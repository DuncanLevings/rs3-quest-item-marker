"""Reads the quest-item-marker-probe console log into the build's client inputs.

What this file does: the probe (dev_plugins/quest-item-marker-probe, ribbon section
"D. Quests") prints lines that only the game client can answer. Copy the console output to a
text file and run this on it. It owns nothing but the three tools/data files it rewrites:

  "Dump quest states"            QUEST <id> | <CONFIG> | <name> | <type> | <deprecated> | ...
      -> tools/data/client_quests.json (adds each quest's type: 0 quest, 1 holiday, 2 tutorial)
  "M1: dump QOBJ + NOTED ..."    QOBJS <quest name> | id,id,...
      -> tools/data/client_quest_objects.json (for the "given by the quest" cross-check)
                                 NOTEDS id,id,...   (each id's noted form is id + 1)
      -> tools/data/noted_ids.json (the only accepted source of noted ids)
                                 M1 SUMMARY quests N | QOBJ links N | NOTED pairs N | ...
      -> checked against the lines found; a log that lost lines is refused

The older one-per-line QOBJ / NOTED lines are still read. A section that isn't in the log
leaves its file untouched.

Usage: py -3 -I tools/import_probe_log.py <log file> --client "951-1"
"""
import argparse
import datetime
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ROOT / "tools" / "data"

QUEST = re.compile(r"\[qim-probe\] QUEST (\d+) \| ([A-Z0-9_]*) \| (.*?) \| (.*?) \| (true|false) \|")
QOBJ = re.compile(r"\[qim-probe\] QOBJ (\d+) \| (.+?)\s*$")
NOTED = re.compile(r"\[qim-probe\] NOTED (\d+) \| (\d+)\s*$")
QOBJS = re.compile(r"\[qim-probe\] QOBJS (.+?) \| ([\d,]+)\s*$")
NOTEDS = re.compile(r"\[qim-probe\] NOTEDS ([\d,]+)\s*$")
SUMMARY = re.compile(r"\[qim-probe\] M1 SUMMARY quests (\d+) \| QOBJ links (\d+) \| NOTED pairs (\d+)")


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", type=Path)
    parser.add_argument("--client", required=True, help="client build the log came from, eg 951-1")
    args = parser.parse_args(argv)

    text = args.log.read_text(encoding="utf-8", errors="replace")
    stamp = f"quest-item-marker-probe on client {args.client}, imported {datetime.date.today()}"

    # Quest types. The type prints as a number or an enum name; keep the number.
    types = {}

    for match in QUEST.finditer(text):
        raw = match.group(4)
        number = re.search(r"\d+", raw)
        names = {"NORMAL": 0, "SEASONAL": 1, "TUTORIAL": 2}
        types[int(match.group(1))] = int(number.group()) if number else names.get(raw.upper())

    if types:
        client = json.loads((INPUTS / "client_quests.json").read_text(encoding="utf-8"))

        for quest in client["quests"]:
            if quest["id"] in types:
                quest["type"] = types[quest["id"]]

        client["source"] += f" type added from {stamp}."
        write(INPUTS / "client_quests.json", client)
        print(f"client_quests.json: type for {len(types)} quests")

    # Items the client ties to each quest.
    objects = defaultdict(set)

    for line in text.splitlines():
        match = QOBJ.search(line)

        if match and match.group(2) not in ("", "nil"):
            objects[match.group(2)].add(int(match.group(1)))

        match = QOBJS.search(line)

        if match:
            objects[match.group(1)].update(int(number) for number in match.group(2).split(","))

    # Noted pairs.
    noted = {}

    for line in text.splitlines():
        match = NOTED.search(line)

        if match:
            noted[match.group(1)] = int(match.group(2))

        match = NOTEDS.search(line)

        if match:
            for number in match.group(1).split(","):
                noted[number] = int(number) + 1

    # The console keeps only its newest lines. The packed dump ends with its totals, so a
    # log that lost lines is caught here instead of shipping half the noted ids.
    summary = SUMMARY.search(text)

    if summary:
        expected = tuple(int(group) for group in summary.groups())
        found = (len(objects), sum(map(len, objects.values())), len(noted))

        if found != expected:
            print(f"the log is incomplete: M1 SUMMARY says quests/links/noted = {expected}, "
                  f"the log has {found}. Copy the console again right after the scan ends; "
                  "nothing was written.", file=sys.stderr)
            return 1
    elif objects or noted:
        print("no M1 SUMMARY line, so the log can't be checked for lost lines; nothing was "
              "written. Run the probe's M1 button again and copy everything up to its summary.",
              file=sys.stderr)
        return 1

    if objects:
        write(INPUTS / "client_quest_objects.json", {
            "source": "ObjType.quests for every object id, " + stamp,
            "quests": {name: sorted(ids) for name, ids in sorted(objects.items())},
        })
        print(f"client_quest_objects.json: {sum(map(len, objects.values()))} links, {len(objects)} quests")

    if noted:
        write(INPUTS / "noted_ids.json", {
            "about": "Unnoted item id -> noted item id, confirmed in the client: the next id has the "
                     "same name and always stacks while the item itself doesn't.",
            "source": stamp,
            "noted": dict(sorted(noted.items(), key=lambda pair: int(pair[0]))),
        })
        print(f"noted_ids.json: {len(noted)} pairs")

    if not (types or objects or noted):
        print("no QUEST, QOBJ or NOTED lines found in the log", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
