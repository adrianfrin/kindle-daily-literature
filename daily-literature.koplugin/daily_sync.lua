-- The transport and filesystem are injected so downloads can be tested without a Kindle.
local Sync = {}
local MAX_ARTICLE = 512 * 1024

local function blobHash(body, deps)
    return deps.sha1("blob " .. #body .. "\0" .. body)
end

local function decodeJSON(body, deps)
    local ok, result = pcall(deps.decode, body)
    if not ok or type(result) ~= "table" then
        error("远端数据不是有效的 JSON")
    end
    return result
end

function Sync.decodeBlob(response, path, deps)
    local obj = decodeJSON(response, deps)
    if obj.type ~= "file" or obj.path ~= path or obj.encoding ~= "base64"
        or type(obj.content) ~= "string" or type(obj.sha) ~= "string"
        or not obj.sha:match("^%x+$") or #obj.sha ~= 40
        or type(obj.size) ~= "number" or obj.size > MAX_ARTICLE then
        error("GitHub 文件信息无效：" .. path)
    end
    local body = deps.base64(obj.content)
    if type(body) ~= "string" or #body ~= obj.size or blobHash(body, deps) ~= obj.sha then
        error("文件完整性校验失败：" .. path)
    end
    return body, obj.sha
end

local function validatedArticles(manifest)
    if manifest.version ~= 1 or type(manifest.articles) ~= "table" or #manifest.articles > 60 then
        error("日报目录格式不受支持")
    end
    local entries, seen = {}, {}
    for _, entry in ipairs(manifest.articles) do
        if type(entry) ~= "table" or type(entry.date) ~= "string"
            or not entry.date:match("^%d%d%d%d%-%d%d%-%d%d$")
            or entry.path ~= "articles/" .. entry.date .. ".html"
            or type(entry.title) ~= "string" or #entry.title > 1000
            or type(entry.sha) ~= "string" or #entry.sha ~= 40 or not entry.sha:match("^%x+$")
            or seen[entry.path] then
            error("日报目录含无效或重复条目")
        end
        seen[entry.path] = true
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b) return a.date > b.date end)
    return entries
end

function Sync.run(deps, state)
    state = state or {}
    if type(state.files) ~= "table" then state.files = {} end
    local result = { downloaded = 0, current = 0, errors = {}, latest = nil }
    local manifest_body = Sync.decodeBlob(assert(deps.fetch("manifest.json")), "manifest.json", deps)
    local entries = validatedArticles(decodeJSON(manifest_body, deps))
    local attempted = 0
    for _, entry in ipairs(entries) do
        local filename = entry.date .. ".html"
        local saved = state.files[entry.path]
        local local_body = deps.read(filename)
        if saved and saved.sha == entry.sha and local_body
            and blobHash(local_body, deps) == entry.sha then
            result.current = result.current + 1
        elseif attempted < 5 then
            attempted = attempted + 1
            local ok, err = pcall(function()
                local body, sha = Sync.decodeBlob(assert(deps.fetch(entry.path)), entry.path, deps)
                if sha ~= entry.sha then error("目录正在更新，请稍后重试") end
                if not body:lower():find("<html", 1, true) or not body:lower():find("</html>", 1, true) then
                    error("文章 HTML 不完整")
                end
                assert(deps.write(filename, body))
                state.files[entry.path] = { sha = sha, date = entry.date, title = entry.title }
                assert(deps.save(state))
                result.downloaded = result.downloaded + 1
            end)
            if not ok then result.errors[#result.errors + 1] = tostring(err) end
        end
        if not result.latest and state.files[entry.path] and deps.read(filename) then
            result.latest = entry.date
        end
    end
    if #result.errors == 0 then
        state.last_success = deps.now()
        assert(deps.save(state))
    end
    result.last_success = state.last_success
    return result
end

return Sync
