local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Trapper = require("ui/trapper")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local https = require("ssl.https")
local sha = require("ffi/sha2")
local socketutil = require("socketutil")
local logger = require("logger")
local Sync = require("daily_sync")

local REPOSITORY = "adrianfrin/kindle-daily-literature"
local BRANCH = "master"
local DOWNLOAD_DIR = "/mnt/us/documents/DailyLiterature"
local STATE_FILE = DataStorage:getSettingsDir() .. "/daily-literature-state.json"
local MAX_RESPONSE = 800 * 1024
local busy, last_attempt = false, 0

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    if not size or size > MAX_RESPONSE then file:close(); return nil end
    file:seek("set", 0)
    local body = file:read("*a")
    file:close()
    return body
end

local function atomicWrite(path, body)
    local temporary = path .. ".part"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local ok = file:write(body)
    local closed = file:close()
    if not ok or not closed then os.remove(temporary); return nil, "写入失败" end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_error end
    return true
end

local function fetchContents(path)
    local chunks, size, started = {}, 0, os.time()
    socketutil:set_timeout(6, 15)
    local ok, response, code = pcall(https.request, {
        url = "https://api.github.com/repos/" .. REPOSITORY .. "/contents/" .. path .. "?ref=" .. BRANCH,
        method = "GET",
        headers = { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = socketutil.USER_AGENT },
        protocol = "tlsv1_2",
        verify = "peer",
        cafile = "data/ca-bundle.crt",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        sink = function(chunk)
            if chunk then
                size = size + #chunk
                if size > MAX_RESPONSE then return nil, "文件过大" end
                if os.time() - started > 15 then return nil, "网络超时" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    })
    socketutil:reset_timeout()
    if not ok or response ~= 1 or tonumber(code) ~= 200 then
        error("无法访问 GitHub（" .. tostring(code or response) .. "），请检查 Wi-Fi 后重试")
    end
    return table.concat(chunks)
end

local function download()
    local ok, result = pcall(function()
        if lfs.attributes(DOWNLOAD_DIR, "mode") ~= "directory" then
            assert(lfs.mkdir(DOWNLOAD_DIR))
        end
        local state = {}
        local saved = readFile(STATE_FILE)
        if saved then
            local valid, decoded = pcall(json.decode, saved)
            if valid and type(decoded) == "table" then state = decoded end
        end
        return Sync.run({
            decode = json.decode, base64 = sha.base64_to_bin, sha1 = sha.sha1,
            fetch = fetchContents, now = os.time,
            read = function(filename) return readFile(DOWNLOAD_DIR .. "/" .. filename) end,
            write = function(filename, body) return atomicWrite(DOWNLOAD_DIR .. "/" .. filename, body) end,
            save = function(data) return atomicWrite(STATE_FILE, json.encode(data)) end,
        }, state)
    end)
    if not ok then return { error = tostring(result) } end
    return result
end

local Daily = WidgetContainer:extend{ name = "daily_literature", is_doc_only = false }

function Daily:init()
    self.closed = false
    self.ui.menu:registerToMainMenu(self)
    self.auto_task = function()
        if self.closed then return end
        self:sync(false)
        if not self.closed then UIManager:scheduleIn(1800, self.auto_task) end
    end
    UIManager:scheduleIn(8, self.auto_task)
end

function Daily:autoEnabled()
    return G_reader_settings:readSetting("daily_literature_auto", true)
end

function Daily:sync(manual)
    if busy or (not manual and (not self:autoEnabled() or os.time() - last_attempt < 900)) then return end
    if not NetworkMgr:isConnected() then return end
    busy, last_attempt = true, os.time()
    Trapper:wrap(function()
        local ok, completed, result = pcall(function()
            return Trapper:dismissableRunInSubprocess(download, manual and "正在同步每日文学推荐…\n轻触可取消" or nil)
        end)
        busy = false
        if not ok then
            logger.warn("DailyLiterature", completed)
            if manual then UIManager:show(InfoMessage:new{ text = "同步失败，请重试。" }) end
            return
        end
        if not completed then return end
        if type(result) ~= "table" then result = { error = "没有收到同步结果" } end
        if result.error then
            logger.warn("DailyLiterature", result.error)
            if manual then UIManager:show(InfoMessage:new{ text = "同步失败：\n" .. result.error }) end
        elseif manual then
            local text = "同步完成，新增 " .. result.downloaded .. " 篇。\n请选“打开推荐文件夹”阅读。"
            if #result.errors > 0 then text = text .. "\n部分文章待重试：" .. result.errors[1] end
            UIManager:show(InfoMessage:new{ text = text })
        end
    end)
end

function Daily:addToMainMenu(menu_items)
    menu_items.daily_literature = {
        text = "每日文学推荐", sorting_hint = "more_tools",
        sub_item_table = {
            { text = "立即同步", callback = function()
                NetworkMgr:runWhenConnected(function() self:sync(true) end)
            end },
            { text = "打开推荐文件夹", callback = function()
                if lfs.attributes(DOWNLOAD_DIR, "mode") ~= "directory" then lfs.mkdir(DOWNLOAD_DIR) end
                local FileManager = require("apps/filemanager/filemanager")
                if self.ui.document then self.ui:onClose() end
                if FileManager.instance then FileManager.instance:reinit(DOWNLOAD_DIR)
                else FileManager:showFiles(DOWNLOAD_DIR) end
            end },
            { text = "自动同步（已有 Wi-Fi 时）", checked_func = function() return self:autoEnabled() end,
              callback = function()
                  G_reader_settings:saveSetting("daily_literature_auto", not self:autoEnabled())
              end },
        },
    }
end

function Daily:onNetworkConnected()
    if not self.closed then UIManager:scheduleIn(5, function() if not self.closed then self:sync(false) end end) end
end

function Daily:onResume()
    self:onNetworkConnected()
end

function Daily:onCloseWidget()
    self.closed = true
    if self.auto_task then UIManager:unschedule(self.auto_task) end
end

return Daily
