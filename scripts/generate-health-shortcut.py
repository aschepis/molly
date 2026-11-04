#!/usr/bin/env python3
"""Builds and signs the "Molly Health" iPhone Shortcut.

usage: scripts/generate-health-shortcut.py <host> [output.shortcut] [--skip a,b] [--only a,b] [--no-watch]

Find Health Samples halts the whole shortcut with "No Samples Found" when a
type has never been recorded, so leave out types your devices do not produce:
--no-watch drops everything that needs an Apple Watch; --skip/--only take
molly type names from docs/HEALTH.md.

<host> is how the phone reaches the Mac, for example
adams-macbook-pro.tail853834.ts.net. The token and port come from Molly's
config. The output contains the token, so keep it out of git and share it
by AirDrop or by importing it on the Mac (iCloud syncs it to the phone).

The plist shapes come from shortcuts exported from iOS 26; Apple does not
document them. Rows marked "verify" use a Health type label that was not
seen in a real export, so check them once in the Shortcuts editor.
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid

CONFIG = os.environ.get("MOLLY_CONFIG") or os.path.expanduser(
    "~/Library/Application Support/Molly/config.json")

# (molly type, Find Health Samples type label, how the day's value is derived)
# "sum" / "average" / "maximum" feed Calculate Statistics over Value.
SUM, AVG, MAX = "Sum", "Average", "Maximum"
QUANTITIES = [
    ("steps", "Steps", SUM),
    ("active_energy_kcal", "Active Calories", SUM),
    ("exercise_minutes", "Exercise Minutes", SUM),
    ("walking_distance_m", "Walking + Running Distance", SUM),
    ("flights_climbed", "Flights Climbed", SUM),
    ("resting_heart_rate_bpm", "Resting Heart Rate", AVG),
    ("heart_rate_bpm", "Heart Rate", AVG),
    ("hrv_ms", "Heart Rate Variability", AVG),
    ("daylight_minutes", "Time in Daylight", SUM),
    ("headphone_audio_db", "Headphone Audio Levels", MAX),
    ("vo2max", "Cardio Fitness", AVG),
    ("body_mass_kg", "Weight", AVG),
    ("respiratory_rate", "Respiratory Rate", AVG),
    ("blood_oxygen_ratio", "Blood Oxygen", AVG),
    ("wrist_temperature_delta_c", "Wrist Temperature", AVG),
    ("mindful_minutes", "Mindful Minutes", SUM),
]
WATCH_ONLY = {"exercise_minutes", "stand_hours", "resting_heart_rate_bpm", "heart_rate_bpm", "hrv_ms",
              "vo2max", "blood_oxygen_ratio", "wrist_temperature_delta_c", "respiratory_rate",
              "sleep_minutes", "sleep_in_bed_minutes", "bedtime", "wake_time"}
VERIFIED_LABELS = {"Steps", "Active Calories", "Exercise Minutes",
                   "Walking + Running Distance", "Flights Climbed", "Sleep"}

IS, IS_NOT, IS_TODAY = 4, 5, 1002


def uid():
    return str(uuid.uuid4()).upper()


def ref(output_uuid, output_name):
    """A bare reference to another action's output."""
    return {"Value": {"OutputUUID": output_uuid, "Type": "ActionOutput", "OutputName": output_name},
            "WFSerializationType": "WFTextTokenAttachment"}


def text(value):
    """A literal string parameter."""
    return {"Value": {"string": value, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}


def text_ref(output_uuid, output_name):
    """A string parameter that is entirely one action's output."""
    return {"Value": {"string": "￼", "attachmentsByRange": {
        "{0, 1}": {"OutputUUID": output_uuid, "Type": "ActionOutput", "OutputName": output_name}}},
        "WFSerializationType": "WFTextTokenString"}


def action(identifier, **params):
    params.setdefault("UUID", uid())
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": params}


def enum_row(prop, operator, value, removable=False):
    return {"Bounded": True, "Operator": operator, "Property": prop, "Removable": removable,
            "Values": {"Enumeration": {"Value": value, "WFSerializationType": "WFStringSubstitutableState"}}}


def today_row(prop):
    # Real iOS exports carry Number/Unit on the "is today" row; keep them.
    return {"Bounded": True, "Operator": IS_TODAY, "Property": prop, "Removable": False,
            "Values": {"Number": "7", "Unit": 16}}


def find_samples(type_label, date_prop="Start Date", extra_rows=(), sort=None, limit=None):
    rows = [enum_row("Type", IS, type_label), today_row(date_prop), *extra_rows]
    params = {"WFContentItemFilter": {
        "Value": {"WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
                  "WFActionParameterFilterTemplates": rows},
        "WFSerializationType": "WFContentPredicateTableTemplate"}}
    if sort:
        params["WFContentItemSortProperty"], params["WFContentItemSortOrder"] = sort
    if limit:
        params["WFContentItemLimitEnabled"] = True
        params["WFContentItemLimitNumber"] = limit
    return action("is.workflow.actions.filter.health.quantity", **params)


def statistics(source, operation):
    return action("is.workflow.actions.statistics", Input=ref(source["WFWorkflowActionParameters"]["UUID"], "Health Samples"),
                  WFStatisticsOperation=operation)


def detail(source, name):
    return action("is.workflow.actions.properties.health.quantity",
                  WFInput=ref(source["WFWorkflowActionParameters"]["UUID"], "Health Samples"),
                  WFContentItemPropertyName=name)


def output_of(act, name):
    return act["WFWorkflowActionParameters"]["UUID"], name


HAS_ANY_VALUE = 100


def guarded(source, inner):
    """Wrap `inner` in "If <source> has any value"; Statistics and Math fail on empty input."""
    group = uid()
    variable = {"Type": "Variable", "Variable": ref(*output_of(source, "Health Samples"))}
    begin = action("is.workflow.actions.conditional", WFInput=variable, WFCondition=HAS_ANY_VALUE,
                   WFControlFlowMode=0, GroupingIdentifier=group)
    end = action("is.workflow.actions.conditional", WFControlFlowMode=2, GroupingIdentifier=group)
    return [begin, *inner, end]


def dict_item(key, value_ref):
    return {"WFItemType": 0, "WFKey": text(key), "WFValue": text_ref(*value_ref)}


def build(host, port, token, wanted):
    actions = []
    totals = []  # (molly type, (uuid, output name))

    def append(molly_type, acts, output):
        if molly_type in wanted:
            actions.extend(acts)
            totals.append((molly_type, output))

    date = action("is.workflow.actions.date")
    day = action("is.workflow.actions.format.date", WFDate=text_ref(*output_of(date, "Date")),
                 WFDateFormatStyle="Custom", WFDateFormat="Custom", WFDateFormatString="yyyy-MM-dd")
    actions += [date, day]

    for molly_type, label, operation in QUANTITIES:
        found = find_samples(label)
        stat = statistics(found, operation)
        append(molly_type, [found, *guarded(found, [stat])], output_of(stat, "Statistics Result"))

    # Stand hours are category samples: one per hour, "Stood" or "Idle".
    stood = find_samples("Stand Hours", extra_rows=[enum_row("Value", IS, "Stood")])
    count = action("is.workflow.actions.count", WFCountType="Items",
                   WFInput=ref(*output_of(stood, "Health Samples")), Input=ref(*output_of(stood, "Health Samples")))
    append("stand_hours", [stood, count], output_of(count, "Count"))

    # Sleep ends this morning, so filter on End Date. Durations sum to seconds.
    asleep_rows = [enum_row("Value", IS_NOT, "In Bed"), enum_row("Value", IS_NOT, "Awake")]
    for molly_type, rows in (("sleep_minutes", asleep_rows), ("sleep_in_bed_minutes", [enum_row("Value", IS, "In Bed")])):
        found = find_samples("Sleep", date_prop="End Date", extra_rows=rows)
        durations = detail(found, "Duration")
        seconds = action("is.workflow.actions.statistics", Input=ref(*output_of(durations, "Duration")), WFStatisticsOperation=SUM)
        minutes = action("is.workflow.actions.math", WFInput=ref(*output_of(seconds, "Statistics Result")),
                         WFMathOperation="÷", WFMathOperand="60")
        append(molly_type, [found, *guarded(found, [durations, seconds, minutes])], output_of(minutes, "Calculation Result"))

    for molly_type, sort, prop in (("bedtime", ("Start Date", "Oldest First"), "Start Date"),
                                   ("wake_time", ("End Date", "Latest First"), "End Date")):
        found = find_samples("Sleep", date_prop="End Date", extra_rows=asleep_rows, sort=sort, limit=1)
        when = detail(found, prop)
        iso = action("is.workflow.actions.format.date", WFDate=text_ref(*output_of(when, prop)),
                     WFDateFormatStyle="ISO 8601", WFISO8601IncludeTime=True)
        append(molly_type, [found, *guarded(found, [when, iso])], output_of(iso, "Formatted Date"))

    totals_dict = {"WFItemType": 1, "WFKey": text("totals"), "WFValue": {
        "Value": {"Value": {"WFDictionaryFieldValueItems": [dict_item(t, r) for t, r in totals]},
                  "WFSerializationType": "WFDictionaryFieldValue"},
        "WFSerializationType": "WFDictionaryFieldValue"}}
    body = {"Value": {"WFDictionaryFieldValueItems": [
        {"WFItemType": 0, "WFKey": text("device"), "WFValue": text("iphone")},
        dict_item("date", output_of(day, "Formatted Date")),
        totals_dict]}, "WFSerializationType": "WFDictionaryFieldValue"}
    headers = {"Value": {"WFDictionaryFieldValueItems": [
        {"WFItemType": 0, "WFKey": text("Authorization"), "WFValue": text("Bearer " + token)},
        {"WFItemType": 0, "WFKey": text("Content-Type"), "WFValue": text("application/json")}]},
        "WFSerializationType": "WFDictionaryFieldValue"}
    post = action("is.workflow.actions.downloadurl", WFURL=f"http://{host}:{port}/health",
                  WFHTTPMethod="POST", WFHTTPBodyType="JSON", WFJSONValues=body, WFHTTPHeaders=headers,
                  Advanced=True, ShowHeaders=True)
    note = action("is.workflow.actions.notification", WFInput=ref(*output_of(post, "Contents of URL")),
                  WFNotificationActionTitle="Molly Health", WFNotificationActionBody=text_ref(*output_of(post, "Contents of URL")),
                  WFNotificationActionSound=False)
    actions += [post, note]

    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2700.0.4",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59511, "WFWorkflowIconStartColor": 4282601983},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowName": "Molly Health",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
    }


ALL_TYPES = [t for t, _, _ in QUANTITIES] + ["stand_hours", "sleep_minutes", "sleep_in_bed_minutes", "bedtime", "wake_time"]


def parse_args(argv):
    positional, skip, only, no_watch = [], set(), None, False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--no-watch":
            no_watch = True
        elif arg in ("--skip", "--only"):
            i += 1
            names = set(argv[i].split(","))
            unknown = names - set(ALL_TYPES)
            if unknown:
                sys.exit("unknown type(s): " + ", ".join(sorted(unknown)) + "\nknown: " + ", ".join(ALL_TYPES))
            if arg == "--skip":
                skip |= names
            else:
                only = names
        else:
            positional.append(arg)
        i += 1
    wanted = set(ALL_TYPES) if only is None else only
    if no_watch:
        wanted -= WATCH_ONLY
    wanted -= skip
    if not positional or not wanted:
        sys.exit(__doc__)
    return positional, wanted


def main():
    positional, wanted = parse_args(sys.argv[1:])
    host = positional[0]
    output = positional[1] if len(positional) > 1 else os.path.expanduser("~/Desktop/Molly Health.shortcut")
    with open(CONFIG, encoding="utf-8") as f:
        config = json.load(f)
    token = config.get("collectors", {}).get("health", {}).get("token", "")
    port = config.get("server", {}).get("port", 9765)
    if not token:
        sys.exit("collectors.health.token is not set in " + CONFIG)

    workflow = build(host, port, token, wanted)
    with tempfile.TemporaryDirectory() as tmp:
        unsigned = os.path.join(tmp, "Molly Health.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
        subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", output], check=True)

    unverified = sorted({label for t, label, _ in QUANTITIES if t in wanted and label not in VERIFIED_LABELS}
                        | ({"Stand Hours"} if "stand_hours" in wanted else set()))
    print(f"wrote {output} ({len(workflow['WFWorkflowActions'])} actions, {len(wanted)} types)")
    print("types: " + ", ".join(t for t in ALL_TYPES if t in wanted))
    print("type labels to check once in the editor: " + ", ".join(unverified))


if __name__ == "__main__":
    main()
