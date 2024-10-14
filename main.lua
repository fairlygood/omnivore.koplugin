local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("frontend/luasettings")
local Menu = require("ui/widget/menu")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template
local mime = require("mime")

-- constants

local API_ENDPOINT = "https://api-prod.omnivore.app/api/graphql"

local Omnivore = WidgetContainer:extend{
    name = "omnivore",
    is_doc_only = false,
}

function Omnivore:onDispatcherRegisterActions()
    Dispatcher:registerAction("omnivore_download", { category="none", event="SynchronizeOmnivore", title=_("Omnivore retrieval"), general=true,})
end

function Omnivore:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.omnivore_settings = self:readSettings()
    self.api_key = self.omnivore_settings:readSetting("omnivore", {}).api_key
    self.directory = self.omnivore_settings:readSetting("omnivore", {}).directory
end

function Omnivore:addToMainMenu(menu_items)
    menu_items.omnivore = {
        text = _("Omnivore"),
        sub_item_table = {
            {
                text = _("View Omnivore Articles"),
                callback = function()
                    self:displayArticleList()
                end,
            },
            {
                text = _("Go to download folder"),
                callback = function()
                    if self.ui.document then
                        self.ui:onClose()
                    end
                    if FileManager.instance then
                        FileManager.instance:reinit(self.directory)
                    else
                        FileManager:showFiles(self.directory)
                    end
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Configure Omnivore"),
                        keep_menu_open = true,
                        callback = function()
                            self:editSettings()
                        end,
                    },
                    {
                        text_func = function()
                            local path
                            if not self.directory or self.directory == "" then
                                path = _("Not set")
                            else
                                path = filemanagerutil.abbreviate(self.directory)
                            end
                            return T(_("Set download folder: %1"), BD.dirpath(path))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setDownloadDirectory(touchmenu_instance)
                        end,
                    },
                }
            },
            {
                text = _("Info"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[Omnivore is a read-it-later service. This plugin downloads articles as HTML. Downloads to folder: %1]]), BD.dirpath(filemanagerutil.abbreviate(self.directory)))
                    })
                end,
            },
        },
    }
end

function Omnivore:showProgress(text)
    self.progress_message = InfoMessage:new{text = text, timeout = 0}
    UIManager:show(self.progress_message)
    UIManager:forceRePaint()
end

function Omnivore:hideProgress()
    if self.progress_message then UIManager:close(self.progress_message) end
    self.progress_message = nil
end

function Omnivore:callAPI(method, url, headers, body)
    
    local request = {
        url = url,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table({}),
    }

    local response_body = {}
    request.sink = ltn12.sink.table(response_body)

    local ok, code, response_headers = http.request(request)

    if not ok then
        return nil, "network_error"
    end

    if code ~= 200 then
        return nil, "http_error", code
    end

    local content = table.concat(response_body)

    if content == "" then
        return nil, "empty_response"
    end

    local ok, result = pcall(JSON.decode, content)
    if ok and result then
        return result
    else
        return nil, "json_error"
    end
end

function Omnivore:getArticleList()
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set"
    end

    local query = [[
        query Search($after: String, $first: Int, $query: String) {
            search(first: $first, after: $after, query: $query) {
                ... on SearchSuccess {
                    edges {
                        node {
                            id
                            title
                            url
                            author
                            slug
                        }
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
                ... on SearchError {
                    errorCodes
                }
            }
        }
    ]]

    local all_articles = {}
    local hasNextPage = true
    local endCursor = nil

    while hasNextPage do
        local variables = {
            first = 20,  -- Fetch 20 articles at a time
            query = "sort:saved-desc in:inbox",
            after = endCursor
        }

        local body = {
            query = query,
            variables = variables
        }

        local json_body = JSON.encode(body)

        local headers = {
            ["Authorization"] = self.api_key,
            ["Content-Type"] = "application/json",
        }

        local result, err, code = self:callAPI("POST", API_ENDPOINT, headers, json_body)

        if err then
            local error_msg = "Error fetching article list: " .. err
            return nil, error_msg
        end

        if result and result.data and result.data.search then
            if result.data.search.edges then
                for _, edge in ipairs(result.data.search.edges) do
                    table.insert(all_articles, edge)
                end
                hasNextPage = result.data.search.pageInfo.hasNextPage
                endCursor = result.data.search.pageInfo.endCursor
            elseif result.data.search.errorCodes then
                local error_msg = "Search error: " .. table.concat(result.data.search.errorCodes, ", ")
                return nil, error_msg
            end
        else
            hasNextPage = false
        end

        -- Update progress
        self:showProgress(_("Fetching articles... ") .. #all_articles .. _(" found"))
    end

    return all_articles
end

function Omnivore:displayArticleList()
    local fetch_articles = function()
        self:showProgress(_("Fetching articles..."))
        local articles, err = self:getArticleList()
        self:hideProgress()

        if err then
            UIManager:show(InfoMessage:new{text = T(_("Error fetching articles: %1"), err)})
            return
        end
        if #articles == 0 then
            UIManager:show(InfoMessage:new{text = _("No articles found in Omnivore inbox.")})
            return
        end

        local menu_items = {}
        for i, article in ipairs(articles) do
            table.insert(menu_items, {
                text = article.node.title,
                callback = function()
                    self:downloadArticle(article.node)
                end
            })
        end

        if self.article_menu == nil then
            self.article_menu = Menu:new{
                title = _("Omnivore Articles"),
                item_table = menu_items,
                is_popout = false,
                is_borderless = true,
                show_parent = self,
                close_callback = function() 
                    self.article_menu = nil 
                end,
                perpage = 10,
                onNextPage = function(this)
                    this.page = math.min(this.page + 1, math.ceil(#menu_items / this.perpage))
                    this:updateItems()
                    UIManager:setDirty(this, function()
                        return "ui", this.dimen
                    end)
                    return true
                end,
                onPrevPage = function(this)
                    this.page = math.max(1, this.page - 1)
                    this:updateItems()
                    UIManager:setDirty(this, function()
                        return "ui", this.dimen
                    end)
                    return true
                end,
            }
            UIManager:show(self.article_menu)
        else
            self.article_menu:switchItemTable(_("Omnivore Articles"), menu_items)
        end
    end

    NetworkMgr:runWhenOnline(fetch_articles)
end

function Omnivore:downloadArticle(article)
    
    local download = function()
        self:showProgress(_("Fetching article data..."))
        
        local query = [[
            query GetArticle($username: String!, $slug: String!) {
                article(username: $username, slug: $slug) {
                    ... on ArticleSuccess {
                        article {
                            id
                            title
                            url
                            author
                            content
                            slug
                        }
                    }
                    ... on ArticleError {
                        errorCodes
                    }
                }
            }
        ]]

        local variables = {
            username = "me",
            slug = article.slug
        }

        local body = {
            query = query,
            variables = variables
        }

        local json_body = JSON.encode(body)

        local headers = {
            ["Authorization"] = self.api_key,
            ["Content-Type"] = "application/json",
        }

        local result, err = self:callAPI("POST", API_ENDPOINT, headers, json_body)

        if err then
            self:hideProgress()
            UIManager:show(InfoMessage:new{text = T(_("Error fetching article: %1"), err)})
            return
        end

        if result and result.data and result.data.article and result.data.article.article then
            local article_data = result.data.article.article
            
            self:showProgress(_("Processing article content..."))
            local title = util.getSafeFilename(article_data.title, nil, 230)
            local directory = self.directory:gsub("([^/])$", "%1/")
            local local_path = directory .. title .. ".html"
            
            -- Process content and embed images
            local image_count = 0
            local processed_content = article_data.content:gsub('<img[^>]+>', function(img_tag)
                local original_src = img_tag:match('data%-omnivore%-original%-src="([^"]+)"')
                if original_src then
                    image_count = image_count + 1
                    if image_count == 1 then
                        self:showProgress(_("Fetching images..."))
                    end
                    local encoded_img = self:fetchAndEncodeImage(original_src)
                    if encoded_img then
                        return img_tag:gsub('src="[^"]+"', 'src="' .. encoded_img .. '"')
                    end
                end
                return img_tag
            end)
            
            self:showProgress(_("Saving article..."))
            local success = self:saveHTML(article_data, local_path, processed_content)
            self:hideProgress()

            if success then
                UIManager:show(InfoMessage:new{text = _("Article downloaded successfully.")})
            else
                UIManager:show(InfoMessage:new{text = _("Failed to save article.")})
            end
        else
            self:hideProgress()
            UIManager:show(InfoMessage:new{text = _("Failed to fetch article data.")})
        end
    end

    NetworkMgr:runWhenOnline(download)
end

function Omnivore:fetchAndEncodeImage(url)
    local response = {}
    local request, code, response_headers = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        method = "GET",
    }
    
    if code ~= 200 then
        return nil
    end
    
    local image_data = table.concat(response)
    
    local encoded = mime.b64(image_data)
    
    local mime_type = response_headers and response_headers["content-type"] or "image/jpeg"
    
    return string.format("data:%s;base64,%s", mime_type, encoded)
end

function Omnivore:saveHTML(article_data, local_path, processed_content)
    
    -- Ensure the directory exists
    local dir = local_path:match("(.+)/[^/]+$")
    if dir then
        local command = string.format('mkdir -p "%s"', dir)
        local success, reason, code = os.execute(command)
        if not success then
            return false
        end
    end

    local file, err = io.open(local_path, "w")
    if not file then
        return false
    end

    local content = string.format(
        "<html><head><title>%s</title></head><body>",
        article_data.title
    )
    content = content .. string.format("<h1>%s</h1>", article_data.title)
    content = content .. string.format("<p>Author: %s</p>", article_data.author or "Unknown")
    content = content .. string.format("<p>URL: <a href='%s'>%s</a></p>", article_data.url, article_data.url)
    content = content .. "<hr>"
    content = content .. processed_content
    content = content .. "</body></html>"

    local success, write_err = file:write(content)
    if not success then
        file:close()
        return false
    end

    local close_success, close_err = file:close()
    if not close_success then
        return false
    end

    return true
end

function Omnivore:editSettings()
    self.settings_dialog = MultiInputDialog:new {
        title = _("Omnivore settings"),
        fields = {
            {
                text = self.api_key or "",
                hint = _("API Key")
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.settings_dialog)
                    end
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.settings_dialog:getFields()
                        self.api_key = fields[1]
                        self:saveSettings()
                        UIManager:close(self.settings_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

function Omnivore:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            -- Ensure the path ends with a slash
            path = path:gsub("([^/])$", "%1/")
            self.directory = path
            self:saveSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir()
end

function Omnivore:saveSettings()
    local settings = {
        api_key = self.api_key,
        directory = self.directory,
    }
    self.omnivore_settings:saveSetting("omnivore", settings)
    self.omnivore_settings:flush()
end

function Omnivore:readSettings()
    local omnivore_settings = LuaSettings:open(DataStorage:getSettingsDir().."/omnivore.lua")
    omnivore_settings:readSetting("omnivore", {})
    return omnivore_settings
end

function Omnivore:onSynchronizeOmnivore()
    local connect_callback = function()
        self:displayArticleList()
    end
    NetworkMgr:runWhenOnline(connect_callback)
    return true
end

return Omnivore