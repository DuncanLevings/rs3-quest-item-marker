"""Builds data/post_quest_items.lua: quest items still used after their quest ("keep") and
quest-only items that are no longer needed once the quest is done ("done").

Every quest is covered, including quests with no required items, because the starting point
is the Wiki's Category:Quest items, not the quests' "Items required" text. An item belongs to
the quests its infobox names (|quest = [[...]]), matched to quest titles despite spelling,
subquest and redirect differences. The page's quest categories stand in only when the
infobox names none: they also pick up items a quest page merely mentions (Buttons is in
"The Dig Site" for its list of extraneous finds, but belongs to Animal Magnetism).

Rules (hand-reviewed inputs in tools/data/post_quest_review.json):
  never marked  name matches never_marked_patterns, or the item has no quest we can match
  keep          lists an achievement ({{Achievement|...}}) or links to the master quest cape,
                or is in keep_add; never in keep_exclude or permanent. A keep item is kept
                until every achievement it lists is complete (just the master quest cape
                when it lists none), then it reads as "done".
  permanent     a lasting use (teleports, weapons, diving gear): never marked
  done          untradeable, in no "useful" category (incl. one named after a minigame or
                activity, so it can be got outside the quest), no keep signal, not required by any
                quest in data/quest_items.lua, not in done_exclude, every quest tracked, and
                no id shared with a keep, useful or common item. Every playable quest whose
                page links to the item joins its quests, since a quest may use an item it
                doesn't list (A Fairy Tale I's random ingredients)

Run from the plugin folder:
    py -3 -I tools/build_post_quest.py            (asks the Wiki, ~1 request a second)
    py -3 -I tools/build_post_quest.py --offline  (cache only)
"""
import argparse
import datetime
import json
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

# -I leaves the script's folder off the import path; add tools/ back (our own code only).
sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_quest_items import (SEASONAL_CATEGORIES, lua_string, match_quests, normalise,
                               page_categories, quest_category)
from wiki import ITEMS_PER_QUERY, TITLES_PER_QUERY, Wiki, WikiError, category_members, literal, write_json

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ROOT / "tools" / "data"
WORK = ROOT / "work"
OUTPUT = ROOT / "data" / "post_quest_items.lua"
REPORT = ROOT / "data" / "post_quest_report.txt"

SCHEMA = 1

# Pages linked from an item page that mean "needed for the master quest cape".
KEEP_LINKS = ["Master quest cape", "Master Quest Cape (achievement)"]

# The achievement that stands for "has the master quest cape".
MASTER_QUEST_CAPE = "Master Quest Cape"

# Templates on an item page that mean the page lists achievements it's used for.
KEEP_TEMPLATES = ["Template:Achievement"]

# Categories that mean the item is a lasting reward or generally useful, so it is never
# "no longer needed". "Keys" isn't one: nearly every quest key opens one door in its
# quest, and keys with a later use carry an achievement link, so they're "keep".
USEFUL_CATEGORIES = {
    "Equipable items", "Equipment", "Items on reward scrolls", "Experience lamps",
    "Lamps", "Teleportation items", "Tradeable items", "Pets", "Cosmetic overrides",
    "Free retrieve", "Tools", "Experience items", "Experience books", "Items sold by shops",
}

# An item in a category named after one of these categories' members (a minigame or
# activity, eg "Fishing Trawler") can be got outside its quest, so it's never "done".
ACTIVITY_CATEGORIES = ["Category:Minigames", "Category:Distractions and Diversions", "Category:Activities"]

ACHIEVEMENT_TEMPLATE = re.compile(r"\{\{\s*[Aa]chievement\s*\|\s*([^|}]+?)\s*[|}]")
INFOBOX_QUEST = re.compile(r"^\s*\|\s*quest\d*\s*=(.*)$", re.M)
LINK = re.compile(r"\[\[([^\]]+)\]\]")


def filtered_prop(wiki, titles, prop, targets):
    # {title: set of targets the page uses}, for prop=templates or prop=links, asking only
    # about the target pages so the answers stay small.
    found = defaultdict(set)
    key = {"templates": "tl", "links": "pl"}[prop]

    for start in range(0, len(titles), TITLES_PER_QUERY):
        params = {"action": "query", "prop": prop, key + "limit": "max",
                  key + ("templates" if prop == "templates" else "titles"): "|".join(targets),
                  "titles": "|".join(titles[start:start + TITLES_PER_QUERY])}

        while True:
            data = wiki.get(params)

            for page in data["query"]["pages"]:
                found[page["title"]].update(entry["title"] for entry in page.get(prop, []))

            if "continue" not in data:
                break

            params = dict(params, **data["continue"])

    return found


def linked_from(wiki, titles, quest_titles):
    # {title: set of quest titles whose page (or a subpage, "Quest/Quick guide") links to it}
    result = defaultdict(set)

    for start in range(0, len(titles), TITLES_PER_QUERY):
        params = {"action": "query", "prop": "linkshere", "lhnamespace": "0", "lhprop": "title",
                  "lhlimit": "max", "titles": "|".join(titles[start:start + TITLES_PER_QUERY])}

        while True:
            data = wiki.get(params)

            for page in data["query"]["pages"]:
                for entry in page.get("linkshere", []):
                    source = entry["title"].split("/", 1)[0]

                    if source in quest_titles:
                        result[page["title"]].add(source)

            if "continue" not in data:
                break

            params = dict(params, **data["continue"])

    return result


def page_texts(wiki, titles):
    # {title: wikitext}
    result = {}

    for start in range(0, len(titles), TITLES_PER_QUERY):
        data = wiki.get({"action": "query", "prop": "revisions", "rvprop": "content",
                         "rvslots": "main", "titles": "|".join(titles[start:start + TITLES_PER_QUERY])})

        for page in data["query"]["pages"]:
            result[page["title"]] = page["revisions"][0]["slots"]["main"]["content"] if page.get("revisions") else ""

    return result


def link_title(target):
    # "[[rocking_Out#Walkthrough|x]]" target -> "Rocking Out"
    target = target.split("|", 1)[0].split("#", 1)[0].replace("_", " ").strip()
    return target[:1].upper() + target[1:]


def quest_key(name):
    # Spelling-insensitive key: case, "&"/"and", "(quest)", "(miniquest)", and a
    # subpage ("Recipe for Disaster/Freeing ...") all ignored.
    name = name.split("/", 1)[-1] if "/" in name else name
    name = re.sub(r"\s*\(miniquest\)$", "", name, flags=re.I)
    return normalise(name)


def quest_lookup(quest_titles):
    # {key: quest title}: by full title and, for "Series: Part" titles, by the part alone.
    # A full title wins over another quest's part ("Shield of Arrav" over "Dimension of
    # Disaster: Shield of Arrav"); a part two quests share is left out rather than guessed.
    lookup = {quest_key(title): title for title in quest_titles}
    parts, clashes = {}, set()

    for title in quest_titles:
        key = quest_key(title.split(": ", 1)[-1])

        if key in parts and parts[key] != title:
            clashes.add(key)

        parts[key] = title

    for key, title in parts.items():
        if key not in lookup and key not in clashes:
            lookup[key] = title

    return lookup


def resolve_quest_links(wiki, links, lookup):
    # {link title: quest title} for the links that name a quest, following redirects for
    # those the lookup doesn't know. Links that aren't quests (NPCs, minigames) are left out.
    resolved, unknown = {}, []

    for link in links:
        title = lookup.get(quest_key(link))

        if title:
            resolved[link] = title
        else:
            unknown.append(link)

    for start in range(0, len(unknown), TITLES_PER_QUERY):
        batch = unknown[start:start + TITLES_PER_QUERY]
        data = wiki.get({"action": "query", "redirects": "1", "titles": "|".join(batch)})
        target = {link: link for link in batch}

        for step in ("normalized", "redirects"):
            for entry in data["query"].get(step, []):
                for link, current in target.items():
                    if current == entry["from"]:
                        target[link] = entry["to"]

        for link, current in target.items():
            title = lookup.get(quest_key(current))

            if title:
                resolved[link] = title

    return resolved


def infobox_quests(text):
    """The quests an item page's infobox names (|quest = , |quest1 = ...), as link titles.

    None when the infobox has no quest field, or names no quest by link ("Yes"); an
    empty set when it says "No". The categories stand in when it's None.
    """
    found, said_no = set(), False

    for value in INFOBOX_QUEST.findall(text):
        found.update(link_title(target) for target in LINK.findall(value))
        said_no = said_no or value.strip().lower() in ("no", "none")

    if found:
        return found

    return set() if said_no else None


def achievement_ids(wiki, names):
    # {achievement name: client achievement id} from bucket('achievement').
    found = {}
    names = sorted(names)

    for start in range(0, len(names), ITEMS_PER_QUERY):
        conditions = ",".join("{'name'," + literal(name) + "}" for name in names[start:start + ITEMS_PER_QUERY])
        rows = wiki.bucket("bucket('achievement').select('name','id')"
                           f".where(bucket.Or({conditions})).limit(5000).run()")

        for row in rows:
            if isinstance(row.get("id"), int):
                found[row["name"]] = row["id"]

    return found


def item_facts(wiki, titles):
    # {title: {"ids": set, "tradeable": bool}} from infobox_item, every version merged.
    facts = defaultdict(lambda: {"ids": set(), "tradeable": False})

    for start in range(0, len(titles), ITEMS_PER_QUERY):
        batch = titles[start:start + ITEMS_PER_QUERY]
        conditions = ",".join("{'page_name'," + literal(title) + "}" for title in batch)
        rows = wiki.bucket("bucket('infobox_item').select('page_name','item_id','tradeable')"
                           f".where(bucket.Or({conditions})).limit(5000).run()")

        for row in rows:
            ids = row.get("item_id") or []
            entry = facts[row["page_name"]]
            entry["ids"].update(int(number) for number in (ids if isinstance(ids, list) else [ids]))
            entry["tradeable"] = entry["tradeable"] or bool(row.get("tradeable"))

    return facts


def required_ids():
    # Every item id data/quest_items.lua lists, common items included.
    text = (ROOT / "data" / "quest_items.lua").read_text(encoding="utf-8")
    ids = set()

    for block in re.findall(r"items = \{([^}]*)\}", text):
        ids.update(int(number) for number in re.findall(r"\d+", block))

    ids.update(int(number) for number in re.findall(r"\[(\d+)\] = true", text))
    return ids


def classify(page, signals, quests, other_quests, tradeable, useful, review):
    """The verdict for one item page: "keep", "done" or a reason it gets no marker.

    signals: subset of {"achievement", "master quest cape"}. quests: quest names we can
    mark; other_quests: its quests we can't (unmatched, holiday, skipped). useful: the
    page's categories that are in USEFUL_CATEGORIES or name a minigame or activity.
    """
    if any(re.search(pattern, page, re.I) for pattern in review["never_marked_patterns"]):
        return "never (name)"

    if not quests:
        return "never (no quest)"

    if page in review["keep_exclude"]:
        return "never (keep_exclude)"

    if page in review["permanent"]:
        return "never (permanent)"

    if signals or page in review["keep_add"]:
        return "keep"

    if tradeable or useful:
        return "never (useful)"

    if page in review["done_exclude"]:
        return "never (done_exclude)"

    # "All its quests are finished" can't be checked for a quest we don't track.
    if other_quests:
        return "never (untracked quest)"

    return "done"


def keep_until(page, achievements, signals, known, review):
    """Achievement ids that, once all complete, end a keep item's use.

    Returns (ids, unresolved names).
    """
    ids = sorted({known[name] for name in achievements if name in known})
    unresolved = [name for name in achievements if name not in known]

    if not ids:
        # Only the master quest cape link (or nothing that resolved): kept until the cape.
        ids = [known[MASTER_QUEST_CAPE]]

    return ids, unresolved


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true", help="use cached Wiki answers only")
    args = parser.parse_args(argv)

    started = time.monotonic()
    wiki = Wiki(WORK / "wiki-cache", offline=args.offline)
    review = json.loads((INPUTS / "post_quest_review.json").read_text(encoding="utf-8"))
    client = json.loads((INPUTS / "client_quests.json").read_text(encoding="utf-8"))
    aliases = json.loads((INPUTS / "aliases.json").read_text(encoding="utf-8"))
    noted = {int(plain): int(note) for plain, note in
             json.loads((INPUTS / "noted_ids.json").read_text(encoding="utf-8"))["noted"].items()}

    # Same queries as build_quest_items.py, so these come from the cache.
    print("quests", flush=True)
    quest_rows = wiki.bucket("bucket('quest').select('page_name','json').limit(5000).run()")
    quest_titles = sorted({row["page_name"] for row in quest_rows})
    quest_categories = page_categories(wiki, quest_titles)

    # Quests whose items aren't tracked at all: removed, holiday events, the skip list.
    untracked = {title for title in quest_titles
                 if quest_categories[title] & (SEASONAL_CATEGORIES | {"Removed content"})
                 or title in aliases.get("skip", {})}
    matches, unmatched = match_quests([title for title in quest_titles if title not in untracked],
                                      client, aliases.get("aliases", {}))

    quests = {}

    for title, record in matches.items():
        category = quest_category(quest_categories[title], record.get("type"), [], title)

        if category in ("quest", "miniquest"):
            quests[title] = {"id": record["id"], "config": record["config"],
                             "name": record["name"], "category": category}

    print("quest items", flush=True)
    items = sorted(title for title in category_members(wiki, "Category:Quest items")
                   if not title.startswith(("Category:", "File:", "Template:")))
    categories = page_categories(wiki, items)
    templates = filtered_prop(wiki, items, "templates", KEEP_TEMPLATES)
    links = filtered_prop(wiki, items, "links", KEEP_LINKS)
    facts = item_facts(wiki, items)
    required = required_ids()

    activities = set()

    for category in ACTIVITY_CATEGORIES:
        activities.update(category_members(wiki, category))

    activities -= set(quest_titles)

    print("item pages", flush=True)
    texts = page_texts(wiki, items)
    named_by_page = {title: infobox_quests(texts.get(title, "")) for title in items}
    quest_links = resolve_quest_links(
        wiki, sorted({link for named in named_by_page.values() if named for link in named}),
        quest_lookup(quest_titles))
    table = []

    for title in items:
        cats = categories.get(title, set())
        info = facts.get(title, {"ids": set(), "tradeable": False})
        signals = []

        if templates.get(title):
            signals.append("achievement")

        if links.get(title):
            signals.append("master quest cape")

        # The infobox names the quest the item really belongs to; the categories also
        # pick up items a quest page merely mentions. Categories only stand in when the
        # infobox names no quest. Infobox links that aren't quests (an NPC) are dropped.
        named = named_by_page[title]
        source = "categories" if named is None else "infobox"
        belongs = (cats & set(quest_titles)) if named is None else \
            {quest_links[link] for link in named if link in quest_links}
        marked = sorted(belongs & set(quests))
        other = sorted(belongs - set(quests))
        ids = set(info["ids"])
        ids.update(noted[number] for number in info["ids"] if number in noted)

        table.append({
            "page": title,
            "quests": marked,
            "otherQuests": other,
            "questSource": source,
            "ids": sorted(ids),
            "signals": signals,
            "verdict": classify(title, signals, marked, other, info["tradeable"],
                                sorted(cats & (USEFUL_CATEGORIES | activities)), review),
        })

    print("achievements", flush=True)
    keep_rows = [row for row in table if row["verdict"] == "keep"]
    listed = {row["page"]: sorted(set(ACHIEVEMENT_TEMPLATE.findall(texts.get(row["page"], ""))))
              for row in keep_rows if "achievement" in row["signals"]}
    known = achievement_ids(wiki, {name for names in listed.values() for name in names} | {MASTER_QUEST_CAPE})

    if MASTER_QUEST_CAPE not in known:
        raise WikiError(f"no achievement id for {MASTER_QUEST_CAPE}")

    unresolved = {}

    for row in keep_rows:
        row["achievements"] = listed.get(row["page"], [])
        row["until"], missing = keep_until(row["page"], row["achievements"], row["signals"], known, review)

        if missing:
            unresolved[row["page"]] = missing

    # A quest page that links to a "done" item may use it without listing it (A Fairy Tale I
    # picks random ingredients, Red vine worm among them), so every quest whose page links
    # to the item must be finished too. A link from a quest we don't track (a holiday
    # quest, Dimension of Disaster) means "done" can't be checked, so the item gets no
    # marker. Removed quests (the historical versions) can't be played, so their links
    # don't count.
    print("quest pages linking to items", flush=True)
    done_rows = [row for row in table if row["verdict"] == "done"]
    playable = {title for title in quest_titles if "Removed content" not in quest_categories[title]}
    linking = linked_from(wiki, [row["page"] for row in done_rows], playable)

    for row in done_rows:
        extra = linking.get(row["page"], set()) - set(row["quests"])
        row["linkedQuests"] = sorted(extra)

        if extra - set(quests):
            row["verdict"] = "never (linked from untracked quest)"
        else:
            row["quests"] = sorted(set(row["quests"]) | extra)

    # An id shared with anything that isn't "done" (another version of a keep item, say),
    # or required by a quest, is never "done".
    blocked = set(required)

    for row in table:
        if row["verdict"] != "done":
            blocked.update(row["ids"])

    keep, until, done = defaultdict(set), {}, defaultdict(set)
    names = {}
    dropped = Counter()

    for row in table:
        quest_ids = {quests[title]["id"] for title in row["quests"]}

        for number in row["ids"]:
            if row["verdict"] == "keep":
                keep[number].update(quest_ids)
                names.setdefault(number, row["page"])

                # Two pages on one id: every achievement counts.
                until[number] = sorted(set(until.get(number, [])) | set(row["until"]))
            elif row["verdict"] == "done":
                if number in blocked:
                    dropped["done id shared or required"] += 1
                else:
                    done[number].update(quest_ids)
                    names.setdefault(number, row["page"])

    # An id both kept and done (two pages, one id) is kept: a missed "done" is harmless.
    for number in keep:
        done.pop(number, None)

    used = {quest_id for groups in (keep, done) for ids in groups.values() for quest_id in ids}
    out_quests = sorted((quest for quest in quests.values() if quest["id"] in used),
                        key=lambda quest: quest["id"])

    snapshot = datetime.date.today().isoformat()
    write_json(WORK / "post_quest_table.json", table)
    write_report(snapshot, table, keep, until, done, dropped, unmatched, unresolved, known, wiki,
                 time.monotonic() - started)
    used_achievements = {number for ids in until.values() for number in ids}
    achievement_names = {number: name for name, number in known.items() if number in used_achievements}
    write_lua(snapshot, out_quests, achievement_names, keep, until, done, names)
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(keep)} keep ids, {len(done)} done ids, "
          f"{len(out_quests)} quests")
    return 0


def write_report(snapshot, table, keep, until, done, dropped, unmatched, unresolved, known, wiki, seconds):
    verdicts = Counter(row["verdict"] for row in table)
    by_id = {number: name for name, number in known.items()}
    lines = [
        f"Post-quest items build report - {snapshot}",
        f"Quest item pages: {len(table)}",
        f"Requests: {wiki.sent} sent, {wiki.cached} from cache; {seconds:.0f} s",
        f"Wiki quests not matched to a client quest (their items get no marker): {len(unmatched)}",
        "",
        "Pages by verdict",
    ]
    lines += [f"  {count:5}  {verdict}" for verdict, count in sorted(verdicts.items())]
    lines += [
        "",
        f"Item ids written: keep {len(keep)}, done {len(done)}",
        f"Done ids dropped (shared with another verdict, or required by a quest): "
        f"{dropped['done id shared or required']}",
        f"Done pages that also wait for other quests linking to them: "
        f"{sum(1 for row in table if row['verdict'] == 'done' and row.get('linkedQuests'))}",
        "",
        "Achievement names with no achievement id (ignored)",
    ]
    lines += [f"  {page}: {', '.join(names)}" for page, names in sorted(unresolved.items())]
    lines += ["", "Keep pages (kept until these achievements are complete)"]

    for row in table:
        if row["verdict"] == "keep":
            kept = ", ".join(by_id.get(number, str(number)) for number in row["until"])
            lines.append(f"  {row['page']} ({', '.join(row['quests'])}): {kept}")

    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"report: {REPORT.relative_to(ROOT)}")


def write_lua(snapshot, quests, achievement_names, keep, until, done, names):
    out = [
        "-- Generated by tools/build_post_quest.py. Don't edit by hand: fix tools/data/ and rebuild.",
        "-- Derived from the RuneScape Wiki (RuneScape Wiki contributors, CC BY-NC-SA 3.0); see",
        "-- THIRD_PARTY_NOTICES.txt. Quest and achievement ids are RuneScape client identifiers",
        "-- (Jagex Ltd.).",
        "return {",
        f"    schema = {SCHEMA},",
        f"    snapshot = {lua_string(snapshot)},",
        '    attribution = "RuneScape Wiki contributors, CC BY-NC-SA 3.0",',
        "",
        "    quests = {",
    ]

    for quest in quests:
        out.append(f"        [{quest['id']}] = {{ name = {lua_string(quest['name'])}, "
                   f"category = {lua_string(quest['category'])} }}, -- {quest['config']}")

    out.append("    },")
    out += ["", "    -- Names of the achievements in keepUntil, for the tooltip.", "    achievements = {"]

    for number, name in sorted(achievement_names.items()):
        out.append(f"        [{number}] = {lua_string(name)},")

    out.append("    },")

    def item_list(label, comment, group):
        lines = ["", f"    -- {comment}", f"    {label} = {{"]

        for number in sorted(group):
            values = ", ".join(str(value) for value in sorted(group[number]))
            lines.append(f"        [{number}] = {{ {values} }}, -- {names[number]}")

        return lines + ["    },"]

    out += item_list("keep", "Still used after the quest: marked once any of its quests is finished.", keep)
    out += item_list("keepUntil", "Achievement ids that end a keep item's use once all are complete.",
                     until)
    out += item_list("done", "Only used in its quests: marked once all of them are finished.", done)
    out += ["}", ""]
    OUTPUT.write_text("\n".join(out), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except WikiError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
