#!/usr/bin/env python3
"""Builds observability/dashboards/robot-shop-logs.json, the logs dashboard.

Same idea as build_dashboard.py (dashboard as code): edit below, run

    python3 observability/dashboards/build_logs_dashboard.py

and commit both files. Everything here is a LogQL query against Loki, using
the labels Fluent Bit adds (observability/logging/shape-log.lua):
namespace, service, container, level.
"""
import json
from pathlib import Path

DS = {"type": "loki", "uid": "loki"}
# every query starts from the same stream selector, driven by the variables
SHOP = '{namespace="robot-shop", service=~"$service", level=~"$level"}'
SEARCH = '|~ "(?i)$search"'

# the same colour for the same level in every panel
LEVEL_COLOURS = {"error": "red", "warn": "orange", "info": "green",
                 "debug": "blue", "unknown": "text"}


def level_overrides():
    return [{"matcher": {"id": "byName", "options": level},
             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": colour}}]}
            for level, colour in LEVEL_COLOURS.items()]


def target(expr, legend="", query_type="range"):
    return {"refId": "A", "datasource": DS, "expr": expr,
            "legendFormat": legend, "queryType": query_type}


panels = [
    {
        "id": 1, "type": "timeseries",
        "title": "Log lines per second by level",
        "description": "How much each level is logging. A jump in red is usually the "
                       "first sign something broke.",
        "datasource": DS,
        "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
        "targets": [target(f"sum by (level) (rate({SHOP} {SEARCH} [$__auto]))", "{{level}}")],
        "fieldConfig": {"defaults": {"unit": "short",
                                     "custom": {"drawStyle": "bars", "fillOpacity": 70,
                                                "stacking": {"mode": "normal"}}},
                        "overrides": level_overrides()},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    },
    {
        "id": 2, "type": "timeseries",
        "title": "Errors and warnings by service",
        "description": "Which service is complaining. Matches the error panels on the "
                       "Requests/Errors/Latency dashboard, seen from the logs side.",
        "datasource": DS,
        "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
        "targets": [target(
            'sum by (service) (count_over_time({namespace="robot-shop", service=~"$service", '
            f'level=~"error|warn"}} {SEARCH} [$__auto]))', "{{service}}")],
        "fieldConfig": {"defaults": {"unit": "short",
                                     "custom": {"drawStyle": "bars", "fillOpacity": 70,
                                                "stacking": {"mode": "normal"}}},
                        "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    },
    {
        "id": 3, "type": "logs",
        "title": "Log lines (newest first)",
        "description": "The lines themselves. Filter with the Service, Level and Search "
                       "boxes at the top. Click a line to see its labels and pod.",
        "datasource": DS,
        "gridPos": {"x": 0, "y": 8, "w": 24, "h": 16},
        "targets": [target(f"{SHOP} {SEARCH}")],
        "options": {"showTime": True, "showLabels": False, "showCommonLabels": False,
                    "wrapLogMessage": True, "prettifyLogMessage": False,
                    "enableLogDetails": True, "sortOrder": "Descending",
                    "dedupStrategy": "none"},
    },
]

dashboard = {
    "uid": "robot-shop-logs",
    "title": "Robot Shop - Logs",
    "description": "Logs from every Robot Shop service, collected by Fluent Bit and "
                   "stored in Loki. Built by observability/dashboards/build_logs_dashboard.py.",
    "tags": ["robot-shop", "logs", "capstone-2"],
    "timezone": "browser",
    "editable": True,
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [
        {
            "name": "service", "label": "Service", "type": "query",
            "datasource": DS,
            # every value of the "service" label Loki has seen in robot-shop
            "query": {"type": 1, "label": "service", "stream": '{namespace="robot-shop"}',
                      "refId": "LokiVariableQueryEditor-VariableQuery"},
            "refresh": 2, "sort": 1,
            "multi": True, "includeAll": True, "allValue": ".+",
            "current": {"text": ["All"], "value": ["$__all"]},
        },
        {
            "name": "level", "label": "Level", "type": "custom",
            "query": "error,warn,info,debug,unknown",
            "multi": True, "includeAll": True, "allValue": ".+",
            "current": {"text": ["All"], "value": ["$__all"]},
            "options": [],
        },
        {
            "name": "search", "label": "Search (text or regex)", "type": "textbox",
            "query": "", "current": {"text": "", "value": ""},
        },
    ]},
    "annotations": {"list": []},
    "links": [{"title": "Requests, Errors, Latency", "type": "dashboards",
               "tags": ["red"], "asDropdown": False, "keepTime": True}],
    "panels": panels,
}

out = Path(__file__).with_name("robot-shop-logs.json")
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {out} ({len(panels)} panels)")
