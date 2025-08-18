local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))

local item_names = {}
for s in string.gmatch(os.getenv("item_names"), "([^\n]+)") do
  local pattern = string.gsub(s, "%*", "[0-9a-zA-Z]") .. "$"
  item_names[pattern] = s
end

local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local expect_disallowed = false

local discovered_outlinks = {}
local discovered_items = {}
local discovered_news = {}
local discovered_alerts = {}
local discovered_images = {}
local bad_items = {}
local ids = {}

local retry_url = false
local is_initial_url = true

abort_item = function(item)
  abortgrab = true
  killgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
print('discovered', item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  if ids[url] then
    return nil
  end
  local value = nil
  local type_ = nil
  for pattern, name in pairs({
    ["^https?://goo%.gl/([0-9a-zA-Z]+)%?d=1$"]="i",
    ["^https?://goo%.gl/forms/([0-9a-zA-Z]+)%?d=1$"]="g",
    ["^https?://goo%.gl/photos/([0-9a-zA-Z]+)%?d=1$"]="p",
    ["^https?://goo%.gl/maps/([0-9a-zA-Z]+)%?d=1$"]="m",
    ["^https?://goo%.gl/news/([0-9a-zA-Z]+)%?d=1$"]="n",
    ["^https?://goo%.gl/alerts/([0-9a-zA-Z]+)%?d=1$"]="a",
    ["^https?://goo%.gl/fb/([0-9a-zA-Z]+)%?d=1$"]="f",
    ["^https?://goo%.gl/images/([0-9a-zA-Z]+)%?d=1$"]="im"
  }) do
    value = string.match(url, pattern)
    type_ = name
    if value then
      break
    end
  end
  if value and type_ then
    return {
      ["value"]=value,
      ["type"]=type_
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_name_single_new = found["type"] .. ":" .. found["value"]
    item_name_new = nil
    for pattern, s in pairs(item_names) do
      if string.match(item_name_single_new, pattern) then
        if item_name_new then
          error("Found two fitting item names.")
        end
        item_name_new = s
      end
    end
    if item_name_new then
      ids[found["value"]] = true
      expect_disallowed = false
    end
    if item_name_new ~= item_name then
      ids = {}
      context = {["expect_sorry"]=false}
      --ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      is_new_design = false
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

percent_encode_url = function(url)
  temp = ""
  for c in string.gmatch(url, "(.)") do
    local b = string.byte(c)
    if b < 32 or b > 126 then
      c = string.format("%%%02X", b)
    end
    temp = temp .. c
  end
  return temp
end

allowed = function(url, parenturl)
  if ids[url] then
    return true
  end

  if string.match(url, "^https?://[^/]*google[^/]+/imgres%?")
    and (
      not parenturl
      or string.match(parenturl, "^https?://goo%.gl/images/")
      or string.match(parenturl, "^https?://[^/]*google[^/]+/imgres%?")
    ) then
    return true
  end

  if string.match(url, "^https?://[^/]*goo%.gl/") then
    for _, pattern in pairs({
      "([a-z0-9A-Z]+)",
    }) do
      for s in string.gmatch(url, pattern) do
        if ids[s] then
          return true
        end
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"])
    and not processed(url)
    and string.match(url, "^https://")
    and not addedtolist[url] then
    addedtolist[url] = true
    return true
  end

  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

percent_encode_url = function(newurl)
  result = string.gsub(
    newurl, "(.)",
    function (s)
      local b = string.byte(s)
      if b < 32 or b > 126 then
        return string.format("%%%02X", b)
      end
      return s
    end
  )
  return result
end

get_redirect_data = function(s)
  local json = cjson.decode(string.match(s, ">AF_initDataCallback%({key:[%s',:0-9a-z]-data:(%[.-%]),%s*sideChannel"))
  if not json then
    error("Could not extract JSON data.")
  end
  return json
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    local post_body = nil
    local post_url = nil
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      table.insert(urls, {url=url_})
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end

  local function get_news_url(s)
    local results = {[s]=true}
    for inner_url in string.gmatch(s .. "&", "[%?&][a-z]*url=(https?[^&]+)") do
      while string.match(inner_url, "^https?%%") do
        local temp = urlparse.unescape(inner_url)
        -- rare, allowing
        --[[if temp == inner_url then
          print(inner_url, s)
          error("Could not unescape inner URL.")
        end]]
        inner_url = temp
      end
      if string.match(inner_url, "^https?://") then
        for k, v in pairs(get_news_url(urlparse.unescape(inner_url))) do
          results[k] = v
        end
      end
    end
    return results
  end

  local function queue_news(json)
    for k, v in pairs(json) do
      if type(v) == "string"
        and string.match(v, "^https?") then
        local param_url = get_news_url(v)
        if param_url then
          discover_item(discovered_news, urlparse.unescape(param_url))
        end
      elseif type(v) == "table" then
        queue_news(v)
      end
    end
  end

  if allowed(url)
    and status_code < 300 then
    html = read_file(file)
    if string.match(url, "%?d=1$") then
      local path = string.match(url, "^([^%?]+)%?")
      check(path)
      check(path .. "?si=1")
      if string.match(html, "dynamic link has [0-9]+ error")
        and (
          string.match(html, "is disallowed%.")
          or string.match(html, "We could not match param .+ with whitelisted URL patterns")
          or string.match(html, "is over the allowed limit of 7168%.")
        ) then
        print("This is a disallowed shortened URL.")
        expect_disallowed = true
      else
        expect_disallowed = false
      end
      if string.match(url, "/news/")
        or string.match(url, "/alerts/")
        or string.match(url, "/images/") then
        local json = get_redirect_data(html)
        local raw_news_urls = nil
        if expect_disallowed then
          local _, count = string.gsub(json[1][1][2], "'", "")
          --[[if count ~= 2 then
            error("Found " .. tostring(count) .. " occurences of '.")
          end]]
          raw_news_url = string.match(json[1][1][2], "'(.+)'")
        else
          raw_news_url = json[3]
        end
        for newurl, _ in pairs(get_news_url(raw_news_url)) do
          if not string.match(newurl, "^https?://[^/]+%.google%.") then
            discover_item(
              ({
                ["news"]=discovered_news,
                ["alerts"]=discovered_alerts,
                ["images"]=discovered_images,
              })[string.match(url, "^https?://[^/]+/([a-z]+)")],
              newurl
            )
          end
        end
      end
    end
    --[[if json then
      html = html .. " " .. flatten_json(json)
    end
    for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end]]
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  is_new_design = false
  if http_stat["len"] == 0
    and http_stat["statcode"] < 300 then
    print("Unexpected 0 bytes returned.")
    retry_url = true
    return false
  end
  if http_stat["statcode"] == 404
    and string.match(url["url"], "%?d=1$") then
    return false
  end
  if http_stat["statcode"] == 200
    and string.match(url["url"], "%?d=1$") then
    local json = get_redirect_data(read_file(http_stat["local_file"]))
    if json[3] and string.match(json[3], "^https?://[^/]*google%.[^%./]+/sorry") then
      print("Found redirect to sorry page. Accepting sorry page.")
      context["expect_sorry"] = string.match(url["url"], "([0-9a-zA-Z]+)%?")
    end
  end
  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if string.match(newloc, "^https?://[^/]*google%.[^%./]+/sorry")
      and context["expect_sorry"] ~= string.match(url["url"], "^https?://[^/]+/([0-9a-zA-Z]+)")
      --[[or string.match(newloc, "^https://accounts%.google%.com")]] then
      print("Google asks for a login, sleeping 20 minutes.")
      io.stdout:flush()
      os.execute("sleep 1200")
      retry_url = true
      return false
    end
  end
  local matched_pattern = false
  if string.match(url["url"], "^[^%?]+$")
    and status_code == 400 then
    local html = read_file(http_stat["local_file"])
    if string.match(html, "URL includes illegal chara?cter") then
      expect_disallowed = true
      print("URL contains illegal character.")
    end
  end
  for pattern, codes in pairs({
    ["^[^%?]+$"]={200,302,400,500},
    ["%?d=1$"]={200},
    ["%?si=1$"]={302,400,500},
    ["^https?://[^/]+/imgres%?"]={302,200,400}
  }) do
    if string.match(url["url"], pattern) then
      matched_pattern = true
      local good_code = false
      for _, code in pairs(codes) do
        if status_code == code
          and (
            (
              code ~= 400
              and code ~= 500
            )
            or expect_disallowed
            or (
              pattern == "^https?://[^/]+/imgres%?"
              and code == 400
            )
          ) then
          good_code = true
        end
      end
      if not good_code then
        print("Found a bad code.")
        retry_url = true
        return false
      end
    end
  end
  if not matched_pattern then
    print("Found unexpected URL.")
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC, previously aborted.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end
  
  if is_new_design then
    return wget.actions.EXIT
  end

  -- 8 is higher than the current max tries
  if seen_200[url["url"]] and seen_200[url["url"]] > 8 then
    print("Received data incomplete.")
    abort_item()
    return wget.actions.EXIT
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0
    and string.match(url["url"], "^https?://[^/:]+:[0-9]+/") then
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 5
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 then
      if not seen_200[url["url"]] then
        seen_200[url["url"]] = 0
      end
      seen_200[url["url"]] = seen_200[url["url"]] + 1
    end
    downloaded[url["url"]] = true
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    --["goo-gl-"] = discovered_items,
    --["urls-"] = discovered_outlinks,
    ["goo-gl-news-xpbxx8latirznfut"] = discovered_news,
    ["goo-gl-alerts-zqaa3uc1s3phzj2r"] = discovered_alerts,
    ["goo-gl-images-gsr58xiv808heid1"] = discovered_images,
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


