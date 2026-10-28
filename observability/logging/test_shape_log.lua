-- test_shape_log.lua - checks shape-log.lua against real lines from the shop.
--
-- Run:  lua observability/logging/test_shape_log.lua
-- (from the repo root; CI runs it too)
--
-- Each example is written in the format that service really uses (taken from
-- its code and image: pino, Flask/uwsgi, Spring Boot, my nginx log_format...),
-- with the level I expect shape-log.lua to give it. The lines further down
-- are real ones copied out of Loki once it was running.

dofile("observability/logging/shape-log.lua")

local examples = {
  -- cart / catalogue / user: pino JSON
  { "cart", '{"level":"info","time":1761660000000,"pid":1,"msg":"Got hash"}', "info" },
  { "cart", '{"level":"error","time":1761660000000,"msg":"ERROR connecting to Redis"}', "error" },
  { "user", '{"level":30,"time":1761660000000,"msg":"request completed"}', "info" },
  { "user", '{"level":50,"time":1761660000000,"msg":"failed"}', "error" },
  -- web: my nginx "timed" access log; the status code decides
  { "web", '10.0.1.5 - - [28/Oct/2026:14:02:11 +0000] "GET /api/catalogue/products HTTP/1.1" 200 1234 "-" "python-requests/2.32" "-" 0.012 0.011', "info" },
  { "web", '10.0.1.5 - - [28/Oct/2026:14:02:11 +0000] "GET /api/ratings/api/fetch/RED HTTP/1.1" 504 167 "-" "python-requests/2.32" "-" 60.001 60.000', "error" },
  { "web", '10.0.1.5 - - [28/Oct/2026:14:02:11 +0000] "GET /api/catalogue/product/NOPE HTTP/1.1" 404 9 "-" "-" "-" 0.004 0.004', "warn" },
  -- web: nginx's own error log
  { "web", '2026/10/28 14:02:11 [error] 29#29: *812 upstream timed out (110: Connection timed out)', "error" },
  -- payment: Flask messages and uwsgi request lines
  { "payment", '[2026-10-28 14:02:11,123] ERROR in payment: 500 Server Error from partner-57', "error" },
  { "payment", '[2026-10-28 14:02:11,123] INFO in payment: payment for 2f6d', "info" },
  { "payment", '[pid: 7|app: 0|req: 9/42] 10.0.2.9 () {40 vars in 512 bytes} [Wed Oct 28 14:02:11 2026] POST /pay/2f6d => generated 32 bytes in 120 msecs (HTTP/1.1 500) 2 headers in 81 bytes', "error" },
  { "payment", '[pid: 7|app: 0|req: 9/43] 10.0.2.9 () {40 vars in 512 bytes} [Wed Oct 28 14:02:12 2026] GET /health => generated 2 bytes in 1 msecs (HTTP/1.1 200) 2 headers in 79 bytes', "info" },
  -- shipping: Spring Boot, plus a Java stack trace line
  { "shipping", '2026-10-28 14:02:11.123  INFO 1 --- [nio-8080-exec-3] c.i.r.shipping.Controller : calc for 1234', "info" },
  { "shipping", '2026-10-28 14:02:11.123  WARN 1 --- [nio-8080-exec-3] o.h.engine.jdbc.spi.SqlExceptionHelper : SQL Error: 0', "warn" },
  { "shipping", '\tat com.instana.robotshop.shipping.Controller.caclc(Controller.java:91)', "error" },
  -- mongodb: JSON with a one-letter severity in "s"
  { "mongodb", '{"t":{"$date":"2026-10-28T14:02:11.123+00:00"},"s":"I","c":"NETWORK","id":22943,"msg":"Connection accepted"}', "info" },
  { "mongodb", '{"t":{"$date":"2026-10-28T14:02:11.123+00:00"},"s":"W","c":"CONTROL","id":22120,"msg":"Access control is not enabled"}', "warn" },
  -- mysql and rabbitmq: level in brackets
  { "mysql", '2026-10-28T14:02:11.123456Z 0 [Warning] [MY-011810] [Server] Insecure configuration', "warn" },
  { "mysql", '2026-10-28T14:02:11.123456Z 0 [System] [MY-010931] [Server] ready for connections', "info" },
  { "rabbitmq", '2026-10-28 14:02:11.123 [info] <0.273.0> Server startup complete', "info" },
  -- dispatch: Go's plain log.Printf, no level at all
  { "dispatch", '2026/10/28 14:02:11 order {"orderid": "2f6d"}', "info" },

  -- Real lines copied from Loki on my cluster (28 Oct 2026), after the first
  -- install showed dispatch "unknown", redis "unknown" and dispatch "error":
  { "dispatch", '2026/10/28 15:56:14 Creating child span', "info" },
  { "dispatch", '2026/10/28 15:56:14 Headers map[X-INSTANA-L:1 X-INSTANA-S:8a2c4a63f2308bd7 X-INSTANA-T:abf7471e70c3d615]', "info" },
  -- the Instana tracer built into the dispatch image, looking for an agent
  -- that doesn't exist: real errors, so they stay "error"
  { "dispatch", '2026/10/28 15:56:11 instana: ERROR: sender not ready', "error" },
  { "dispatch", '2026/10/28 15:56:07 instana: INFO: failed to send a request to http://169.254.1.1:42699/: Get "http://169.254.1.1:42699/": context deadline exceeded', "info" },
  { "redis", '1:M 28 Oct 15:51:58.886 * Background saving terminated with success', "info" },
  { "redis", '40:C 28 Oct 15:51:58.788 * DB saved on disk', "info" },
  { "redis", '1:M 28 Oct 15:51:58.886 # WARNING overcommit_memory is set to 0!', "warn" },
  { "rabbitmq", '2026-10-28 15:43:46.338 [error] <0.1092.0> closing AMQP connection <0.1092.0> (172.31.35.246:43504 -> 172.31.20.9:5672):', "error" },
  -- ...whose second line arrives separately with nothing to go on
  { "rabbitmq", 'missed heartbeats from client, timeout: 60s', "unknown" },
  -- Loki and Grafana themselves: logfmt
  { "loki", 'level=warn ts=2026-10-28T14:02:11Z caller=pool.go:42 msg="slow query"', "warn" },
}

local failures = 0
for i, example in ipairs(examples) do
  local service, line, want = example[1], example[2], example[3]
  local record = {
    log = line,
    stream = "stdout",
    kubernetes = {
      namespace_name = "robot-shop",
      pod_name = service .. "-7d9f8c6b5-abcde",
      container_name = service,
      labels = { service = service },
    },
  }
  local code, _, out = shape("kube.test", 0, record)
  local ok = code == 1 and out.level == want and out.service == service
             and out.namespace == "robot-shop" and out.log == line
             and out.pod == service .. "-7d9f8c6b5-abcde" and out.kubernetes == nil
  if ok then
    print(string.format("ok    %-9s %-7s %s", service, out.level, line:sub(1, 60)))
  else
    failures = failures + 1
    print(string.format("FAIL  %-9s got %-7s want %-7s %s", service, tostring(out.level), want, line:sub(1, 60)))
  end
end

-- a pod with no "service" label falls back to app.kubernetes.io/name
local _, _, out = shape("kube.test", 0, { log = "level=info msg=hi", kubernetes = {
  namespace_name = "logging", pod_name = "loki-0", container_name = "loki",
  labels = { ["app.kubernetes.io/name"] = "loki" } } })
if out.service ~= "loki" then
  failures = failures + 1
  print("FAIL  fallback service label: got " .. tostring(out.service))
end

print(string.format("\n%d examples, %d failed", #examples + 1, failures))
os.exit(failures == 0 and 0 or 1)
