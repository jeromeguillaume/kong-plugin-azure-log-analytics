local Queue = require "kong.tools.queue"
local cjson = require "cjson"
local url = require "socket.url"
local http = require "resty.http"
local sandbox = require "kong.tools.sandbox".sandbox
local kong_meta = require "kong.meta"


local kong = kong
local ngx = ngx
local encode_base64 = ngx.encode_base64
local tostring = tostring
local tonumber = tonumber
local fmt = string.format
local pairs = pairs
local max = math.max


local sandbox_opts = { env = { kong = kong, ngx = ngx } }

-----------------------------------------------------------------------
-- Encoding Data (not UTF-8) in BASE64
--
-- Lua 5.1+ base64 v3.0 (c) 2009 by Alex Kloss <alexthkloss@web.de>
-- licensed under the terms of the LGPL2
-----------------------------------------------------------------------
local base_dict = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function enc(data)
    return ((data:gsub('.', function(x) 
        local r,base_dictb='',x:byte()
        for i=8,1,-1 do r=r..(base_dict%2^i-base_dict%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-----------------------------------------------------------------------
-- Decoding BASE64 data (not UTF-8)
-- As it's not UTF-8, the 'ngx.decode_base64' doesn't work
--
-- Lua 5.1+ base64 v3.0 (c) 2009 by Alex Kloss <alexthkloss@web.de>
-- licensed under the terms of the LGPL2
-----------------------------------------------------------------------
function dec(data)
    data = string.gsub(data, '[^'..base_dict..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(base_dict:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

---------------------------------------------------------------------------------------------------
-- Build the HMAC signature to call the Azure Data Collector REST API
-- The Signature is based on this format: Base64(HMAC-SHA256(UTF8(StringToSign)))
-- The 'azurePrimaryKey' used for HMAC-SHA256 is encoded in BASE64 (not UTF-8)
---------------------------------------------------------------------------------------------------
function azureBuildSignature(method, content_type, azureWorkspaceId, azurePrimaryKey, xMsDate, azureContentLength, azureResource)
  local azurePrimaryKey_decoded_base64 = dec(azurePrimaryKey)
  -- Build a signingString following this example:
  --  POST
  --  100
  --  application/json
  --  x-ms-date:Thu, 29 Jun 2023 10:15:22 GMT
  --  /api/logs
  local openssl_hmac = require "resty.openssl.hmac"

  local signingString =   method .. '\n' ..
                          tostring(azureContentLength) .. '\n' .. 
                          content_type .. '\n' .. 
                          'x-ms-date:' .. xMsDate .. '\n' .. 
                          azureResource
  local hmac = openssl_hmac.new(azurePrimaryKey_decoded_base64, "sha256"):final(signingString)
  local encode_base64 = ngx.encode_base64
  local encodedHmacHash = encode_base64 (hmac)
  return "SharedKey " .. azureWorkspaceId .. ":" .. encodedHmacHash
end


-- Create a function that concatenates multiple JSON objects into a JSON array.
-- This saves us from rendering all entries into one large JSON string.
-- Each invocation of the function returns the next bit of JSON, i.e. the opening
-- bracket, the entries, delimiting commas and the closing bracket.
local function make_json_array_payload_function(conf, entries)
  if conf.queue.max_batch_size == 1 then
    return #entries[1], entries[1]
  end

  local nentries = #entries

  local content_length = 1
  for i = 1, nentries do
    content_length = content_length + #entries[i] + 1
  end

  local i = 0
  local last = max(2, nentries * 2 + 1)
  return content_length, function()
    i = i + 1

    if i == 1 then
      return '['

    elseif i < last then
      return i % 2 == 0 and entries[i / 2] or ','

    elseif i == last then
      return ']'
    end
  end
end


local parsed_urls_cache = {}
-- Parse host url.
-- @param `url` host url
-- @return `parsed_url` a table with host details:
-- scheme, host, port, path, query
local function parse_url(host_url)
  local parsed_url = parsed_urls_cache[host_url]

  if parsed_url then
    return parsed_url
  end

  parsed_url = url.parse(host_url)
  if not parsed_url.port then
    if parsed_url.scheme == "http" then
      parsed_url.port = 80

    elseif parsed_url.scheme == "https" then
      parsed_url.port = 443
    end
  end
  if not parsed_url.path then
    parsed_url.path = "/"
  end

  parsed_urls_cache[host_url] = parsed_url

  return parsed_url
end


-- Sends the provided entries to the configured plugin host
-- @return true if everything was sent correctly, falsy if error
-- @return error message if there was an error
local function send_entries(conf, entries)
  local content_length, payload
  if conf.queue.max_batch_size == 1 then
    assert(
      #entries == 1,
      "internal error, received more than one entry in queue handler even though max_batch_size is 1"
    )
    content_length = #entries[1]
    payload = entries[1]
  else
    content_length, payload = make_json_array_payload_function(conf, entries)
  end

  local method = conf.method
  local timeout = conf.timeout
  local keepalive = conf.keepalive
  local content_type = conf.content_type
  local azure_http_endpoint = conf.azure_http_endpoint

  local parsed_url = parse_url(azure_http_endpoint)
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)
  local curTime = os.time()
  local xMsDate = os.date('!%a, %d %b %Y %H:%M:%S GMT', curTime)

  -- Extract from the Endpoint URL the Azure Workspace Id (1st part of Domain name)
  -- Example: 
  --  azure_http_endpoint = https://b5f9e1c0-724b-4c62-9296-b02c0f7b0d19.ods.opinsights.azure.com
  --  azure_workspace_id = b5f9e1c0-724b-4c62-9296-b02c0f7b0d19
  local azure_workspace_id
  local b1, e1 = string.find(azure_http_endpoint, "://")
  local b2, e2 = string.find(azure_http_endpoint, "%.", e1)
  -- If we failed to find azure_workspace_id
  if e1 == nil or b2 == nil then
    kong.log.err ( "Unable to extract Azure Workspace Id on: " .. azure_http_endpoint )
    return nil, "Unable to extract Azure Workspace Id on: " .. azure_http_endpoint
  end
  azure_workspace_id = string.sub(azure_http_endpoint, e1 + 1, b2 - 1)

  local httpc = http.new()
  httpc:set_timeout(timeout)
  local azureSignature = azureBuildSignature (method, conf.content_type, azure_workspace_id, conf.azure_primary_key, xMsDate, content_length, conf.azure_resource)
  local headers = {
    ["Host"] = host,
    ["Content-Type"] = content_type,
    ["Content-Length"] = content_length,
    ["Authorization"] = azureSignature,
    ["Log-Type"] = conf.azure_log_type,
    ["x-ms-date"] = xMsDate
  }
  if conf.headers then
    for h, v in pairs(conf.headers) do
      headers[h] = headers[h] or v -- don't override Host, Content-Type, Content-Length, Authorization
    end
  end

  local log_server_url = fmt("%s://%s:%d%s%s", parsed_url.scheme, host, port, parsed_url.path, conf.azure_resource)

  local res, err = httpc:request_uri(log_server_url, {
    method = method,
    headers = headers,
    query = 'api-version=' .. conf.azure_api_version,
    body = payload,
    keepalive_timeout = keepalive,
    ssl_verify = false,
  })
  if not res then
    return nil, "failed request to " .. host .. ":" .. tostring(port) .. ": " .. err
  end

  -- always read response body, even if we discard it without using it on success
  local response_body = res.body

  kong.log.debug(fmt("azure-log-analytics sent data log server, %s:%s HTTP status %d",
    host, port, res.status))

  if res.status < 300 then
    return true

  else
    return nil, "request to " .. host .. ":" .. tostring(port)
      .. " returned status code " .. tostring(res.status) .. " and body "
      .. response_body
  end
end


local AzureLogAnalytics = {
  PRIORITY = 25,
  VERSION = '1.0.0',
}


-- Create a queue name from the same legacy parameters that were used in the
-- previous queue implementation.  This ensures that azure-log-analytics instances that
-- have the same log server parameters are sharing a queue.  It deliberately
-- uses the legacy parameters to determine the queue name, even though they may
-- be nil in newer configurations.  Note that the modernized queue related
-- parameters are not included in the queue name determination.
local function make_queue_name(conf)
  return fmt("%s:%s:%s:%s:%s:%s",
    conf.azure_http_endpoint .. conf.azure_resource,
    conf.method,
    conf.content_type,
    conf.timeout,
    conf.keepalive,
    conf.retry_count,
    conf.queue_size,
    conf.flush_timeout)
end


function AzureLogAnalytics:log(conf)
  if conf.custom_fields_by_lua then
    local set_serialize_value = kong.log.set_serialize_value
    for key, expression in pairs(conf.custom_fields_by_lua) do
      set_serialize_value(key, sandbox(expression, sandbox_opts)())
    end
  end

  local queue_conf = Queue.get_plugin_params("azure-log-analytics", conf, make_queue_name(conf))
  kong.log.debug("Queue name automatically configured based on configuration parameters to: ", queue_conf.name)

  local ok, err = Queue.enqueue(
    queue_conf,
    send_entries,
    conf,
    cjson.encode(kong.log.serialize())
  )
  if not ok then
    kong.log.err("Failed to enqueue log entry to log server: ", err)
  end
end

return AzureLogAnalytics