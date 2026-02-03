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

local function remember_temp_file(path)
    if path and path ~= "" then
        temp_danmaku_files[path] = true
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

local function download_danmaku_xml(url)
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

local function extract_play_url(data)
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

    local lines = split(vod.vod_play_from or "", "$$$")
    local groups = split(vod.vod_play_url or "", "$$$")
    local title = vod.vod_name or "详情"

    if use_uosc() then
        -- 按线路分组，使用子菜单展示
        local items = {}

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
                        value = {
                            "script-message-to", mp.get_script_name(), "catpaw-play-episode",
                            site.id, line, id,
                        },
                    }
                end
            end

            if ep_count > 0 then
                items[#items + 1] = {
                    title = line,
                    hint = ep_count .. " 集",
                    items = episodes,
                }
            end
        end

        update_menu_uosc("catpaw_detail", title, items, "", nil, nil)
    elseif input_loaded then
        -- mp.input 不支持子菜单，使用扁平列表
        local items = {}
        for i, group in ipairs(groups) do
            local line = lines[i] or ("线路 " .. tostring(i))
            for ep in group:gmatch("[^#]+") do
                if ep ~= "" then
                    local name, id = ep:match("^(.-)%$(.+)$")
                    name = name or ep
                    id = id or ep
                    items[#items + 1] = {
                        title = name,
                        hint = line,
                        value = {
                            "script-message-to", mp.get_script_name(), "catpaw-play-episode",
                            site.id, line, id,
                        },
                    }
                end
            end
        end
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

    local url = extract_play_url(data)
    if not url or url == "" then
        show_message("无可用播放地址", 3)
        return
    end

    mp.commandv("loadfile", url, "replace")

    -- 弹幕挂载
    if data.extra and data.extra.danmaku then
        local danmaku = data.extra.danmaku
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

mp.register_script_message("catpaw-show-results", function()
    show_cached_results()
end)

mp.register_event("end-file", function()
    cleanup_temp_files("end-file")
end)

mp.register_event("shutdown", function()
    cleanup_temp_files("shutdown")
end)
