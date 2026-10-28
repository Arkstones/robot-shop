#!/usr/bin/env python3
"""Builds observability/dashboards/robot-shop-red.json, the Grafana dashboard.

The JSON file is what Grafana loads (dashboard as code). This script exists so
the dashboard is easy to read and change: edit the panels below, run

    python3 observability/dashboards/build_dashboard.py

and commit both files. RED = Rate (requests/s), Errors, Duration (latency).
All numbers come from the web gateway, which every request passes through.
"""
import json
from pathlib import Path

DS = {"type": "prometheus", "uid": "${datasource}"}
REQ = 'nginx_http_response_count_total{service=~"$service"}'
REQ_5XX = 'nginx_http_response_count_total{service=~"$service", status=~"5.."}'
LAT = 'nginx_http_response_time_seconds_hist_bucket{service=~"$service"}'
RANGE = "[$__rate_interval]"

_next_id = 0


def panel(kind, title, description, targets, grid, unit, **extra):
    global _next_id
    _next_id += 1
    p = {
        "id": _next_id,
        "type": kind,
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": dict(zip(("x", "y", "w", "h"), grid)),
        "targets": [
            {"refId": chr(65 + i), "datasource": DS, "expr": expr, "legendFormat": legend}
            for i, (expr, legend) in enumerate(targets)
        ],
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {},
    }
    if kind == "timeseries":
        p["fieldConfig"]["defaults"]["custom"] = {"lineWidth": 2, "fillOpacity": 10}
        p["options"] = {"legend": {"displayMode": "table", "placement": "right",
                                   "calcs": ["mean", "max", "lastNotNull"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}}
    if kind == "stat":
        p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"]},
                        "colorMode": "background", "graphMode": "area"}
    for key, value in extra.items():
        if key == "thresholds":
            p["fieldConfig"]["defaults"]["thresholds"] = {
                "mode": "absolute",
                "steps": [{"color": c, "value": v} for v, c in value]}
        elif key == "decimals":
            p["fieldConfig"]["defaults"]["decimals"] = value
    return p


def row(title, y):
    global _next_id
    _next_id += 1
    return {"id": _next_id, "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


def quantile(q):
    return f"histogram_quantile({q}, sum by (service, le) (rate({LAT}{RANGE})))"


panels = [
    row("Right now (whole shop)", 0),
    panel("stat", "Requests / second",
          "All requests through the web gateway for the selected services.",
          [(f"sum(rate({REQ}{RANGE}))", "requests/s")],
          (0, 1, 6, 4), "reqps", decimals=1),
    panel("stat", "Error rate (5xx)",
          "Share of requests that failed with a server error (HTTP 5xx). "
          "This is the number the availability SLO is built on.",
          [(f"sum(rate({REQ_5XX}{RANGE})) / sum(rate({REQ}{RANGE}))", "errors")],
          (6, 1, 6, 4), "percentunit", decimals=2,
          thresholds=[(None, "green"), (0.01, "orange"), (0.05, "red")]),
    panel("stat", "Latency p95",
          "95% of requests finished faster than this.",
          [(f"histogram_quantile(0.95, sum by (le) (rate({LAT}{RANGE})))", "p95")],
          (12, 1, 6, 4), "s", decimals=3,
          thresholds=[(None, "green"), (0.5, "orange"), (1, "red")]),
    panel("stat", "Items sold / hour",
          "Business view, from payment's own /metrics: robots sold in the last hour.",
          [('sum(increase({__name__=~"sold_count|sold_count_total", namespace="robot-shop"}[1h]))',
            "items")],
          (18, 1, 6, 4), "short", decimals=0),

    row("Requests (Rate)", 5),
    panel("timeseries", "Requests per second by service",
          "How busy each service is. Requests are counted at the web gateway, "
          "which routes /api/<service>/ to each backend.",
          [(f"sum by (service) (rate({REQ}{RANGE}))", "{{service}}")],
          (0, 6, 12, 8), "reqps"),
    panel("timeseries", "Requests per second by status code",
          "2xx = OK, 4xx = client mistakes (e.g. an unknown product), 5xx = server errors.",
          [(f"sum by (status) (rate({REQ}{RANGE}))", "{{status}}")],
          (12, 6, 12, 8), "reqps"),

    row("Errors", 14),
    panel("timeseries", "Error rate (5xx) by service",
          "Share of each service's requests that failed with a server error. "
          "load-gen deliberately calls a broken payment partner, so payment "
          "always shows some errors.",
          [(f"sum by (service) (rate({REQ_5XX}{RANGE})) / sum by (service) (rate({REQ}{RANGE}))",
            "{{service}}")],
          (0, 15, 12, 8), "percentunit",
          thresholds=[(None, "green"), (0.01, "orange"), (0.05, "red")]),
    panel("timeseries", "5xx errors per second by service",
          "The same errors as absolute numbers.",
          [(f"sum by (service) (rate({REQ_5XX}{RANGE}))", "{{service}}")],
          (12, 15, 12, 8), "reqps"),

    row("Latency (Duration)", 23),
    panel("timeseries", "Latency p95 by service",
          "95% of each service's requests finished faster than this "
          "(measured from nginx receiving the request to sending the last byte).",
          [(quantile(0.95), "{{service}}")],
          (0, 24, 12, 8), "s"),
    panel("timeseries", "Latency p50 / p95 / p99 (selected services)",
          "Typical (p50), slow (p95) and slowest (p99) request times together.",
          [(f"histogram_quantile({q}, sum by (le) (rate({LAT}{RANGE})))", name)
           for q, name in ((0.5, "p50"), (0.95, "p95"), (0.99, "p99"))],
          (12, 24, 12, 8), "s"),
]

dashboard = {
    "uid": "robot-shop-red",
    "title": "Robot Shop - Requests, Errors, Latency",
    "description": "RED metrics for web, catalogue, cart and payment, measured at the "
                   "web gateway. Built by observability/dashboards/build_dashboard.py.",
    "tags": ["robot-shop", "red", "capstone-2"],
    "timezone": "browser",
    "editable": True,
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [
        {
            "name": "datasource", "label": "Data source", "type": "datasource",
            "query": "prometheus", "current": {"text": "Prometheus", "value": "prometheus"},
        },
        {
            "name": "service", "label": "Service", "type": "custom",
            # the four services the brief focuses on; "All" adds the rest
            "query": "web,catalogue,cart,payment",
            "multi": True, "includeAll": True, "allValue": ".+",
            "current": {"text": ["web", "catalogue", "cart", "payment"],
                        "value": ["web", "catalogue", "cart", "payment"]},
            "options": [],
        },
    ]},
    "annotations": {"list": []},
    "links": [],
    "panels": panels,
}

out = Path(__file__).with_name("robot-shop-red.json")
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {out} ({len(panels)} panels)")
