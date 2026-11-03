#!/usr/bin/env python3
"""Generates the Molly Grafana dashboards. Output dir is argv[1]."""
import json
import os
import sys

DS = {"type": "prometheus", "uid": "molly-prometheus"}
S = 'user=~"$user",host=~"$host"'
BLUE = "#2a78d6"
ORANGE = "#eb6834"
GOOD, WARN, SERIOUS, CRIT = "#0ca30c", "#fab219", "#ec835a", "#d03b3b"
GRAY = "#898781"
RI = "$__rate_interval"


def sel(extra=""):
    return "{" + S + ("," + extra if extra else "") + "}"


def m(name, extra=""):
    return name + sel(extra)


class Dash:
    def __init__(self, uid, title, description, time_from="now-24h"):
        self.uid, self.title, self.description = uid, title, description
        self.time_from = time_from
        self.annotations = []
        self.panels = []
        self.x = 0
        self.y = 0
        self.rowh = 0
        self.next_id = 1

    def _place(self, w, h):
        if self.x + w > 24:
            self.y += self.rowh
            self.x = 0
            self.rowh = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.rowh = max(self.rowh, h)
        return pos

    def row(self, title):
        self.y += self.rowh
        self.x = 0
        self.rowh = 0
        self.panels.append({
            "id": self._id(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": [],
        })
        self.y += 1

    def _id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def add(self, panel, w, h):
        panel["id"] = self._id()
        panel["gridPos"] = self._place(w, h)
        panel.setdefault("datasource", DS)
        self.panels.append(panel)

    def json(self):
        return {
            "uid": self.uid, "title": self.title, "description": self.description,
            "tags": ["molly"], "timezone": "browser", "schemaVersion": 39, "version": 1,
            "editable": True, "graphTooltip": 1, "refresh": "30s",
            "time": {"from": self.time_from, "to": "now"},
            "timepicker": {}, "annotations": {"list": self.annotations}, "links": [],
            "templating": {"list": [
                {
                    "name": "user", "label": "user", "type": "query", "datasource": DS,
                    "query": {"query": "label_values(molly_up, user)", "refId": "user"},
                    "definition": "label_values(molly_up, user)", "refresh": 2,
                    "multi": True, "includeAll": True, "allValue": ".*",
                    "current": {"selected": True, "text": "All", "value": "$__all"},
                    "sort": 1,
                },
                {
                    "name": "host", "label": "host", "type": "query", "datasource": DS,
                    "query": {"query": 'label_values(molly_up{user=~"$user"}, host)', "refId": "host"},
                    "definition": 'label_values(molly_up{user=~"$user"}, host)', "refresh": 2,
                    "multi": True, "includeAll": True, "allValue": ".*",
                    "current": {"selected": True, "text": "All", "value": "$__all"},
                    "sort": 1,
                },
            ]},
            "panels": self.panels,
        }


def targets(items, instant=False, fmt=None):
    out = []
    for i, item in enumerate(items):
        expr, legend = item if isinstance(item, tuple) else (item, "")
        t = {"refId": chr(ord("A") + i), "datasource": DS, "expr": expr,
             "legendFormat": legend or "__auto"}
        if instant:
            t["instant"] = True
            t["range"] = False
        if fmt:
            t["format"] = fmt
        out.append(t)
    return out


def fixed(color=BLUE):
    return {"mode": "fixed", "fixedColor": color}


PALETTE = {"mode": "palette-classic-by-name"}


def thresholds(steps):
    """steps: list of (value or None, color)."""
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}


def stat(d, title, expr, unit="short", w=4, h=4, decimals=None, time_from=None,
         spark=True, color=None, th=None, text_mode="auto", legend="", desc="",
         mappings=None, min_=None, max_=None, instant=False):
    defaults = {"unit": unit, "color": color or fixed(), "mappings": mappings or []}
    if decimals is not None:
        defaults["decimals"] = decimals
    if th:
        defaults["color"] = {"mode": "thresholds"}
        defaults["thresholds"] = thresholds(th)
    if min_ is not None:
        defaults["min"] = min_
    if max_ is not None:
        defaults["max"] = max_
    p = {
        "type": "stat", "title": title, "description": desc,
        "targets": targets([(expr, legend)], instant=instant),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value" if th else "none",
            "graphMode": "area" if spark else "none", "textMode": text_mode,
            "justifyMode": "auto", "orientation": "auto",
        },
    }
    if time_from:
        p["timeFrom"] = time_from
        p["hideTimeOverride"] = True
    d.add(p, w, h)


def today_stat(d, title, expr, unit="short", w=4, h=4, decimals=0, desc=""):
    """Counter-based 'since local midnight' tile: relative time now/d makes $__range the elapsed day."""
    stat(d, title, expr, unit=unit, w=w, h=h, decimals=decimals, time_from="now/d",
         spark=False, desc=desc or "Since local midnight.", instant=True)


def timeseries(d, title, items, unit="short", w=12, h=8, stack=False, bars=False,
               min_=None, max_=None, desc="", color=None, fill=10, th=None, decimals=None):
    custom = {
        "drawStyle": "bars" if bars else "line", "lineWidth": 2,
        "fillOpacity": 60 if bars else fill, "showPoints": "never", "spanNulls": False,
        "lineInterpolation": "linear", "axisPlacement": "auto",
        "stacking": {"mode": "normal" if stack else "none", "group": "A"},
        "gradientMode": "none",
    }
    if bars:
        custom["lineWidth"] = 0
    defaults = {"unit": unit, "color": color or PALETTE, "custom": custom, "mappings": []}
    if min_ is not None:
        defaults["min"] = min_
    if max_ is not None:
        defaults["max"] = max_
    if decimals is not None:
        defaults["decimals"] = decimals
    if th:
        defaults["thresholds"] = thresholds(th)
    n = len(items)
    d.add({
        "type": "timeseries", "title": title, "description": desc,
        "targets": targets(items),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {"displayMode": "table" if n > 1 else "list", "placement": "bottom",
                       "showLegend": n > 1, "calcs": ["lastNotNull"] if n > 1 else []},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }, w, h)


def bargauge(d, title, items, unit="short", w=12, h=8, desc="", th=None, min_=0, max_=None,
             color=None, decimals=None):
    defaults = {"unit": unit, "color": color or fixed(), "min": min_, "mappings": []}
    if max_ is not None:
        defaults["max"] = max_
    if decimals is not None:
        defaults["decimals"] = decimals
    if th:
        defaults["color"] = {"mode": "thresholds"}
        defaults["thresholds"] = thresholds(th)
    d.add({
        "type": "bargauge", "title": title, "description": desc,
        "targets": targets(items, instant=True),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "orientation": "horizontal", "displayMode": "basic", "valueMode": "color",
            "showUnfilled": True, "namePlacement": "left", "sizing": "auto", "minVizHeight": 16,
        },
    }, w, h)


def piechart(d, title, items, unit="short", w=8, h=8, desc=""):
    d.add({
        "type": "piechart", "title": title, "description": desc,
        "targets": targets(items, instant=True),
        "fieldConfig": {"defaults": {"unit": unit, "color": PALETTE, "mappings": []}, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "pieType": "donut", "displayLabels": [],
            "legend": {"displayMode": "table", "placement": "right", "showLegend": True,
                       "values": ["value", "percent"]},
            "tooltip": {"mode": "single"},
        },
    }, w, h)


def mapping(pairs):
    """pairs: list of (value, text, color)."""
    opts = {str(v): {"text": t, "color": c, "index": i} for i, (v, t, c) in enumerate(pairs)}
    return [{"type": "value", "options": opts}]


def state_timeline(d, title, items, mappings=None, w=24, h=6, desc="", color=None, unit="short"):
    defaults = {
        "unit": unit, "color": color or PALETTE, "mappings": mappings or [],
        "custom": {"fillOpacity": 80, "lineWidth": 0},
    }
    if mappings:
        defaults["color"] = {"mode": "thresholds"}
        defaults["thresholds"] = thresholds([(None, GRAY)])
    d.add({
        "type": "state-timeline", "title": title, "description": desc,
        "targets": targets(items),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "mergeValues": True, "showValue": "auto", "alignValue": "left", "rowHeight": 0.8,
            "legend": {"showLegend": bool(mappings), "displayMode": "list", "placement": "bottom"},
            "tooltip": {"mode": "single"},
        },
    }, w, h)


ACTIVE_MAP = mapping([(0, "idle", GRAY), (1, "active", BLUE)])
YESNO = lambda on, c=BLUE: mapping([(0, "no", GRAY), (1, on, c)])
PRESSURE_MAP = mapping([(1, "normal", GOOD), (2, "warn", WARN), (4, "critical", CRIT)])
THERMAL_MAP = mapping([(0, "nominal", GOOD), (1, "fair", WARN), (2, "serious", SERIOUS), (3, "critical", CRIT)])
FLOW_MAP = mapping([(0, "break", GRAY), (1, "shallow", WARN), (2, "flow", GOOD)])


def annotation(d, name, expr, color, title_format, text_format="", tag_keys="", step="15s", region=False):
    """A Prometheus annotation query: one marker (or region when the series stays non-zero) per sample."""
    d.annotations.append({
        "name": name, "datasource": DS, "enable": True, "hide": False, "iconColor": color,
        "expr": expr, "step": step, "titleFormat": title_format, "textFormat": text_format,
        "tagKeys": tag_keys, "useValueForTime": False,
    })


def text_panel(d, title, content, w=24, h=3, desc=""):
    d.add({
        "type": "text", "title": title, "description": desc,
        "options": {"mode": "markdown", "content": content},
    }, w, h)


def annotate_activity(d):
    annotation(d, "Commits", "changes(" + m("molly_git_last_commit_timestamp_seconds") + "[1m]) > 0",
               BLUE, "commit", "{{repo}}", tag_keys="repo")
    annotation(d, "Meetings", m("molly_meeting_active") + " == 1", ORANGE, "meeting", "mic or camera in use")
    annotation(d, "Screen locked", m("molly_screen_locked") + " == 1", GRAY, "locked", "screen locked")


def table(d, title, items, renames, w=24, h=9, desc="", units=None, exclude=None, sort_by=None):
    """items: instant queries sharing a label set; merged into one row per series."""
    exclude = {k: True for k in (exclude or [])}
    exclude.update({"Time": True, "user": True, "host": True, "job": True, "instance": True,
                    "__name__": True})
    overrides = []
    for col, unit in (units or {}).items():
        overrides.append({"matcher": {"id": "byName", "options": col},
                          "properties": [{"id": "unit", "value": unit}]})
    d.add({
        "type": "table", "title": title, "description": desc,
        "targets": targets(items, instant=True, fmt="table"),
        "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}},
                                     "color": {"mode": "fixed", "fixedColor": BLUE}},
                        "overrides": overrides},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [{"displayName": sort_by, "desc": True}] if sort_by else []},
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": exclude, "renameByName": renames}},
        ],
    }, w, h)


def write(d, outdir):
    path = os.path.join(outdir, d.uid + ".json")
    with open(path, "w") as f:
        json.dump(d.json(), f, indent=2)
        f.write("\n")


# ---------------------------------------------------------------- overview
def overview():
    d = Dash("molly-overview", "Molly / Overview", "Today at a glance: activity, focus, output, and machine load.")
    d.row("Today")
    stat(d, "Active vs idle (today)", "avg(avg_over_time(molly_user_active" + sel() + "[$__range]))",
         unit="percentunit", w=4, h=5, time_from="now/d", spark=False, min_=0, max_=1, decimals=0,
         desc="Share of today the machine was awake, unlocked and not idle past the idle threshold.",
         instant=True)
    stat(d, "Focused app now", m("molly_focus_app"), w=4, h=5, text_mode="name", spark=False,
         legend="{{app}}", desc="The frontmost application.", instant=True)
    today_stat(d, "Active hours", "sum(increase(" + m("molly_active_seconds_total") + "[$__range])) / 3600",
               unit="h", decimals=1, h=5, desc="Hours of active use since local midnight.")
    today_stat(d, "Focus switches", "sum(increase(" + m("molly_focus_switches_total") + "[$__range]))", h=5)
    stat(d, "Commits", "sum(" + m("molly_git_commits_today") + ")", w=4, h=5, spark=False, decimals=0,
         desc="Commits today across tracked repos.", instant=True)
    today_stat(d, "Claude tokens", "sum(increase(" + m("molly_claude_tokens_total") + "[$__range]))",
               unit="short", h=5, desc="Input, output and cache tokens since midnight.")
    stat(d, "Anomalies firing", 'count(ALERTS{alertstate="firing", severity="info", alertname!="MollyDown"}) or vector(0)',
         w=4, h=5, spark=False, decimals=0, instant=True, th=[(None, GOOD), (1, WARN)],
         desc="Informational alerts currently firing (see Health > Alerts). Built-in series; not filtered by user/host.")
    d.row("Output today")
    stat(d, "Messages sent", "sum(" + m("molly_messages_today", 'direction="sent"') + ")", w=6, h=4, spark=False,
         decimals=0, instant=True)
    stat(d, "Browser visits", "sum(" + m("molly_browser_visits_today") + ")", w=6, h=4, spark=False,
         decimals=0, instant=True)
    today_stat(d, "Meeting minutes", "sum(increase(" + m("molly_meeting_seconds_total") + "[$__range])) / 60",
               unit="m", w=6, h=4, desc="Minutes with the microphone or camera in use.")
    today_stat(d, "Claude cost (est.)", "sum(increase(" + m("molly_claude_estimated_cost_usd_total") + "[$__range]))",
               unit="currencyUSD", w=6, h=4, decimals=2,
               desc="Estimated from token counts and the configured price table.")
    d.row("Focus and activity")
    state_timeline(d, "Focused app", [(m("molly_focus_app"), "{{app}}")], h=8,
                   desc="One row per app; a bar means it was frontmost.")
    state_timeline(d, "Active / idle", [(m("molly_user_active"), "active")], mappings=ACTIVE_MAP, h=3)
    d.row("Machine")
    timeseries(d, "CPU utilization", [(m("molly_cpu_utilization_ratio"), "{{host}}")], unit="percentunit",
               w=12, h=6, min_=0, max_=1)
    timeseries(d, "Memory in use", [(
        "sum by (host) (" + m("molly_memory_bytes", 'state=~"active|wired|compressed"') + ") / on (host) max by (host) (" + m("molly_memory_total_bytes") + ")",
        "{{host}}")], unit="percentunit", w=12, h=6, min_=0, max_=1,
        desc="Active + wired + compressed over total physical memory.")
    d.row("Insights")
    text_panel(d, "Latest insights",
               "Molly can write a daily narrative with recommendations from this data "
               "(`molly insights`, or enable the `insights` collector). "
               "Open the latest report: [127.0.0.1:9765/insights/latest](http://127.0.0.1:9765/insights/latest). "
               "Setup: `docs/INSIGHTS.md`.",
               h=3, desc="Reports are Markdown served by Molly; Grafana text panels cannot fetch them inline.")
    annotate_activity(d)
    return d


# ------------------------------------------------------------------ system
def system():
    d = Dash("molly-system", "Molly / System", "CPU, memory, disk, network, power, processes and containers.")
    d.row("CPU and load")
    timeseries(d, "CPU total", [(m("molly_cpu_utilization_ratio"), "{{host}}")], unit="percentunit",
               w=8, min_=0, max_=1)
    timeseries(d, "CPU per core", [(
        "1 - sum by (host, cpu) (rate(" + m("molly_cpu_seconds_total", 'cpu!="total",mode="idle"') + "[" + RI + "]))"
        " / sum by (host, cpu) (rate(" + m("molly_cpu_seconds_total", 'cpu!="total"') + "[" + RI + "]))",
        "{{host}} core {{cpu}}")], unit="percentunit", w=8, min_=0, max_=1, fill=0)
    timeseries(d, "Load average", [(m("molly_load_average"), "{{host}} {{period}}")], w=8, min_=0,
               desc="Compare with the core count; sustained load above it means queueing.")
    d.row("Memory")
    timeseries(d, "Memory by state", [(m("molly_memory_bytes"), "{{state}}"),
                                      (m("molly_memory_total_bytes"), "total")],
               unit="bytes", w=12, stack=False, fill=0, min_=0,
               desc="Per-state gauges plus the physical total.")
    state_timeline(d, "Memory pressure", [(m("molly_memory_pressure_level"), "{{host}}")], mappings=PRESSURE_MAP,
                   w=6, h=8)
    timeseries(d, "Swap", [(m("molly_swap_bytes"), "{{state}}")], unit="bytes", w=6, stack=True, min_=0)
    d.row("Disk")
    bargauge(d, "Disk space used per mount",
             [("1 - " + m("molly_disk_free_bytes") + " / " + m("molly_disk_total_bytes"), "{{host}} {{mount}}")],
             unit="percentunit", w=8, max_=1, th=[(None, BLUE), (0.8, WARN), (0.92, CRIT)])
    timeseries(d, "Disk read / write", [
        ("sum by (device) (rate(" + m("molly_disk_read_bytes_total") + "[" + RI + "]))", "{{device}} read"),
        ("sum by (device) (rate(" + m("molly_disk_write_bytes_total") + "[" + RI + "]))", "{{device}} write")],
        unit="Bps", w=8, min_=0)
    timeseries(d, "Disk operations", [
        ("sum by (device) (rate(" + m("molly_disk_read_ops_total") + "[" + RI + "]))", "{{device}} read"),
        ("sum by (device) (rate(" + m("molly_disk_write_ops_total") + "[" + RI + "]))", "{{device}} write")],
        unit="iops", w=8, min_=0)
    d.row("Network")
    state_timeline(d, "Connection", [(m("molly_network_primary_interface_info"), "{{interface}} ({{type}})")], w=12, h=5,
                   desc="Interface holding the default route and its type; none means offline.")
    state_timeline(d, "VPN state", [(m("molly_network_vpn_active"), "VPN")], mappings=YESNO("on"), w=6, h=5,
                   desc="On when a tunnel interface has a routable address or a network service routes through one.")
    timeseries(d, "Probe latency", [(m("molly_network_probe_latency_seconds"), "{{host}}")], unit="s", w=6, h=5, min_=0,
               desc="Needs collectors.network.probeURL.")
    timeseries(d, "Network receive", [
        ("sum by (interface) (rate(" + m("molly_network_receive_bytes_total") + "[" + RI + "]))", "{{interface}}")],
        unit="Bps", w=8, min_=0)
    timeseries(d, "Network transmit", [
        ("sum by (interface) (rate(" + m("molly_network_transmit_bytes_total") + "[" + RI + "]))", "{{interface}}")],
        unit="Bps", w=8, min_=0)
    timeseries(d, "Network errors", [
        ("sum by (interface) (rate(" + m("molly_network_receive_errors_total") + "[" + RI + "])) + sum by (interface) (rate(" + m("molly_network_transmit_errors_total") + "[" + RI + "]))", "{{interface}}")],
        unit="pps", w=8, min_=0)
    stat(d, "VPN", m("molly_network_vpn_active"), w=4, h=3, spark=False, mappings=mapping([(0, "off", GRAY), (1, "on", BLUE)]), instant=True)
    stat(d, "Wi-Fi connected", m("molly_network_wifi_connected"), w=4, h=3, spark=False, mappings=mapping([(0, "no", GRAY), (1, "yes", BLUE)]), instant=True)
    stat(d, "Displays", m("molly_displays"), w=4, h=3, spark=False, decimals=0, instant=True)
    stat(d, "Bluetooth devices", m("molly_bluetooth_devices_connected"), w=4, h=3, spark=False, decimals=0, instant=True)
    stat(d, "Uptime", m("molly_uptime_seconds"), unit="s", w=4, h=3, spark=False, instant=True)
    stat(d, "Processes", m("molly_processes_count"), w=4, h=3, decimals=0)
    d.row("Power and thermal")
    timeseries(d, "Battery", [(m("molly_battery_percent"), "{{host}} charge")], unit="percent", w=8, min_=0, max_=100,
               th=[(None, CRIT), (15, WARN), (30, GOOD)])
    state_timeline(d, "Power source", [(m("molly_battery_on_ac"), "AC power"), (m("molly_battery_charging"), "charging")],
                   mappings=YESNO("yes"), w=8, h=8)
    state_timeline(d, "Thermal state", [(m("molly_thermal_state"), "{{host}}")], mappings=THERMAL_MAP, w=8, h=8)
    stat(d, "Battery health", m("molly_battery_health_ratio"), unit="percentunit", w=6, h=3, spark=False, decimals=0, instant=True)
    stat(d, "Cycle count", m("molly_battery_cycle_count"), w=6, h=3, spark=False, decimals=0, instant=True)
    stat(d, "Time remaining", m("molly_battery_time_remaining_seconds"), unit="s", w=6, h=3, spark=False,
         mappings=[{"type": "range", "options": {"from": -1, "to": -1, "result": {"text": "unknown"}}}], instant=True)
    stat(d, "Output volume", m("molly_audio_output_volume_ratio"), unit="percentunit", w=6, h=3, spark=False, decimals=0, instant=True)
    d.row("Processes")
    bargauge(d, "Top processes by CPU", [("topk(10, " + m("molly_process_cpu_ratio") + ")", "{{name}}")],
             unit="percentunit", w=12, h=9, desc="Share of one core; may exceed 100% for multithreaded apps.")
    bargauge(d, "Top processes by memory", [("topk(10, " + m("molly_process_resident_memory_bytes", 'name!=""') + ")", "{{name}}")],
             unit="bytes", w=12, h=9)
    d.row("Docker")
    timeseries(d, "Containers by state", [(m("molly_docker_containers"), "{{state}}")], w=8, stack=True, min_=0, decimals=0)
    timeseries(d, "Container CPU", [(m("molly_docker_container_cpu_ratio"), "{{name}}")], unit="percentunit", w=8, min_=0,
               desc="Needs collectors.docker.stats = true.")
    timeseries(d, "Container memory", [(m("molly_docker_container_memory_bytes"), "{{name}}")], unit="bytes", w=8, min_=0,
               desc="Needs collectors.docker.stats = true.")
    table(d, "Containers", [m("molly_docker_container_info")], {"name": "Container", "image": "Image"}, h=7, exclude=["Value"])
    annotation(d, "VPN", m("molly_network_vpn_active") + " == 1", GOOD, "VPN", "tunnel active", region=True)
    return d


# ------------------------------------------------------------------- focus
def focus():
    d = Dash("molly-focus", "Molly / Focus", "Where your attention went: apps, switches, idle time, meetings.")
    d.row("Focus time")
    bargauge(d, "Focus time by app (selected range)",
             [("topk(15, sum by (app) (increase(" + m("molly_focus_seconds_total") + "[$__range])))", "{{app}}")],
             unit="s", w=12, h=10, desc="Frontmost time while active and unlocked.")
    bargauge(d, "App usage per knowledgeC (selected range)",
             [("topk(15, sum by (app) (increase(" + m("molly_knowledge_app_usage_seconds_total") + "[$__range])))", "{{app}}")],
             unit="s", w=12, h=10, color=fixed(ORANGE),
             desc="macOS's own usage log, keyed by bundle id. Counts time Molly was not running.")
    state_timeline(d, "Focused app", [(m("molly_focus_app"), "{{app}}")], h=9)
    timeseries(d, "Focus vs system usage log (hours per hour)", [
        ("sum(increase(" + m("molly_focus_seconds_total") + "[1h])) / 3600", "Molly focus"),
        ("sum(increase(" + m("molly_knowledge_app_usage_seconds_total") + "[1h])) / 3600", "knowledgeC usage")],
        unit="h", w=12, min_=0, fill=0, desc="Large gaps mean Molly was off or knowledgeC counts background apps.")
    timeseries(d, "Focus switches per hour", [("sum(increase(" + m("molly_focus_switches_total") + "[1h]))", "switches")],
               w=12, bars=True, min_=0, desc="Rolling 1h; a proxy for context switching.")
    d.row("Flow")
    state_timeline(d, "Flow state (5 minute buckets)", [(m("molly:flow_state:5m"), "{{host}}")], mappings=FLOW_MAP, h=4,
                   desc="flow: active 80%+ and at most 1.5 app switches/min; shallow: active 50%+; break: otherwise. Thresholds live in deploy/prometheus/rules/molly.yml.")
    today_stat(d, "Flow minutes today", "sum(" + m("molly:flow_minutes:increase1d") + ")", unit="m", w=6, h=6,
               desc="Minutes classified as flow since local midnight (5 minute resolution).")
    timeseries(d, "App switches per minute", [(m("molly:switch_rate:5m"), "{{host}}")], w=9, h=6, min_=0, fill=0,
               th=[(None, BLUE), (1.5, WARN)], desc="Rolling 5 minutes. Above 1.5 the bucket cannot be flow.")
    timeseries(d, "Interruptions per hour", [(m("molly:interruptions:increase1h"), "{{host}}")], w=9, h=6, bars=True, min_=0,
               decimals=0, desc="App switches per hour above a baseline of 10. An approximation of context-switch cost.")
    d.row("Presence")
    state_timeline(d, "Active / idle", [(m("molly_user_active"), "active")], mappings=ACTIVE_MAP, h=3)
    state_timeline(d, "Locked / asleep / screensaver", [
        (m("molly_screen_locked"), "screen locked"), (m("molly_system_asleep"), "asleep"),
        (m("molly_screensaver_active"), "screensaver")], mappings=YESNO("yes", SERIOUS), h=6)
    state_timeline(d, "Meeting (mic or camera in use)", [
        (m("molly_meeting_active"), "meeting"), (m("molly_microphone_in_use"), "microphone"),
        (m("molly_camera_in_use"), "camera")], mappings=YESNO("on"), h=6)
    d.row("Apps and windows")
    timeseries(d, "Running apps", [(m("molly_running_apps"), "{{host}}")], w=8, min_=0, decimals=0)
    timeseries(d, "Windows on screen", [(m("molly_windows_on_screen"), "{{host}}")], w=8, min_=0, decimals=0)
    timeseries(d, "Idle seconds", [(m("molly_idle_seconds"), "{{host}}")], unit="s", w=8, min_=0)
    bargauge(d, "App launches (selected range)",
             [("topk(10, sum by (app) (increase(" + m("molly_app_launches_total") + "[$__range])))", "{{app}}")],
             unit="short", w=24, decimals=0)
    d.row("Window titles (opt-in)")
    table(d, "Top windows by focus time (selected range)",
          ["topk(15, sum by (app, title) (increase(" + m("molly_focus_window_seconds_total") + "[$__range])))"],
          {"app": "App", "title": "Title", "Value": "Seconds"}, h=9, units={"Seconds": "s"}, sort_by="Seconds",
          desc="Needs the titles collector (Screen Recording). Titles are hashed unless titles.titles.hash is false.")
    state_timeline(d, "Now playing", [(m("molly_media_playing"), "{{app}}")], mappings=YESNO("playing"), h=3,
                   desc="Needs the media collector (Automation permission for Music/Spotify).")
    annotate_activity(d)
    return d


# --------------------------------------------------------------- developer
def developer():
    d = Dash("molly-developer", "Molly / Developer", "Git, AI agents, shell and project activity.")
    d.row("Git")
    timeseries(d, "Commits per repo (per hour)",
               [("sum by (repo) (increase(" + m("molly_git_commits_total", 'author="me"') + "[1h]))", "{{repo}}")],
               w=12, bars=True, stack=True, min_=0, decimals=0)
    stat(d, "Lines added today", "sum(" + m("molly_git_lines_added_today") + ")", w=3, h=4, spark=False, decimals=0, instant=True,
         color=fixed(BLUE))
    stat(d, "Lines removed today", "sum(" + m("molly_git_lines_removed_today") + ")", w=3, h=4, spark=False, decimals=0, instant=True,
         color=fixed(ORANGE))
    stat(d, "Commits today", "sum(" + m("molly_git_commits_today") + ")", w=3, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Active repos", m("molly_git_repos_active"), w=3, h=4, spark=False, decimals=0, instant=True)
    bargauge(d, "Lines changed today by repo", [
        ("topk(10, " + m("molly_git_lines_added_today") + " + " + m("molly_git_lines_removed_today") + ")", "{{repo}}")],
        w=12, h=4, decimals=0)
    table(d, "Repository state", [
        m("molly_git_dirty_files"), m("molly_git_untracked_files"), m("molly_git_ahead"), m("molly_git_behind"),
        m("molly_git_stashes"), m("molly_git_last_commit_timestamp_seconds")],
        {"repo": "Repo", "Value #A": "Dirty", "Value #B": "Untracked", "Value #C": "Ahead", "Value #D": "Behind",
         "Value #E": "Stashes", "Value #F": "Last commit"},
        units={"Last commit": "dateTimeFromNow"}, sort_by="Dirty",
        desc="Unpushed (ahead) and uncommitted work per active repo.")
    state_timeline(d, "Active projects", [(m("molly_project_active"), "{{project}}")], h=7,
                   desc="Projects with git, Claude or shell activity in the last 30 minutes.")
    d.row("Claude Code")
    stat(d, "Sessions active", "sum(" + m("molly_claude_sessions_active") + ")", w=4, h=4, decimals=0)
    stat(d, "Sessions today", "sum(" + m("molly_claude_sessions_today") + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    today_stat(d, "Cost today (est.)", "sum(increase(" + m("molly_claude_estimated_cost_usd_total") + "[$__range]))",
               unit="currencyUSD", w=4, decimals=2)
    today_stat(d, "Tokens today", "sum(increase(" + m("molly_claude_tokens_total") + "[$__range]))", w=4)
    stat(d, "Subagent messages / h", "sum(increase(" + m("molly_claude_subagent_messages_total") + "[1h]))", w=4, h=4, decimals=0)
    stat(d, "Prompts / h", "sum(increase(" + m("molly_claude_prompts_total") + "[1h]))", w=4, h=4, decimals=0)
    bargauge(d, "Tool calls by tool (selected range)",
             [("topk(15, sum by (tool) (increase(" + m("molly_claude_tool_calls_total") + "[$__range])))", "{{tool}}")],
             w=12, h=9, decimals=0)
    timeseries(d, "Tokens by kind (per hour)",
               [("sum by (kind) (increase(" + m("molly_claude_tokens_total") + "[1h]))", "{{kind}}")],
               w=12, h=9, stack=True, bars=True, min_=0, desc="Cache reads dominate; watch input and output for real work.")
    timeseries(d, "Tokens by model (per hour)",
               [("sum by (model) (increase(" + m("molly_claude_tokens_total") + "[1h]))", "{{model}}")],
               w=12, stack=True, bars=True, min_=0)
    timeseries(d, "Estimated cost (rolling 24h)",
               [("sum(increase(" + m("molly_claude_estimated_cost_usd_total") + "[1d]))", "cost")],
               unit="currencyUSD", w=12, min_=0, decimals=2, desc="Each point is the preceding 24 hours of spend.")
    timeseries(d, "Prompts per hour", [("sum(increase(" + m("molly_claude_prompts_total") + "[1h]))", "prompts")],
               w=12, bars=True, min_=0, decimals=0)
    timeseries(d, "Claude messages per hour", [
        ("sum by (role) (increase(" + m("molly_claude_messages_total") + "[1h]))", "{{role}}")],
        w=12, stack=True, bars=True, min_=0)
    d.row("Agent ROI")
    stat(d, "Cost per commit (24h)", "max(" + m("molly:claude_cost_per_commit:1d") + ")", unit="currencyUSD", w=6, h=5,
         decimals=2, desc="Estimated Claude spend over the last 24h divided by your commits in that window.")
    stat(d, "Tokens per commit (24h)", "max(" + m("molly:claude_tokens_per_commit:1d") + ")", w=6, h=5, decimals=0,
         desc="All token kinds, cache reads included.")
    timeseries(d, "Tool calls per hour", [(m("molly:claude_tool_calls:rate1h"), "{{host}}")], w=12, h=5, bars=True, min_=0,
               decimals=0)
    d.row("Other agents and tools")
    timeseries(d, "Cursor AI events (per hour)", [
        ("sum(increase(" + m("molly_cursor_ai_code_events_total") + "[1h]))", "AI code events"),
        ("sum(increase(" + m("molly_cursor_conversations_total") + "[1h]))", "conversations"),
        ("sum(increase(" + m("molly_cursor_scored_commits_total") + "[1h]))", "scored commits")],
        w=8, min_=0, fill=0)
    timeseries(d, "Codex tokens (per hour)", [
        ("sum by (kind) (increase(" + m("molly_codex_tokens_total") + "[1h]))", "{{kind}}")],
        w=8, stack=True, bars=True, min_=0, desc="Empty unless ~/.codex sessions exist.")
    timeseries(d, "Agent processes running", [(m("molly_agent_processes"), "{{agent}}")], w=8, min_=0, decimals=0)
    timeseries(d, "Shell commands per hour", [
        ("sum by (shell) (increase(" + m("molly_shell_commands_total") + "[1h]))", "{{shell}}")],
        w=12, bars=True, stack=True, min_=0, decimals=0)
    bargauge(d, "Command names (selected range)",
             [("topk(15, sum by (command) (increase(" + m("molly_shell_command_names_total") + "[$__range])))", "{{command}}")],
             w=12, decimals=0, desc="Only populated when collectors.shell.commands policy is enabled; arguments are never recorded.")
    return d


# ----------------------------------------------------------- communication
def communication():
    d = Dash("molly-communication", "Molly / Communication", "Messages, browsing, notifications, notes, calendar and mail.")
    d.row("Messages")
    stat(d, "Sent today", "sum(" + m("molly_messages_today", 'direction="sent"') + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Received today", "sum(" + m("molly_messages_today", 'direction="received"') + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Unread", "sum(" + m("molly_messages_unread") + ")", w=4, h=4, decimals=0,
         th=[(None, BLUE), (20, WARN), (100, SERIOUS)])
    stat(d, "Chats active today", "sum(" + m("molly_message_chats_active_today") + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    timeseries(d, "Messages per hour", [
        ("sum by (service, direction) (increase(" + m("molly_messages_total") + "[1h]))", "{{service}} {{direction}}")],
        w=24, h=8, bars=True, stack=True, min_=0, decimals=0)
    d.row("Browser")
    timeseries(d, "Visits per hour by browser", [
        ("sum by (browser) (increase(" + m("molly_browser_visits_total") + "[1h]))", "{{browser}}")],
        w=12, bars=True, stack=True, min_=0, decimals=0)
    stat(d, "Distinct domains today", m("molly_browser_distinct_domains_today"), w=6, h=8, spark=False, decimals=0,
         legend="{{browser}}", instant=True)
    stat(d, "Visits today", m("molly_browser_visits_today"), w=6, h=8, spark=False, decimals=0, legend="{{browser}}", instant=True)
    table(d, "Domain visits today", [
        "topk(25, sum by (domain) (" + m("molly_browser_domain_visits_today") + "))"],
        {"domain": "Domain", "Value": "Visits"}, h=9, sort_by="Visits",
        desc="Only populated when collectors.browser.domains policy is enabled (default off).")
    d.row("Notifications and notes")
    stat(d, "Notifications today", "sum(" + m("molly_knowledge_notifications_today") + ")", w=4, h=8, spark=False, decimals=0, instant=True)
    timeseries(d, "Notifications per hour", [
        ("sum(increase(" + m("molly_knowledge_notifications_total") + "[1h]))", "all apps")],
        w=8, bars=True, min_=0, decimals=0)
    stat(d, "Notes created today", "sum(" + m("molly_notes_created_today") + ")", w=3, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Notes modified today", "sum(" + m("molly_notes_modified_today") + ")", w=3, h=4, spark=False, decimals=0, instant=True)
    timeseries(d, "Notes created / modified (per hour)", [
        ("sum(increase(" + m("molly_notes_created_total") + "[1h]))", "created"),
        ("sum(increase(" + m("molly_notes_modified_total") + "[1h]))", "modified")],
        w=6, h=8, bars=True, min_=0, decimals=0)
    d.row("Calendar")
    stat(d, "Events today", "sum(" + m("molly_calendar_events_today") + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    stat(d, "In an event", "max(" + m("molly_calendar_in_event") + ")", w=4, h=4, spark=False,
         mappings=mapping([(0, "free", GRAY), (1, "in event", BLUE)]), instant=True)
    stat(d, "Next event in", "max(" + m("molly_calendar_next_event_start_seconds") + ")", unit="s", w=4, h=4, spark=False,
         mappings=[{"type": "range", "options": {"from": -1, "to": -1, "result": {"text": "none"}}}], instant=True)
    stat(d, "Event time today", "max(" + m("molly_calendar_event_seconds_today") + ")", unit="s", w=4, h=4, spark=False, instant=True)
    stat(d, "Event time remaining", "max(" + m("molly_calendar_event_seconds_remaining_today") + ")", unit="s", w=4, h=4, spark=False, instant=True)
    state_timeline(d, "In an event", [(m("molly_calendar_in_event"), "in event")], mappings=YESNO("in event"), w=4, h=4)
    d.row("Reminders")
    stat(d, "Open reminders", "sum(" + m("molly_reminders_open") + ")", w=4, h=4, decimals=0)
    stat(d, "Due today", "sum(" + m("molly_reminders_due_today") + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Overdue", "sum(" + m("molly_reminders_overdue") + ")", w=4, h=4, spark=False, decimals=0, instant=True,
         th=[(None, BLUE), (1, WARN), (10, SERIOUS)])
    stat(d, "Completed today", "sum(" + m("molly_reminders_completed_today") + ")", w=4, h=4, spark=False, decimals=0, instant=True)
    timeseries(d, "Reminders completed (per hour)", [
        ("sum(increase(" + m("molly_reminders_completed_total") + "[1h]))", "completed")],
        w=8, h=4, bars=True, min_=0, decimals=0)
    d.row("Mail (when enabled)")
    stat(d, "Unread mail", "sum(" + m("molly_mail_unread") + ")", w=6, h=4, decimals=0)
    stat(d, "Mail sent today", "sum(" + m("molly_mail_messages_today", 'direction="sent"') + ")", w=6, h=4, spark=False, decimals=0, instant=True)
    stat(d, "Mail received today", "sum(" + m("molly_mail_messages_today", 'direction="received"') + ")", w=6, h=4, spark=False, decimals=0, instant=True)
    timeseries(d, "Mail per hour", [
        ("sum by (direction) (increase(" + m("molly_mail_messages_total") + "[1h]))", "{{direction}}")],
        w=6, h=4, bars=True, stack=True, min_=0, decimals=0)
    return d


# ------------------------------------------------------------------ health
def health():
    d = Dash("molly-health", "Molly / Health", "Is Molly running, being scraped, and are its collectors healthy.")
    d.row("Exporter")
    stat(d, "Molly up", m("molly_up"), w=4, h=4, spark=False, mappings=mapping([(0, "down", CRIT), (1, "up", GOOD)]),
         th=[(None, CRIT), (1, GOOD)], instant=True)
    stat(d, "Prometheus target", 'up{job="molly"}', w=4, h=4, spark=False, mappings=mapping([(0, "down", CRIT), (1, "up", GOOD)]),
         th=[(None, CRIT), (1, GOOD)], desc="Built-in series; carries no user/host labels.", instant=True)
    stat(d, "Paused", m("molly_paused"), w=4, h=4, spark=False, mappings=mapping([(0, "running", GOOD), (1, "paused", WARN)]),
         th=[(None, GOOD), (1, WARN)], instant=True)
    stat(d, "Version", m("molly_build_info"), w=4, h=4, spark=False, text_mode="name", legend="{{version}}", instant=True)
    stat(d, "Uptime", "time() - " + m("molly_start_time_seconds"), unit="s", w=4, h=4, spark=False, instant=True)
    stat(d, "Threads", m("molly_self_threads"), w=4, h=4, decimals=0)
    timeseries(d, "Scrape duration", [('scrape_duration_seconds{job="molly"}', "scrape")], unit="s", w=8, min_=0,
               desc="Built-in series from Prometheus; how long /metrics takes to render.")
    timeseries(d, "Molly process memory", [(m("molly_self_resident_memory_bytes"), "{{host}} RSS")],
               unit="bytes", w=8, min_=0)
    timeseries(d, "Molly process CPU", [("rate(" + m("molly_self_cpu_seconds_total") + "[" + RI + "])", "{{host}}")],
               unit="percentunit", w=8, min_=0)
    state_timeline(d, "Molly up (history)", [(m("molly_up"), "molly")], mappings=mapping([(0, "down", CRIT), (1, "up", GOOD)]), h=3)
    d.row("Registry size")
    stat(d, "Series", m("molly_self_series_total"), w=4, h=6, decimals=0,
         th=[(None, GOOD), (3000, WARN), (5000, CRIT)],
         desc="Series across all metric families. `molly tune` warns above 5000.")
    stat(d, "Metric families", m("molly_self_metric_families"), w=4, h=6, decimals=0)
    bargauge(d, "Largest families", [("topk(10, " + m("molly_self_series") + ")", "{{family}}")],
             w=16, h=6, decimals=0,
             desc="Series per family for the 20 largest; a family that keeps growing usually has a label policy that needs maxCardinality or a denylist.")
    d.row("Collectors")
    timeseries(d, "Collector runs per minute", [
        ("sum by (collector) (rate(" + m("molly_collector_runs_total") + "[" + RI + "])) * 60", "{{collector}}")],
        w=8, min_=0, fill=0)
    timeseries(d, "Collector errors (per hour)", [
        ("sum by (collector) (increase(" + m("molly_collector_errors_total") + "[1h]))", "{{collector}}")],
        w=8, bars=True, stack=True, min_=0, decimals=0)
    timeseries(d, "Collector run duration", [(m("molly_collector_duration_seconds"), "{{collector}}")],
               unit="s", w=8, min_=0, fill=0)
    table(d, "Collector status", [
        m("molly_collector_enabled"),
        "time() - " + m("molly_collector_last_success_timestamp_seconds"),
        "sum by (collector) (" + m("molly_collector_runs_total") + ")",
        "sum by (collector) (" + m("molly_collector_errors_total") + ")",
        m("molly_collector_duration_seconds")],
        {"collector": "Collector", "Value #A": "Enabled", "Value #B": "Last success age",
         "Value #C": "Runs", "Value #D": "Errors", "Value #E": "Last duration"},
        units={"Last success age": "s", "Last duration": "s"}, h=12, sort_by="Last success age",
        desc="Last success age well above the collector interval means it is failing or unavailable.")
    d.row("Alerts")
    table(d, "Firing alerts", [
        # Seconds since the alert became active where Prometheus tracks it (alerts with a `for`),
        # 0 for alerts that fire immediately.
        '(ALERTS{alertstate="firing"} * on (alertname, user, host) group_left () (time() - ALERTS_FOR_STATE)) '
        'or (ALERTS{alertstate="firing"} * 0)'],
        {"alertname": "Alert", "severity": "Severity", "collector": "Collector", "Value": "Active for"},
        units={"Active for": "s"}, exclude=["alertstate"], h=8, sort_by="Active for",
        desc="Every alert currently firing, from deploy/prometheus/rules/molly.yml. All are informational.")
    state_timeline(d, "Alert history", [('ALERTS{alertstate="firing"}', "{{alertname}}")],
                   mappings=mapping([(1, "firing", WARN)]), h=7,
                   desc="When each alert was firing over the selected range. Built-in series; not filtered by user/host.")
    return d


# -------------------------------------------------------------------- week
def wow_stat(d, title, expr, unit="short", w=4, h=5, decimals=0, desc=""):
    """This 7 days vs the previous 7 days. Tiles show the current value; the sparkline is the daily shape."""
    stat(d, title, expr, unit=unit, w=w, h=h, decimals=decimals, spark=False, instant=True, time_from="now-7d",
         desc=(desc + " " if desc else "") + "Last 7 days.")
    previous = expr.replace("[$__range]", "[$__range] offset 7d").replace("[$__range:5m]", "[$__range:5m] offset 7d")
    stat(d, title + " (previous 7d)", previous, unit=unit, w=w, h=h,
         decimals=decimals, spark=False, instant=True, time_from="now-7d", color=fixed(GRAY),
         desc="The 7 days before that, for comparison.")


def week():
    d = Dash("molly-week", "Molly / Week", "Seven-day review: daily shape, week-over-week change, top apps and repos.",
             time_from="now-7d")
    d.row("Week over week")
    wow_stat(d, "Active hours", "sum(increase(" + m("molly_active_seconds_total") + "[$__range])) / 3600", unit="h", decimals=1)
    wow_stat(d, "Flow hours", "sum(sum_over_time((" + m("molly:flow_state:5m") + " == bool 2)[$__range:5m])) * 5 / 60",
             unit="h", decimals=1, desc="Minutes classified as flow, in hours.")
    wow_stat(d, "Commits", "sum(increase(" + m("molly_git_commits_total", 'author="me"') + "[$__range]))")
    wow_stat(d, "Claude cost (est.)", "sum(increase(" + m("molly_claude_estimated_cost_usd_total") + "[$__range]))",
             unit="currencyUSD", decimals=2)
    wow_stat(d, "Messages sent", "sum(increase(" + m("molly_messages_total", 'direction="sent"') + "[$__range]))")
    wow_stat(d, "Meeting hours", "sum(increase(" + m("molly_meeting_seconds_total") + "[$__range])) / 3600", unit="h", decimals=1)
    d.row("Day by day")
    daily = dict(w=12, h=7, bars=True, min_=0)
    timeseries(d, "Active hours per day", [(m("molly:active_hours:1d"), "{{host}}")], unit="h", decimals=1,
               desc="Each bar is the preceding 24 hours; read the value at each midnight for the calendar day.", **daily)
    timeseries(d, "Flow minutes per day", [(m("molly:flow_minutes:increase1d"), "{{host}}")], unit="m", decimals=0,
               color=fixed(GOOD), **daily)
    timeseries(d, "Commits per day", [(m("molly:commits:increase1d"), "{{host}}")], decimals=0, **daily)
    timeseries(d, "Claude cost per day (est.)", [(m("molly:claude_cost_usd:increase1d"), "{{host}}")], unit="currencyUSD",
               decimals=2, color=fixed(ORANGE), **daily)
    timeseries(d, "Messages sent per day", [("sum by (host) (increase(" + m("molly_messages_total", 'direction="sent"') + "[1d]))", "{{host}}")],
               decimals=0, **daily)
    timeseries(d, "Meeting hours per day", [(m("molly:meeting_hours:1d"), "{{host}}")], unit="h", decimals=1, **daily)
    d.row("Where the week went")
    bargauge(d, "Top apps this week", [("topk(10, sum by (app) (increase(" + m("molly_focus_seconds_total") + "[$__range])))", "{{app}}")],
             unit="s", w=12, h=9, desc="Frontmost time while active and unlocked.")
    bargauge(d, "Top repos this week", [("topk(10, sum by (repo) (increase(" + m("molly_git_commits_total", 'author="me"') + "[$__range])))", "{{repo}}")],
             w=12, h=9, decimals=0, desc="Your commits per repo.")
    state_timeline(d, "Flow state", [(m("molly:flow_state:5m"), "{{host}}")], mappings=FLOW_MAP, h=4)
    annotate_activity(d)
    return d


# ------------------------------------------------------------------- fleet
def fleet():
    """Several machines reporting to one Prometheus: one row per host."""
    d = Dash("molly-fleet", "Molly / Fleet", "Every machine running Molly, side by side: liveness, activity, cost, scrape health.")
    d.row("Hosts")
    table(d, "Hosts", [
        m("molly_up"),
        m("molly_build_info"),
        m("molly_user_active"),
        "label_replace(" + m("molly_focus_app") + ', "focused", "$1", "app", "(.*)")',
        m("molly_battery_percent"),
        m("molly_cpu_utilization_ratio"),
        m("molly_memory_pressure_level"),
        "count by (user, host) (" + m("molly_collector_enabled") + " == 1 and (time() - "
        + m("molly_collector_last_success_timestamp_seconds") + ") > 600)",
        "time() - " + m("molly_start_time_seconds")],
        {"host": "Host", "user": "User", "version": "Version", "Value #A": "Molly up",
         "Value #C": "Active now", "focused": "Focused app", "Value #E": "Battery",
         "Value #F": "CPU", "Value #G": "Mem pressure", "Value #H": "Collectors failing",
         "Value #I": "Uptime"},
        units={"Battery": "percent", "CPU": "percentunit", "Uptime": "s"},
        exclude=["Value #B", "Value #D", "app", "bundle_id"], h=9, sort_by="Host",
        desc="One row per user/host. Collectors failing = enabled collectors with no success in 10 minutes. "
             "Host and user are const labels on every Molly series, so each machine stays distinct.")
    d.row("Today, per host")
    per_host = dict(w=12, h=7, bars=True, min_=0)
    timeseries(d, "Active hours today", [("sum by (host) (increase(" + m("molly_active_seconds_total") + "[1d])) / 3600", "{{host}}")],
               unit="h", decimals=1, desc="Trailing 24 hours per host.", **per_host)
    timeseries(d, "Commits today", [("sum by (host) (increase(" + m("molly_git_commits_total", 'author="me"') + "[1d]))", "{{host}}")],
               decimals=0, desc="Your commits in the trailing 24 hours per host.", **per_host)
    timeseries(d, "Claude cost today (est.)", [("sum by (host) (increase(" + m("molly_claude_estimated_cost_usd_total") + "[1d]))", "{{host}}")],
               unit="currencyUSD", decimals=2, color=fixed(ORANGE), **per_host)
    timeseries(d, "Scrape duration", [('scrape_duration_seconds{job="molly"}', "{{instance}}")], unit="s", w=12, min_=0,
               desc="Built-in series per scrape target; one target per machine in prometheus.yml.")
    d.row("Liveness")
    state_timeline(d, "Molly up per host", [(m("molly_up"), "{{host}}")],
                   mappings=mapping([(0, "down", CRIT), (1, "up", GOOD)]), h=5)
    state_timeline(d, "User active per host", [(m("molly_user_active"), "{{host}}")],
                   mappings=mapping([(0, "idle", GRAY), (1, "active", GOOD)]), h=5)
    return d


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for build in (overview, system, focus, developer, communication, health, week, fleet):
        write(build(), out)
