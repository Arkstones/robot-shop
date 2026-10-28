-- shape-log.lua - runs inside Fluent Bit for every container log line.
--
-- It turns Fluent Bit's record (the raw line plus the "kubernetes" block the
-- kubernetes filter added) into the few fields Loki needs:
--
--   namespace, service, container, level   -> Loki labels (what you filter on)
--   pod                                    -> structured metadata (searchable,
--                                             but not a label: pod names change
--                                             on every restart)
--   log                                    -> the original line, untouched
--
-- The shop's services are written in five languages and none of them agree on
-- how to write a log level, so level_of() below reads each style and maps it
-- to one of: error, warn, info, debug, unknown.

-- words some services use, mapped to my five levels
local WORDS = {
  fatal = "error", critical = "error", crit = "error", severe = "error",
  emerg = "error", alert = "error", error = "error", err = "error",
  warning = "warn", warn = "warn",
  notice = "info", note = "info", info = "info", system = "info",
  debug = "debug", trace = "debug", fine = "debug",
}

-- pino (cart, catalogue, user) can also write numbers
local PINO_NUMBERS = {
  ["10"] = "debug", ["20"] = "debug", ["30"] = "info",
  ["40"] = "warn", ["50"] = "error", ["60"] = "error",
}

-- MongoDB writes one letter in "s"
local MONGO_LETTERS = { F = "error", E = "error", W = "warn", I = "info" }

local function from_http_status(code)
  local n = tonumber(code)
  if not n then return nil end
  if n >= 500 then return "error" end
  if n >= 400 then return "warn" end
  return "info"
end

local function level_of(line)
  -- 1. structured logs: pino (Node.js services), MongoDB, logfmt
  local word = line:match('"level"%s*:%s*"(%a+)"')
  if word and WORDS[word:lower()] then return WORDS[word:lower()] end
  local num = line:match('"level"%s*:%s*(%d+)')
  if num and PINO_NUMBERS[num] then return PINO_NUMBERS[num] end
  local letter = line:match('"s"%s*:%s*"(%u)%d?"')
  if letter then return MONGO_LETTERS[letter] or "debug" end
  --    logfmt (Loki, Grafana, Prometheus):  level=info msg=...
  local logfmt = line:match('^[^"]-level=(%a+)')
  if logfmt and WORDS[logfmt:lower()] then return WORDS[logfmt:lower()] end

  -- 2. request logs: the HTTP status code decides
  --    nginx (web):  "GET /api/cart/... HTTP/1.1" 504 ...
  local status = line:match('"%u+ [^"]* HTTP/[%d%.]+" (%d%d%d) ')
  --    uwsgi (payment):  ... (HTTP/1.1 500) ...
  status = status or line:match('%(HTTP/[%d%.]+ (%d%d%d)%)')
  --    Apache (ratings):  "GET /api/ratings/... HTTP/1.1" 200 ...  (same as nginx)
  if status then return from_http_status(status) end

  -- 3. a level word near the start of the line, in brackets or capitals:
  --    "[error]" nginx/RabbitMQ, "[Warning]" MySQL,
  --    "ERROR in payment" Flask, "2026-.. INFO 1 --- " Spring (shipping)
  local head = line:sub(1, 160)
  local bracketed = head:match('%[(%a+)%]')
  if bracketed and WORDS[bracketed:lower()] then return WORDS[bracketed:lower()] end
  for capital in head:gmatch('%f[%a](%u%u%u+)%f[%A]') do
    local level = WORDS[capital:lower()]
    if level then return level end
  end

  -- 4. Java stack traces arrive one line at a time
  if line:match('^%s+at [%w%.$_]+%(') or line:match('^Caused by: ')
     or line:match('^[%w%.]+Exception') then
    return "error"
  end

  return "unknown"
end

function shape(tag, timestamp, record)
  local k8s = record["kubernetes"] or {}
  local labels = k8s["labels"] or {}
  local line = record["log"] or ""

  local out = {
    log = line,
    namespace = k8s["namespace_name"] or "unknown",
    -- robot-shop pods carry a "service" label (cart, payment...); most other
    -- charts use app.kubernetes.io/name; the container name is the fallback
    service = labels["service"] or labels["app.kubernetes.io/name"]
              or labels["app"] or k8s["container_name"] or "unknown",
    container = k8s["container_name"] or "unknown",
    pod = k8s["pod_name"] or "unknown",
    level = level_of(line),
  }
  -- 1 = record changed, keep the original timestamp
  return 1, timestamp, out
end
