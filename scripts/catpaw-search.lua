-- catpaw-search.lua
-- CatPawOpen 视频搜索与播放插件
-- 支持 uosc 菜单（优先）和 mp.input 降级

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    server = "http://127.0.0.1:3006",
    connect_timeout = 5,
    request_timeout = 15,
    max_results_per_site = 20,
    prefer_uosc = true,
}

options.read_options(o, "catpaw-search")

local input_loaded, input = pcall(require, "mp.input")
local uosc_available = false

local state = {
    sites = nil,
    sites_by_id = {},
    last_query = "",
    last_results = nil,
    current_detail = nil,
    last_play_variants = nil,
    last_play_danmaku = nil,
    pending_danmaku = nil,
    pending_attach = false,
    switching_stream = false,
    last_play_headers = nil,
    saved_http_headers = nil,
    http_headers_applied = false,
    episode_cache = nil,
    episode_cache_key = nil,
    last_episode_ctx = nil,
    last_variant_title = nil,
}

local detail_cache = {}

-- 工具函数
local function use_uosc()
    return o.prefer_uosc and uosc_available
end

local function show_message(text, seconds)
    mp.osd_message(text, seconds or 2)
end

local function normalize_url(url)
    if not url or url == "" then return "http://127.0.0.1:3006" end
    return url:sub(-1) == "/" and url:sub(1, -2) or url
end

local base_url = normalize_url(o.server)

local function join_url(path)
    if not path or path == "" then return base_url end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return base_url .. path
end

local function split(str, sep)
    local res = {}
    if not str or str == "" then return res end
    local start = 1
    while true do
        local i, j = string.find(str, sep, start, true)
        if not i then
            table.insert(res, string.sub(str, start))
            break
        end
        table.insert(res, string.sub(str, start, i - 1))
        start = j + 1
    end
    return res
end

local function build_episode_cache(vod)
    local cache = { lines = {}, line_map = {} }
    if not vod then return cache end
    local lines = split(vod.vod_play_from or "", "$$$")
    local groups = split(vod.vod_play_url or "", "$$$")
    for i, group in ipairs(groups) do
        local line = lines[i] or ("线路 " .. tostring(i))
        local episodes = {}
        local ep_count = 0
        for ep in group:gmatch("[^#]+") do
            if ep ~= "" then
                local name, id = ep:match("^(.-)%$(.+)$")
                name = name or ep
                id = id or ep
                ep_count = ep_count + 1
                episodes[#episodes + 1] = {
                    title = name,
                    id = id,
                    line = line,
                    index = ep_count,
                }
            end
        end
        if ep_count > 0 then
            local entry = {
                line = line,
                index = #cache.lines + 1,
                episodes = episodes,
            }
            cache.lines[#cache.lines + 1] = entry
            cache.line_map[line] = entry
        end
    end
    return cache
end

local function set_episode_cache(site_id, vod_id, vod)
    if not site_id or not vod_id then return nil end
    local cache = build_episode_cache(vod)
    state.episode_cache = cache
    state.episode_cache_key = site_id .. ":" .. tostring(vod_id)
    return cache
end

local function get_episode_cache(site_id, vod_id)
    if not site_id or not vod_id then return nil end
    local key = site_id .. ":" .. tostring(vod_id)
    if state.episode_cache and state.episode_cache_key == key then
        return state.episode_cache
    end
    local detail = detail_cache[key]
    local vod = detail and detail.list and detail.list[1]
    if vod then
        return set_episode_cache(site_id, vod_id, vod)
    end
    return nil
end

-- HTTP 请求
local CURL_NOT_FOUND = "curl 未安装或不在 PATH 中"

local function build_curl_args(method, url, body)
    local args = {
        "curl", "-s", "-L",
        "--connect-timeout", tostring(o.connect_timeout),
        "--max-time", tostring(o.request_timeout),
        "--user-agent", "mpv",
    }
    if method == "POST" then
        table.insert(args, "-H")
        table.insert(args, "Content-Type: application/json")
        table.insert(args, "-X")
        table.insert(args, "POST")
        table.insert(args, "-d")
        table.insert(args, body or "{}")
    end
    table.insert(args, url)
    return args
end

local function is_curl_missing(res)
    if not res then return false end
    if res.status == -2 or res.status == -3 then return true end
    local err_str = res.error_string or res.stderr or ""
    if err_str:lower():find("not found") then return true end
    if err_str:lower():find("createprocess") then return true end
    if err_str:lower():find("no such file") then return true end
    if err_str:lower():find("cannot find") then return true end
    return false
end

local function http_get(url)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = build_curl_args("GET", url, nil),
    })
    if res.status ~= 0 then
        if is_curl_missing(res) then return nil, CURL_NOT_FOUND end
        return nil, res.stderr or res.error_string
    end
    return res.stdout, nil
end

local function http_post(url, body)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = build_curl_args("POST", url, body),
    })
    if res.status ~= 0 then
        if is_curl_missing(res) then return nil, CURL_NOT_FOUND end
        return nil, res.stderr or res.error_string
    end
    return res.stdout, nil
end

local function http_post_async(url, body, cb)
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = build_curl_args("POST", url, body),
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            if is_curl_missing(result) then
                cb(nil, CURL_NOT_FOUND)
            else
                cb(nil, result and (result.stderr or result.error_string) or "request failed")
            end
            return
        end
        cb(result.stdout, nil)
    end)
end

local function parse_json(text)
    if not text or text == "" then return nil end
    return utils.parse_json(text)
end

local function get_temp_dir()
    local is_windows = package.config:sub(1, 1) == "\\"
    if is_windows then
        return os.getenv("TEMP") or os.getenv("TMP") or mp.command_native({ "expand-path", "~~/" })
    end
    return "/tmp"
end

local function write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(content or "")
    f:close()
    return true
end

local temp_danmaku_files = {}
local temp_danmaku_by_url = {}

local function remember_temp_file(path)
    if path and path ~= "" then
        temp_danmaku_files[path] = true
    end
end

local function get_cached_danmaku(url)
    if not url or url == "" then return nil end
    local cached = temp_danmaku_by_url[url]
    if cached and cached ~= "" then
        local info = utils.file_info(cached)
        if info and info.is_file then
            return cached
        end
    end
    temp_danmaku_by_url[url] = nil
    return nil
end

local function remember_danmaku_url(url, path)
    if url and url ~= "" and path and path ~= "" then
        temp_danmaku_by_url[url] = path
    end
end

local function cleanup_temp_files(reason)
    local removed = 0
    for path, _ in pairs(temp_danmaku_files) do
        local info = utils.file_info(path)
        if info and info.is_file then
            local ok, err = os.remove(path)
            if ok then
                removed = removed + 1
            else
                msg.warn("catpaw-search: remove temp file failed: " .. tostring(err))
            end
        end
        temp_danmaku_files[path] = nil
    end
    if next(temp_danmaku_by_url) ~= nil then
        temp_danmaku_by_url = {}
    end
    if removed > 0 then
        msg.info("catpaw-search: cleaned " .. tostring(removed) .. " temp danmaku file(s)" ..
            (reason and (" (" .. reason .. ")") or ""))
    end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_danmaku_xml(xml)
    if not xml or xml == "" then return xml, false end
    local changed = false
    local normalized = xml:gsub('(<d%s+[^>]*%f[^%s]p=")([^"]+)(")', function(prefix, p_attr, suffix)
        local parts = {}
        for val in p_attr:gmatch("([^,]+)") do
            parts[#parts + 1] = trim(val)
        end
        local t = tonumber(parts[1])
        local ty = tonumber(parts[2])
        local p3 = tonumber(parts[3])
        local p4 = tonumber(parts[4])
        if not t or not ty then
            return prefix .. p_attr .. suffix
        end
        if p4 then
            return prefix .. p_attr .. suffix
        end
        if p3 then
            local size = 25
            local color = 0xFFFFFF
            if p3 > 1000 then
                color = p3
            else
                size = p3
            end
            changed = true
            local new_p = table.concat({ parts[1], parts[2], tostring(size), tostring(color) }, ",")
            return prefix .. new_p .. suffix
        end
        return prefix .. p_attr .. suffix
    end)
    return normalized, changed
end

local function is_http_url(text)
    return type(text) == "string" and text:match("^https?://")
end

local function is_catpaw_playback()
    local path = mp.get_property("path") or ""
    return path ~= "" and path:sub(1, #base_url) == base_url
end

local function normalize_http_headers(headers)
    local fields = {}
    if type(headers) ~= "table" then return fields end
    for k, v in pairs(headers) do
        if type(k) == "string" and v ~= nil then
            local value = tostring(v)
            if value ~= "" then
                fields[#fields + 1] = k .. ": " .. value
            end
        end
    end
    return fields
end

local function apply_http_headers(headers)
    local fields = normalize_http_headers(headers)
    if #fields == 0 then
        return false
    end
    if state.saved_http_headers == nil then
        state.saved_http_headers = mp.get_property_native("http-header-fields")
    end
    mp.set_property_native("http-header-fields", fields)
    state.http_headers_applied = true
    return true
end

local function restore_http_headers()
    if not state.http_headers_applied then
        return
    end
    if state.saved_http_headers ~= nil then
        mp.set_property_native("http-header-fields", state.saved_http_headers)
    else
        mp.set_property_native("http-header-fields", {})
    end
    state.saved_http_headers = nil
    state.http_headers_applied = false
end

local function download_danmaku_xml(url)
    local cached = get_cached_danmaku(url)
    if cached then
        return cached, nil
    end
    local xml, err = http_get(url)
    if not xml then return nil, err end
    if xml == "" then return nil, "empty response" end
    local normalized, changed = normalize_danmaku_xml(xml)
    if changed then
        msg.info("catpaw-search: normalized danmaku xml")
    end
    if not normalized:find("<d%s") then
        return nil, "no danmaku items"
    end
    local temp_dir = get_temp_dir()
    local pid = tostring(mp.get_property_native("pid") or "mpv")
    local filename = string.format("catpaw-danmaku-%s-%d.xml", pid, math.random(1000, 9999))
    local file_path = utils.join_path(temp_dir, filename)
    local ok, werr = write_file(file_path, normalized)
    if not ok then return nil, werr end
    remember_temp_file(file_path)
    remember_danmaku_url(url, file_path)
    return file_path, nil
end

-- UI 层
local function update_menu_uosc(menu_type, menu_title, menu_item, footnote, on_search, query)
    local items = {}
    if type(menu_item) == "string" then
        table.insert(items, {
            title = menu_item,
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
        })
    else
        items = menu_item or {}
    end

    local menu_props = {
        type = menu_type,
        title = menu_title,
        search_style = on_search and "palette" or "on_demand",
        search_debounce = on_search and "submit" or 0,
        on_search = on_search,
        footnote = footnote,
        search_suggestion = query,
        items = items,
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_props))
end

local function open_menu_select(menu_items, prompt)
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu_items) do
        item_titles[i] = v.hint and (v.title .. " (" .. v.hint .. ")") or v.title
        item_values[i] = v.value
    end
    mp.commandv("script-message-to", "console", "disable")
    input.select({
        prompt = prompt or "选择:",
        items = item_titles,
        submit = function(id)
            if id and item_values[id] then
                mp.commandv(unpack(item_values[id]))
            end
        end,
    })
end

-- API 层
local function check_service()
    local out, err = http_get(join_url("/check"))
    if not out then return nil, err end
    local data = parse_json(out)
    if not data or type(data.run) ~= "boolean" then
        return nil, "invalid /check response"
    end
    return data.run, nil
end

local function fetch_sites()
    local out, err = http_get(join_url("/config"))
    if not out then return nil, err end
    local data = parse_json(out)
    if not data or not data.video or type(data.video.sites) ~= "table" then
        return nil, "invalid /config response"
    end
    local sites = {}
    for _, site in ipairs(data.video.sites) do
        if site.enable ~= false then
            local api = site.api
            if api and api:sub(1, 1) ~= "/" then api = "/" .. api end
            if not api and site.key and site.type then
                api = "/spider/" .. site.key .. "/" .. tostring(site.type)
            end
            if api then
                local site_id = site.key or api
                sites[#sites + 1] = {
                    id = site_id,
                    key = site.key,
                    name = site.name or site.key or site_id,
                    api = api,
                    type = site.type,
                }
            end
        end
    end
    return sites, nil
end

local function get_sites()
    if state.sites then return state.sites, nil end
    local sites, err = fetch_sites()
    if not sites then return nil, err end
    state.sites = sites
    state.sites_by_id = {}
    for _, site in ipairs(sites) do
        state.sites_by_id[site.id] = site
    end
    return sites, nil
end

local function search_all_sites(keyword, done)
    local sites, err = get_sites()
    if not sites then
        done(nil, { "获取站点失败: " .. (err or "未知错误") })
        return
    end
    if #sites == 0 then
        done({}, nil)
        return
    end

    local pending = #sites
    local results_by_site = {}
    local errors = {}

    for idx, site in ipairs(sites) do
        local url = join_url(site.api .. "/search")
        local body = utils.format_json({ wd = keyword, page = 1 })
        http_post_async(url, body, function(out, err_msg)
            if out then
                local data = parse_json(out)
                if data and type(data.list) == "table" then
                    local site_results = {}
                    local count = 0
                    for _, vod in ipairs(data.list) do
                        site_results[#site_results + 1] = { site = site, vod = vod }
                        count = count + 1
                        if o.max_results_per_site > 0 and count >= o.max_results_per_site then
                            break
                        end
                    end
                    results_by_site[idx] = site_results
                end
            else
                errors[#errors + 1] = (site.name or site.id) .. ": " .. (err_msg or "请求失败")
            end
            pending = pending - 1
            if pending == 0 then
                local results = {}
                for i = 1, #sites do
                    if results_by_site[i] then
                        for _, entry in ipairs(results_by_site[i]) do
                            results[#results + 1] = entry
                        end
                    end
                end
                done(results, #errors > 0 and errors or nil)
            end
        end)
    end
end

local function get_detail(site, vod_id)
    local cache_key = site.id .. ":" .. tostring(vod_id)
    if detail_cache[cache_key] then
        return detail_cache[cache_key], nil
    end
    local url = join_url(site.api .. "/detail")
    local body = utils.format_json({ id = vod_id })
    local out, err = http_post(url, body)
    if not out then return nil, err end
    local data = parse_json(out)
    if not data then return nil, "invalid /detail response" end
    detail_cache[cache_key] = data
    return data, nil
end

local function get_play_url(site, flag, play_id)
    local url = join_url(site.api .. "/play")
    local body = utils.format_json({ id = play_id, flag = flag })
    local out, err = http_post(url, body)
    if not out then return nil, err end
    local data = parse_json(out)
    if not data then return nil, "invalid /play response" end
    return data, nil
end

local function extract_play_variants(data)
    local variants = {}
    if not data then return variants end

    if type(data.url) == "string" then
        if data.url ~= "" then
            variants[#variants + 1] = { title = "默认", url = data.url }
        end
        return variants
    end

    if type(data.url) == "table" then
        local n = #data.url
        local is_pair_list = n >= 2
        if is_pair_list then
            for i = 1, n, 2 do
                if type(data.url[i]) ~= "string" or type(data.url[i + 1]) ~= "string" then
                    is_pair_list = false
                    break
                end
            end
        end
        if is_pair_list then
            for i = 1, n, 2 do
                local title = data.url[i]
                local url = data.url[i + 1]
                if url and url ~= "" then
                    variants[#variants + 1] = { title = title or ("线路 " .. tostring((i + 1) / 2)), url = url }
                end
            end
            return variants
        end

        for i, v in ipairs(data.url) do
            if type(v) == "string" then
                if v ~= "" then
                    variants[#variants + 1] = { title = "线路 " .. tostring(i), url = v }
                end
            elseif type(v) == "table" then
                local title = v[1] or v.title or ("线路 " .. tostring(i))
                local url = v[2] or v.url
                if type(url) == "string" and url ~= "" then
                    variants[#variants + 1] = { title = tostring(title), url = url }
                end
            end
        end
    end

    if #variants == 0 and type(data.urls) == "table" then
        for i, v in ipairs(data.urls) do
            if type(v) == "string" then
                if v ~= "" then
                    variants[#variants + 1] = { title = "线路 " .. tostring(i), url = v }
                end
            elseif type(v) == "table" then
                local title = v[1] or v.title or ("线路 " .. tostring(i))
                local url = v[2] or v.url
                if type(url) == "string" and url ~= "" then
                    variants[#variants + 1] = { title = tostring(title), url = url }
                end
            end
        end
    end

    return variants
end

local function extract_play_url(data, variants)
    if variants and #variants > 0 then
        return variants[1].url
    end
    if not data then return nil end
    if type(data.url) == "string" and data.url ~= "" then
        return data.url
    end
    if type(data.url) == "table" then
        return data.url[2] or data.url[1]
    end
    if type(data.urls) == "table" then
        local first = data.urls[1]
        if type(first) == "string" then return first end
        if type(first) == "table" then return first[2] or first[1] end
    end
    return nil
end

local function attach_danmaku(danmaku)
    if not danmaku then return end
    mp.add_timeout(0.5, function()
        if type(danmaku) == "number" or (type(danmaku) == "string" and danmaku:match("^%d+$")) then
            mp.commandv("script-message", "load-danmaku", "", "", tostring(danmaku))
            return
        end
        if is_http_url(danmaku) then
            -- CatPawOpen 返回 danmu-proxy URL，需先下载为本地 XML 再交给 uosc_danmaku
            local file_path, derr = download_danmaku_xml(danmaku)
            if file_path then
                mp.commandv("script-message", "add-source-event", file_path)
            else
                show_message("下载弹幕失败: " .. (derr or "未知错误"), 3)
                msg.error("catpaw-search: download danmaku failed: " .. (derr or "unknown error"))
            end
            return
        end
        if type(danmaku) == "string" then
            local info = utils.file_info(danmaku)
            if info and info.is_file then
                mp.commandv("script-message", "add-source-event", danmaku)
                return
            end
        end
        mp.commandv("script-message", "load-danmaku", "", "", tostring(danmaku))
    end)
end

local function show_play_variants()
    local variants = state.last_play_variants
    if not variants or #variants == 0 then
        show_message("无可切换线路", 2)
        return
    end

    if use_uosc() then
        local items = {}
        for i, v in ipairs(variants) do
            items[#items + 1] = {
                title = v.title or ("线路 " .. tostring(i)),
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-play-variant",
                    tostring(i),
                },
            }
        end
        update_menu_uosc("catpaw_streams", "选择线路", items, "", nil, nil)
    elseif input_loaded then
        local items = {}
        for i, v in ipairs(variants) do
            items[#items + 1] = {
                title = v.title or ("线路 " .. tostring(i)),
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-play-variant",
                    tostring(i),
                },
            }
        end
        mp.osd_message("")
        mp.add_timeout(0.1, function() open_menu_select(items, "选择线路") end)
    else
        show_message("需要 uosc 或 mp.input 支持", 3)
    end
end

local function play_variant(index)
    local variants = state.last_play_variants
    local idx = tonumber(index or "")
    if not variants or #variants == 0 then
        show_message("无可切换线路", 2)
        return
    end
    if not idx or not variants[idx] then
        show_message("线路不存在", 2)
        return
    end
    local url = variants[idx].url
    if not url or url == "" then
        show_message("无可用播放地址", 2)
        return
    end
    state.last_variant_title = variants[idx].title
    apply_http_headers(state.last_play_headers)
    state.pending_danmaku = state.last_play_danmaku
    state.pending_attach = true
    state.switching_stream = true
    mp.commandv("loadfile", url, "replace")
end

-- 业务逻辑
local function show_search_results(results, errors)
    state.last_results = results

    if not results or #results == 0 then
        if use_uosc() then
            update_menu_uosc("catpaw_search", "CatPaw 搜索", "无结果", "输入关键词搜索",
                { "script-message-to", mp.get_script_name(), "catpaw-do-search" }, state.last_query)
        else
            show_message("无结果", 3)
        end
        return
    end

    local footnote = errors and (#errors .. " 个站点失败") or ""

    if use_uosc() then
        -- 按站点分组，使用子菜单展示（点击视频后再获取详情）
        local sites_order = {}
        local sites_items = {}

        for _, entry in ipairs(results) do
            local vod = entry.vod
            local site = entry.site
            local site_name = site.name or site.id

            if not sites_items[site_name] then
                sites_items[site_name] = {}
                sites_order[#sites_order + 1] = site_name
            end

            sites_items[site_name][#sites_items[site_name] + 1] = {
                title = tostring(vod.vod_name or vod.vod_id or "未知"),
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-show-detail",
                    site.id, tostring(vod.vod_id or ""),
                },
            }
        end

        local items = {}
        for _, site_name in ipairs(sites_order) do
            items[#items + 1] = {
                title = site_name,
                hint = #sites_items[site_name] .. " 个结果",
                items = sites_items[site_name],
            }
        end

        update_menu_uosc("catpaw_search", "CatPaw 搜索", items, footnote,
            { "script-message-to", mp.get_script_name(), "catpaw-do-search" }, state.last_query)
    elseif input_loaded then
        -- mp.input 不支持子菜单，使用扁平列表
        local items = {}
        for _, entry in ipairs(results) do
            local vod = entry.vod
            local site = entry.site
            items[#items + 1] = {
                title = tostring(vod.vod_name or vod.vod_id or "未知"),
                hint = "[" .. (site.name or site.id) .. "]",
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-show-detail",
                    site.id, tostring(vod.vod_id or ""),
                },
            }
        end
        mp.osd_message("")
        mp.add_timeout(0.1, function() open_menu_select(items, "选择视频") end)
    else
        show_message("需要 uosc 或 mp.input 支持", 3)
    end
end

local function build_episode_menu_items(cache, site_id)
    local items = {}
    if not cache or not cache.lines then return items end
    for _, entry in ipairs(cache.lines) do
        local episodes = {}
        for _, ep in ipairs(entry.episodes) do
            episodes[#episodes + 1] = {
                title = ep.title,
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-play-episode",
                    site_id, entry.line, ep.id,
                },
            }
        end
        if #episodes > 0 then
            items[#items + 1] = {
                title = entry.line,
                hint = #episodes .. " 集",
                items = episodes,
            }
        end
    end
    return items
end

local function build_episode_flat_items(cache, site_id)
    local items = {}
    if not cache or not cache.lines then return items end
    for _, entry in ipairs(cache.lines) do
        for _, ep in ipairs(entry.episodes) do
            items[#items + 1] = {
                title = ep.title,
                hint = entry.line,
                value = {
                    "script-message-to", mp.get_script_name(), "catpaw-play-episode",
                    site_id, entry.line, ep.id,
                },
            }
        end
    end
    return items
end

local function show_episode_list()
    local detail = state.current_detail
    if not detail or not detail.site or not detail.vod_id then
        show_message("暂无剧集列表", 2)
        return
    end
    local cache = get_episode_cache(detail.site.id, detail.vod_id)
    if not cache or not cache.lines or #cache.lines == 0 then
        show_message("暂无剧集列表", 2)
        return
    end
    local title = (detail.vod and detail.vod.vod_name) or "剧集列表"
    if use_uosc() then
        local items = build_episode_menu_items(cache, detail.site.id)
        update_menu_uosc("catpaw_detail", title, items, "", nil, nil)
    elseif input_loaded then
        local items = build_episode_flat_items(cache, detail.site.id)
        mp.osd_message("")
        mp.add_timeout(0.1, function() open_menu_select(items, "选择剧集") end)
    else
        show_message("需要 uosc 或 mp.input 支持", 3)
    end
end

local function update_last_episode_ctx(site_id, line, play_id)
    if not site_id or not line or not play_id then return end
    local vod_id = state.current_detail and state.current_detail.vod_id
    local cache = vod_id and get_episode_cache(site_id, vod_id) or state.episode_cache
    if not cache or not cache.line_map then return end
    local entry = cache.line_map[line]
    if not entry then
        for _, e in ipairs(cache.lines or {}) do
            if trim(e.line) == trim(line) then
                entry = e
                break
            end
        end
    end
    if not entry then return end
    local ep_index = nil
    for i, ep in ipairs(entry.episodes) do
        if tostring(ep.id) == tostring(play_id) then
            ep_index = i
            break
        end
    end
    state.last_episode_ctx = {
        site_id = site_id,
        line = entry.line,
        line_index = entry.index,
        episode_index = ep_index or 0,
        play_id = play_id,
    }
end

local function get_next_episode_ctx()
    local ctx = state.last_episode_ctx
    if not ctx or not ctx.site_id then return nil end
    local cache = state.episode_cache
    if not cache or not cache.line_map then return nil end
    local entry = cache.line_map[ctx.line]
    if not entry then return nil end
    local next_index = (ctx.episode_index or 0) + 1
    local next_ep = entry.episodes[next_index]
    if not next_ep then return nil end
    return {
        site_id = ctx.site_id,
        line = entry.line,
        play_id = next_ep.id,
    }
end

local function show_detail(site_id, vod_id)
    local site = state.sites_by_id[site_id]
    if not site then
        show_message("站点未找到", 3)
        return
    end

    local detail, err = get_detail(site, vod_id)
    if not detail then
        show_message("获取详情失败: " .. (err or "未知错误"), 3)
        return
    end

    local vod = detail.list and detail.list[1]
    if not vod then
        show_message("无效的详情响应", 3)
        return
    end

    state.current_detail = { site = site, vod = vod, vod_id = vod_id }

    local cache = set_episode_cache(site.id, vod_id, vod)
    local title = vod.vod_name or "详情"

    if use_uosc() then
        local items = build_episode_menu_items(cache, site.id)
        update_menu_uosc("catpaw_detail", title, items, "", nil, nil)
    elseif input_loaded then
        local items = build_episode_flat_items(cache, site.id)
        mp.osd_message("")
        mp.add_timeout(0.1, function() open_menu_select(items, "选择剧集") end)
    else
        show_message("需要 uosc 或 mp.input 支持", 3)
    end
end

local function play_episode(site_id, flag, play_id)
    local site = state.sites_by_id[site_id]
    if not site then
        show_message("站点未找到", 3)
        return
    end

    show_message("获取播放地址...", 2)

    local data, err = get_play_url(site, flag, play_id)
    if not data then
        show_message("获取播放地址失败: " .. (err or "未知错误"), 3)
        return
    end
    local variants = extract_play_variants(data)
    state.last_play_variants = variants
    state.last_play_danmaku = data.extra and data.extra.danmaku or nil
    state.last_play_headers = data.header
    update_last_episode_ctx(site_id, flag, play_id)

    local url = nil
    if variants and #variants > 0 then
        local chosen_index = nil
        if state.last_variant_title then
            for i, v in ipairs(variants) do
                if v.title == state.last_variant_title then
                    chosen_index = i
                    break
                end
            end
        end
        if not chosen_index then
            chosen_index = 1
        end
        local chosen = variants[chosen_index]
        url = chosen and chosen.url or nil
        if chosen and chosen.title then
            state.last_variant_title = chosen.title
        end
    else
        url = extract_play_url(data, variants)
    end
    if not url or url == "" then
        show_message("无可用播放地址", 3)
        return
    end

    apply_http_headers(state.last_play_headers)
    state.pending_danmaku = state.last_play_danmaku
    state.pending_attach = true
    state.switching_stream = true
    mp.commandv("loadfile", url, "replace")
end

local function do_search(keyword)
    if not keyword or keyword == "" then
        show_message("请输入关键词", 2)
        return
    end

    state.last_query = keyword

    local ok, err = check_service()
    if ok ~= true then
        if err == CURL_NOT_FOUND then
            show_message(CURL_NOT_FOUND, 3)
        else
            show_message("CatPawOpen 服务未运行", 3)
        end
        if err then msg.error("catpaw-search: /check failed: " .. err) end
        return
    end

    if use_uosc() then
        update_menu_uosc("catpaw_search", "CatPaw 搜索", "搜索中...", "",
            { "script-message-to", mp.get_script_name(), "catpaw-do-search" }, keyword)
    else
        show_message("搜索中...", 2)
    end

    search_all_sites(keyword, function(results, errors)
        if errors then
            for _, e in ipairs(errors) do msg.warn("catpaw-search: " .. e) end
        end
        show_search_results(results, errors)
    end)
end

local function open_search(query)
    local q = query or state.last_query or ""
    if use_uosc() then
        update_menu_uosc("catpaw_search", "CatPaw 搜索", "输入关键词搜索", "回车确认",
            { "script-message-to", mp.get_script_name(), "catpaw-do-search" }, q)
        return
    end

    if input_loaded then
        mp.commandv("script-message-to", "console", "disable")
        input.get({
            prompt = "搜索视频:",
            default_text = q,
            cursor_position = q ~= "" and (#q + 1) or 1,
            submit = function(text)
                input.terminate()
                mp.commandv("script-message-to", mp.get_script_name(), "catpaw-do-search", text)
            end
        })
        return
    end

    show_message("需要 uosc 或 mp.input 支持", 3)
end

local function show_cached_results()
    if state.last_results then
        show_search_results(state.last_results, nil)
    else
        open_search(state.last_query)
    end
end

-- 事件注册
mp.register_script_message("uosc-version", function()
    uosc_available = true
end)

mp.register_script_message("catpaw-open-search", function(query)
    open_search(query)
end)

mp.register_script_message("catpaw-do-search", function(query)
    do_search(query)
end)

mp.register_script_message("catpaw-show-detail", function(site_id, vod_id)
    show_detail(site_id, vod_id)
end)

mp.register_script_message("catpaw-play-episode", function(site_id, flag, play_id)
    play_episode(site_id, flag, play_id)
end)

mp.register_script_message("catpaw-show-streams", function()
    show_play_variants()
end)

mp.register_script_message("catpaw-show-episodes", function()
    show_episode_list()
end)

mp.register_script_message("catpaw-play-variant", function(index)
    play_variant(index)
end)

mp.register_script_message("catpaw-show-results", function()
    show_cached_results()
end)

mp.register_event("end-file", function(event)
    cleanup_temp_files("end-file")
    local reason = event and event.reason or mp.get_property("end-file-reason")
    if reason == "eof" and not state.switching_stream then
        local next_ctx = get_next_episode_ctx()
        if next_ctx then
            mp.add_timeout(0, function()
                play_episode(next_ctx.site_id, next_ctx.line, next_ctx.play_id)
            end)
            return
        end
    end
    if not state.switching_stream then
        state.last_play_variants = nil
        state.last_play_danmaku = nil
        state.last_play_headers = nil
        state.last_variant_title = nil
        state.pending_danmaku = nil
        state.pending_attach = false
        restore_http_headers()
    end
end)

mp.register_event("file-loaded", function()
    if not state.pending_attach then
        return
    end
    local danmaku = state.pending_danmaku
    state.pending_danmaku = nil
    state.pending_attach = false
    state.switching_stream = false
    attach_danmaku(danmaku)
end)

mp.register_event("shutdown", function()
    cleanup_temp_files("shutdown")
    state.last_play_variants = nil
    state.last_play_danmaku = nil
    state.last_play_headers = nil
    state.last_variant_title = nil
    state.pending_danmaku = nil
    state.pending_attach = false
    state.switching_stream = false
    state.episode_cache = nil
    state.episode_cache_key = nil
    state.last_episode_ctx = nil
    restore_http_headers()
end)
