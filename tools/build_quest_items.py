"""Builds data/quest_items.lua (which items each quest needs) from the RuneScape Wiki.

What this file does: the whole offline pipeline from the design doc (Technical Plan §2):
fetch -> override -> parse -> resolve links to item IDs -> noted IDs -> match quests ->
check and write. It owns the generated files data/quest_items.lua and data/build_report.txt.
The line parser lives in quest_parser.py (no network) and the HTTP client in wiki.py.

The build is all-or-nothing: if any link can't be resolved, or any quest with items can't be
matched to a client quest, nothing is written and the report says what to fix. Fixes go in
the hand-reviewed files in tools/data/ (see tools/README.txt).

Usage (from the plugin folder; -I so nothing in work/ can shadow a module):
    py -3 -I tools/build_quest_items.py                    full build
    py -3 -I tools/build_quest_items.py --sample           the 10 sample quests, report only
    py -3 -I tools/build_quest_items.py --only "Priest in Peril"
    py -3 -I tools/build_quest_items.py --offline          cached answers only, no network
"""
import argparse
import datetime
import json
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

# -I (isolated mode) leaves the script's own folder off the import path, so add tools/ back
# by hand. That's our own code; work/ (downloads) is still never importable.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from quest_parser import NON_ITEM_NAMESPACES, parse_items
from wiki import (ITEMS_PER_QUERY, TITLES_PER_QUERY, Wiki, WikiError, category_members,
                  literal, page_info, write_json)

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ROOT / "tools" / "data"
WORK = ROOT / "work"
OUTPUT = ROOT / "data" / "quest_items.lua"
REPORT = ROOT / "data" / "build_report.txt"

SCHEMA = 1

# The M1 sample: template-heavy pages, nested "any one of" lists, headers that exclude the
# items under them, and Priest in Peril's choice-dependent amounts (50 rune or 25 pure).
SAMPLE_QUESTS = [
    "Priest in Peril",
    "Cook's Assistant",
    "Dimension of Disaster",
    "Doric's Task V (miniquest)",
    "Heroes' Quest",
    "Throne of Miscellania",
    "The Fremennik Isles",
    "Curse of the Black Stone",
    "Murder on the Border",
    "Goblin Diplomacy",
]

# A link to a page in one of these Wiki categories, with no item infobox, is a person, place,
# skill, spell or quest: never an item, so it's ignored without a manual entry.
NON_ITEM_CATEGORIES = {
    "Locations", "Non-player characters", "Interactive characters", "Non-interactive characters",
    "Shops", "Scenery", "Interactive scenery", "Spells", "Quests", "Miniquests", "Cities",
    "Skills", "Dungeons", "Runecrafting altars", "Bestiary", "Members' bestiary", "Minigames",
    "Regions", "Quest NPCs", "Merchants", "Humans", "Quest locations", "Achievements",
    "Combat", "Interface", "Banks", "Lodestones", "Guilds", "Islands", "Kingdoms", "Towns",
    "Villages", "Activities", "Distractions and Diversions", "Game mechanics", "Familiars",
    "Summoning familiars", "Pets", "Abilities", "Prayers", "Bosses", "Monsters", "Skilling spots",
    "Organisations", "Gangs", "Factions", "Cosmetic overrides", "Set overrides",
    "Combat classes", "Combat spells", "Standard spells", "Lunar spells", "Rituals", "Game info",
    "Game modes", "Transportation",
}

# Only physical items you carry are marked. Some pages have an item infobox but are drawn
# or built, never held: Necromancy glyphs ("Elemental I") and house furniture ("Clockmaker's
# bench 3"). A page in one of these categories is never an item, infobox or not.
NOT_CARRIED_CATEGORIES = {"Glyphs", "Furniture"}
NON_ITEM_CATEGORIES |= NOT_CARRIED_CATEGORIES

# Wiki categories that make a quest seasonal (holiday) or a tutorial. Until a client dump with
# QuestType.type is added, these stand in for the client's type 1 / type 2. Only "Seasonal
# quests" counts: "<year> Christmas event" style categories are also on permanent quests
# that began as events (Swept Away, Violet is Blue, Myths of the White Lands).
SEASONAL_CATEGORIES = {"Seasonal quests"}
TUTORIAL_CATEGORIES = {"Tutorials"}

# Seasonal (holiday event) quests are left out of the data entirely (author decision,
# 2026-11-16): their items aren't tracked.
CATEGORIES = ["quest", "miniquest", "tutorial"]   # closed list (storage contract)


# ---------------------------------------------------------------------------------------
# Hand-reviewed inputs in tools/data/
# ---------------------------------------------------------------------------------------

def load_json(path, default=None):
    if not path.exists():
        return default

    return json.loads(path.read_text(encoding="utf-8"))


def load_inputs():
    """Reads every hand-maintained file. Missing optional files mean "nothing yet"."""
    overrides = {}

    for path in sorted((INPUTS / "overrides").glob("*.json")):
        override = load_json(path)
        overrides[override["quest"]] = dict(override, file=path.name)

    return {
        "client": load_json(INPUTS / "client_quests.json"),
        "aliases": load_json(INPUTS / "aliases.json", {"aliases": {}, "skip": {}}),
        "links": load_json(INPUTS / "link_classes.json", {}),
        "common": load_json(INPUTS / "common_items.json", {"items": {}}),
        "noted": load_json(INPUTS / "noted_ids.json", {"noted": {}}),
        # Optional: (quest name -> item IDs) from the client's ObjType.quests, for the
        # "given by the quest" cross-check. Produced by the probe; see tools/README.txt.
        "client_objects": load_json(INPUTS / "client_quest_objects.json"),
        "overrides": overrides,
    }


# ---------------------------------------------------------------------------------------
# Fetching (every answer is cached by wiki.py)
# ---------------------------------------------------------------------------------------

def page_categories(wiki, titles):
    # {title: set of visible category names, without the "Category:" prefix}
    result = defaultdict(set)
    titles = sorted(set(titles))

    for start in range(0, len(titles), TITLES_PER_QUERY):
        params = {"action": "query", "prop": "categories", "cllimit": "max", "clshow": "!hidden",
                  "titles": "|".join(titles[start:start + TITLES_PER_QUERY])}

        # A batch with many categories comes back in parts; keep asking until it's done.
        while True:
            data = wiki.get(params)

            for page in data["query"]["pages"]:
                result[page["title"]].update(category["title"][len("Category:"):]
                                             for category in page.get("categories", []))

            if "continue" not in data:
                break

            params = dict(params, **data["continue"])

    return result


def page_links(wiki, titles):
    # {title: [article links on that page]}, used to expand disambiguation pages.
    result = defaultdict(list)
    titles = sorted(set(titles))

    for start in range(0, len(titles), TITLES_PER_QUERY):
        params = {"action": "query", "prop": "links", "pllimit": "max", "plnamespace": 0,
                  "titles": "|".join(titles[start:start + TITLES_PER_QUERY])}

        while True:
            data = wiki.get(params)

            for page in data["query"]["pages"]:
                result[page["title"]].extend(link["title"] for link in page.get("links", []))

            if "continue" not in data:
                break

            params = dict(params, **data["continue"])

    return result


def item_rows(wiki, titles):
    """infobox_item rows per page: every version, every ID (not just the first, as the old
    monster-data-core fetch_items did)."""
    result = defaultdict(list)
    titles = sorted(set(titles))
    fields = "'page_name','item_name','item_id','version_anchor','noteable'"

    for start in range(0, len(titles), ITEMS_PER_QUERY):
        batch = titles[start:start + ITEMS_PER_QUERY]
        conditions = ",".join("{'page_name'," + literal(title) + "}" for title in batch)
        rows = wiki.bucket(f"bucket('infobox_item').select({fields})"
                           f".where(bucket.Or({conditions})).limit(5000).run()")

        # 5000 rows for 40 pages would mean the answer was cut off; don't trust it.
        if len(rows) >= 5000:
            raise WikiError(f"infobox_item answer was cut off for {batch}")

        for row in rows:
            ids = row.get("item_id") or []

            if isinstance(ids, int):
                ids = [ids]

            if any(not isinstance(number, int) or number < 0 for number in ids):
                raise WikiError(f"bad item_id {ids!r} on {row.get('page_name')}")

            result[row["page_name"]].append({
                "version": row.get("version_anchor") or "",
                "ids": sorted(set(ids)),
                "noteable": bool(row.get("noteable")),
            })

    return result


# ---------------------------------------------------------------------------------------
# Resolving links to item IDs
# ---------------------------------------------------------------------------------------

class Resolver:
    """Turns a page name (+ optional #version) into item IDs, or says why it can't.

    Fetches what it needs in batches through prepare(), then answers resolve() from memory.
    The order of rules matters and is the same for every link:
      1. a manual entry in link_classes.json (expand to listed pages, or ignore)
      2. an item page in infobox_item           -> its IDs ("automatic"), unless the page is
                                                   in NOT_CARRIED_CATEGORIES (glyphs, furniture)
      3. a disambiguation page                  -> the item pages it links to ("generic")
      4. a page in a non-item category          -> ignored (NPCs, places, skills...)
      5. anything else                          -> unresolved, the build fails
    """

    def __init__(self, wiki, link_classes):
        self.wiki = wiki
        self.classes = link_classes
        self.info = {}        # asked title -> {"title", "revid", "fragment"}
        self.items = {}       # real title -> infobox rows
        self.categories = {}  # real title -> categories
        self.disambiguation = {}  # real title -> item pages it links to

    def prepare(self, titles):
        titles = {title for title in titles if title and title not in self.info}

        if not titles:
            return

        self.info.update(page_info(self.wiki, titles))
        real = {self.info[title]["title"] for title in titles if self.info[title]["title"]}

        # Manual expansions name more pages; they need resolving too. Entries are keyed by
        # the real page ("Hatchets"), which is only known after redirects ("hatchet").
        expansions = {page for title in real | titles
                      for page in self.classes.get(title, {}).get("expand", [])}
        self.prepare({split_anchor(page)[0] for page in expansions})
        self.items.update(item_rows(self.wiki, [title for title in real if title not in self.items]))

        # Every page's categories: an item page may still be something you can't carry, and
        # a page with no item IDs needs them to say what it is.
        self.categories.update(page_categories(self.wiki, [title for title in real
                                                           if title not in self.categories]))
        others = [title for title in real if not self._ids_of(title)]

        # Disambiguation pages point at the real item pages; fetch those in a second round.
        ambiguous = [title for title in others if "Disambiguation" in self.categories.get(title, ())]
        linked = page_links(self.wiki, ambiguous)

        if linked:
            self.prepare({page for pages in linked.values() for page in pages})

        for title in ambiguous:
            self.disambiguation[title] = [page for page in linked.get(title, [])
                                          if self.info.get(page, {}).get("title")
                                          and self._ids_of(self.info[page]["title"])]

    def _ids_of(self, title, version=None):
        if self.categories.get(title, set()) & NOT_CARRIED_CATEGORIES:
            return []

        rows = self.items.get(title, [])

        if version:
            wanted = version.casefold().strip()
            chosen = [row for row in rows if row["version"].casefold().strip() == wanted]

            # An anchor that matches no version (eg a redirect to "Cat#Overgrown cats") falls
            # back to every version: leaning towards marking.
            if chosen:
                rows = chosen

        return sorted({number for row in rows for number in row["ids"]})

    def anchor_matches(self, title, version):
        return any(row["version"].casefold().strip() == version.casefold().strip()
                   for row in self.items.get(title, []))

    def resolve(self, target, fragment=None):
        """Returns (kind, ids, detail). kind: item | generic | ignored | unresolved."""
        if target.startswith("#"):
            entry = self.classes.get(target)

            if entry and "ignore" in entry:
                return "ignored", [], entry["ignore"]

            return "unresolved", [], "link to a section of the quest page itself"

        if target.lower().startswith(NON_ITEM_NAMESPACES):
            return "ignored", [], "not an article"

        info = self.info.get(target)

        if not info or not info["title"]:
            return "unresolved", [], "page doesn't exist"

        title = info["title"]
        version = fragment or info["fragment"]
        entry = self.classes.get(title) or self.classes.get(target)

        # 1. A reviewed decision beats every automatic rule.
        if entry and "ignore" in entry:
            return "ignored", [], entry["ignore"]

        if entry and "expand" in entry:
            ids = set()

            for page in entry["expand"]:
                kind, page_ids, detail = self.resolve(*split_anchor(page))

                if kind not in ("item", "generic"):
                    return "unresolved", [], f"expansion page {page}: {detail}"

                ids.update(page_ids)

            return "generic", sorted(ids), "link_classes.json"

        # 2. An item page.
        ids = self._ids_of(title, version)

        if ids:
            detail = title

            if version and not self.anchor_matches(title, version):
                detail += f" (no version '{version}', all versions used)"

            return "item", ids, detail

        # 3. A disambiguation page: every item page it lists.
        if title in self.disambiguation:
            pages = self.disambiguation[title]
            ids = sorted({number for page in pages for number in self._ids_of(self.info[page]["title"])})

            if ids:
                return "generic", ids, "disambiguation: " + ", ".join(pages)

            return "unresolved", [], "disambiguation page with no item pages"

        # 4. Clearly not an item.
        categories = self.categories.get(title, set())
        hits = sorted(categories & NON_ITEM_CATEGORIES)

        if hits:
            return "ignored", [], "category " + hits[0]

        # 5. Someone has to decide.
        return "unresolved", [], "no item infobox; categories: " + (", ".join(sorted(categories)) or "none")


def split_anchor(page):
    # "Watering can#(8)" -> ("Watering can", "(8)")
    if "#" in page and not page.startswith("#"):
        title, anchor = page.split("#", 1)
        return title.strip(), anchor.strip() or None

    return page, None


# ---------------------------------------------------------------------------------------
# One quest: lines -> needs
# ---------------------------------------------------------------------------------------

def wanted_targets(lines):
    for line in lines:
        if line.status != "required":
            continue

        for link in line.links:
            if not link.negated:
                yield link.target


def build_needs(lines, resolver, stats, problems, quest):
    """Turns parsed lines into the contract's needs list, counting what happened."""
    groups = {}   # index of the line a need belongs to -> need under construction

    for index, line in enumerate(lines):
        if line.status == "markup":
            continue

        if line.status == "excluded":
            stats["lines excluded (given by quest / optional)"] += 1
            continue

        owner = line.merge_into if line.merge_into is not None else index
        need = groups.setdefault(owner, {"ids": [], "amounts": {}, "anyOf": False, "how": set(),
                                         "lines": [], "sets": {}})
        need["lines"].append(line.number)

        # A sub-bullet merged into its parent is an alternative, so the need is "any one of".
        if line.merge_into is not None or line.any_of:
            need["anyOf"] = True

        for link_index, link in enumerate(line.links):
            if link.negated:
                stats["links dropped (\"will not work\")"] += 1
                continue

            # Which alternative of the need this link belongs to. A line split into
            # combinations keeps its groups; a plain "or" line gives each link its own;
            # a line with no "or" (a parent whose alternatives are sub-bullets) is one
            # combination of everything on it.
            if line.groups is not None:
                set_key = (line.number, line.groups[link_index])
            elif line.any_of:
                set_key = (line.number, link_index)
            else:
                set_key = (line.number, 0)

            kind, ids, detail = resolver.resolve(link.target, link.fragment)

            if kind == "unresolved":
                problems.append(f"{quest}: line {line.number}: [[{link.target}"
                                f"{'#' + link.fragment if link.fragment else ''}]] - {detail}")
                need["how"].add("unresolved")
                continue

            if kind == "ignored":
                stats["links ignored (not items)"] += 1
                continue

            if "no version" in detail:
                stats["links with an unknown #version (all versions used)"] += 1

            need["how"].add(kind)
            alternative = need["sets"].setdefault(set_key, {"ids": [], "links": 0, "parts": [],
                                                            "generic": False})
            alternative["links"] += 1
            alternative["parts"].append(list(ids))
            alternative["generic"] = alternative["generic"] or kind == "generic"

            for number in ids:
                if number not in need["ids"]:
                    need["ids"].append(number)

                if number not in alternative["ids"]:
                    alternative["ids"].append(number)

                # Each quest keeps its own amount; an item named twice keeps the first.
                if link.amount is not None and number not in need["amounts"]:
                    need["amounts"][number] = link.amount

    needs = []

    for owner in sorted(groups):
        need = groups[owner]

        if not need["ids"]:
            # A required line that only mentions people, places or free space.
            if "unresolved" not in need["how"]:
                stats["lines with no items (non-item)"] += 1
            continue

        if "generic" in need["how"]:
            stats["lines generic-expanded"] += 1
        else:
            stats["lines automatic"] += 1

        # A single item can't be "any one of".
        any_of = need["anyOf"] and len(need["ids"]) > 1
        alternatives = []

        for key in sorted(need["sets"]):
            alternative = need["sets"][key]

            # A generic link ("any [[light source]]") is a choice by itself, so a
            # combination holding one is a misread: split it back into single choices.
            if alternative["generic"] and alternative["links"] > 1:
                alternatives += [{"ids": ids, "links": 1} for ids in alternative["parts"] if ids]
            else:
                alternatives.append(alternative)

        sets = None

        if any_of and any(alternative["links"] > 1 for alternative in alternatives):
            if len(alternatives) == 1:
                # Every alternative but one was a person or place: one combination, all
                # of it needed ("[[empty pot]] and [[pot lid]] (... a [[potter's wheel]])").
                any_of = False
            else:
                sets = [alternative["ids"] for alternative in alternatives]

        entry = {"items": need["ids"], "amounts": need["amounts"], "anyOf": any_of}

        if sets:
            entry["sets"] = sets

        needs.append(entry)

    return dedupe(needs)


def needs_from_override(override, resolver, problems):
    # An override lists item pages (with optional #version) instead of Wiki text.
    needs = []

    for entry in override["needs"]:
        ids, amounts = [], {}

        for page in entry["items"]:
            kind, page_ids, detail = resolver.resolve(*split_anchor(page))

            if kind not in ("item", "generic"):
                problems.append(f"{override['quest']}: override page {page} - {detail}")
                continue

            ids.extend(number for number in page_ids if number not in ids)

            if page in entry.get("amounts", {}):
                for number in page_ids:
                    amounts[number] = entry["amounts"][page]

        if ids:
            needs.append({"items": ids, "amounts": amounts,
                          "anyOf": bool(entry.get("anyOf")) and len(ids) > 1})

    return dedupe(needs)


def dedupe(needs):
    # Heroes' Quest lists the same armour for solo and partner play; once is enough.
    seen, result = set(), []

    for need in needs:
        key = (tuple(need["items"]), tuple(sorted(need["amounts"].items(), key=str)), need["anyOf"],
               tuple(tuple(ids) for ids in need.get("sets") or ()))

        if key not in seen:
            seen.add(key)
            result.append(need)

    return result


# ---------------------------------------------------------------------------------------
# Matching Wiki quests to client quests
# ---------------------------------------------------------------------------------------

def normalise(name):
    # "Black Knights' Fortress (quest)" and "Black Knights' Fortress" are the same quest;
    # so are "Romeo & Juliet" and "Romeo and Juliet". Miniquest/saga suffixes are kept,
    # because the client names include them.
    name = name.replace("&", "and").replace("’", "'")
    name = re.sub(r"\s*\((?:quest|holiday event|\d{4} [\w' ]+ event)\)$", "", name)
    return re.sub(r"\s+", " ", name).strip().casefold()


def match_quests(titles, client, aliases):
    """Wiki title -> client quest record, using only live (non-deprecated) client quests.

    Returns (matches, unmatched). An alias may give a client id (for duplicate names such as
    the two live "Rune Mysteries") or a client name.
    """
    live = [quest for quest in client["quests"] if not quest["deprecated"] and quest["name"]]
    by_id = {quest["id"]: quest for quest in live}
    by_name = defaultdict(list)

    for quest in live:
        by_name[normalise(quest["name"])].append(quest)

    matches, unmatched = {}, []

    for title in titles:
        alias = aliases.get(title)

        if isinstance(alias, int):
            if alias in by_id:
                matches[title] = by_id[alias]
                continue
        elif isinstance(alias, str):
            found = by_name.get(normalise(alias), [])

            if len(found) == 1:
                matches[title] = found[0]
                continue

        # Subquest pages are "Series: Part"; the client often names just the part.
        candidates = by_name.get(normalise(title)) or by_name.get(normalise(title.split(": ", 1)[-1]))

        if candidates and len(candidates) == 1:
            matches[title] = candidates[0]
        else:
            unmatched.append((title, "duplicate client name" if candidates else "no client quest"))

    return matches, unmatched


def quest_category(categories, client_type, warnings, name):
    """One category per quest: tutorial, seasonal, miniquest or quest.

    The client's QuestType.type (1 holiday, 2 tutorial) decides seasonal and tutorial when
    client_quests.json has it; until then the Wiki categories stand in. Disagreements are
    reported, not fatal.
    """
    wiki = None

    if categories & TUTORIAL_CATEGORIES:
        wiki = "tutorial"
    elif categories & SEASONAL_CATEGORIES:
        wiki = "seasonal"

    client = {1: "seasonal", 2: "tutorial"}.get(client_type)

    if client_type is not None and client != wiki:
        warnings.append(f"category conflict for {name}: client type {client_type}, Wiki says "
                        f"{wiki or 'quest/miniquest'}; the client wins")

    special = client if client_type is not None else wiki

    if special:
        return special

    if "Miniquests" in categories:
        return "miniquest"

    if "Quests" in categories:
        return "quest"

    return None


# ---------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------

def lua_string(text):
    # A double-quoted Lua string. json.dumps isn't quite right: it writes control characters
    # as \uXXXX, which Lua 5.4 doesn't read. (From skill-tips/tools/list_item_ids.py.)
    escaped = []

    for character in text:
        code = ord(character)

        if character in '"\\':
            escaped.append("\\" + character)
        elif code < 32 or code == 127:
            escaped.append(f"\\{code:03d}")
        else:
            escaped.append(character)

    return '"' + "".join(escaped) + '"'


def lua_amount(value):
    return str(value) if isinstance(value, int) else lua_string(str(value))


def write_lua(path, snapshot, quests, common, coverage):
    out = [
        "-- Generated by tools/build_quest_items.py. Don't edit by hand: fix tools/data/ and rebuild.",
        "-- Item requirements derived from the RuneScape Wiki (RuneScape Wiki contributors,",
        "-- CC BY-NC-SA 3.0); see THIRD_PARTY_NOTICES.txt. Quest ids are RuneScape client",
        "-- identifiers (Jagex Ltd.). Shape: docs/designs/quest_item_marker.md, Technical Plan §1.",
        "return {",
        f"    schema = {SCHEMA},",
        f"    snapshot = {lua_string(snapshot)},",
        '    attribution = "RuneScape Wiki contributors, CC BY-NC-SA 3.0",',
        f"    coverage = {{ matched = {coverage['matched']}, wikiQuests = {coverage['wikiQuests']} }},",
        "    categories = { " + ", ".join(lua_string(name) for name in CATEGORIES) + " },",
        "",
        "    -- Required, but so common that marking it would mean nothing: never marked (no icon, no tooltip).",
        "    common = {",
    ]

    for number, name in sorted(common.items()):
        out.append(f"        [{number}] = true, -- {name}")

    out += ["    },", "", "    quests = {"]

    for quest in quests:
        out.append("        {")
        out.append(f"            id = {quest['id']}, -- {quest['config']}")
        out.append(f"            name = {lua_string(quest['name'])},")
        out.append(f"            category = {lua_string(quest['category'])},")

        if quest.get("saga"):
            out.append(f"            saga = {lua_string(quest['saga'])},")

        out.append(f"            revision = {quest['revision']},")
        out.append("            needs = {")

        for need in quest["needs"]:
            parts = ["items = { " + ", ".join(str(number) for number in need["items"]) + " }"]

            if need["amounts"]:
                amounts = ", ".join(f"[{number}] = {lua_amount(amount)}"
                                    for number, amount in sorted(need["amounts"].items()))
                parts.append("amounts = { " + amounts + " }")

            if need["anyOf"]:
                parts.append("anyOf = true")

            if need.get("sets"):
                sets = ", ".join("{ " + ", ".join(str(number) for number in ids) + " }"
                                 for ids in need["sets"])
                parts.append("sets = { " + sets + " }")

            out.append("                { " + ", ".join(parts) + " },")

        out.append("            },")
        out.append("        },")

    out += ["    },", "}", ""]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out), encoding="utf-8", newline="\n")


# ---------------------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", action="append", default=[], help="build just these Wiki titles (report only)")
    parser.add_argument("--sample", action="store_true", help="build the 10 sample quests (report only)")
    parser.add_argument("--offline", action="store_true", help="use cached Wiki answers only")
    parser.add_argument("--refresh", action="store_true", help="ask the Wiki again, replacing the cache")
    parser.add_argument("--delay", type=float, default=1.0, help="seconds between requests (min 1)")
    parser.add_argument("--suggest", action="store_true",
                        help="for each unresolved page, print the item pages it links to "
                             "(a starting point for a link_classes.json expansion)")
    args = parser.parse_args(argv)

    started = time.monotonic()
    inputs = load_inputs()
    wiki = Wiki(WORK / "wiki-cache", offline=args.offline, refresh=args.refresh, delay=args.delay)
    partial = bool(args.only or args.sample)
    stats = Counter()
    problems, warnings = [], []

    # --- 1. Fetch the quest rows, their pages' revisions and categories ---------------------
    print("fetching quest rows", flush=True)
    rows = wiki.bucket("bucket('quest').select('page_name','json').limit(5000).run()")
    quests = {row["page_name"]: json.loads(row["json"]) for row in rows}

    if len(rows) >= 5000:
        raise WikiError("bucket('quest') answer was cut off")

    titles = sorted(quests)

    if partial:
        wanted = args.only or SAMPLE_QUESTS
        missing = [title for title in wanted if title not in quests]

        if missing:
            raise SystemExit(f"not in bucket('quest'): {missing}")

        titles = wanted

    revisions = {title: info["revid"] for title, info in page_info(wiki, titles).items()}
    categories = page_categories(wiki, titles)

    # --- 2/3. Overrides replace a quest's list; everything else is parsed -------------------
    parsed, skipped = {}, {}

    for title in titles:
        if "Removed content" in categories.get(title, set()):
            skipped[title] = "removed from the game (Wiki: Removed content)"
            continue

        # Event quests aren't tracked; skip them before their links have to resolve. A quest
        # only the client's type calls seasonal is caught again at step 7.
        if categories.get(title, set()) & SEASONAL_CATEGORIES:
            skipped[title] = "holiday event quest (event items aren't tracked)"
            continue

        if title in inputs["aliases"].get("skip", {}):
            skipped[title] = inputs["aliases"]["skip"][title]
            continue

        if title in inputs["overrides"]:
            continue

        text = quests[title].get("items") or ""

        if text.strip():
            parsed[title] = parse_items(text)

    # --- 4. Resolve every link and override page --------------------------------------------
    print("resolving links", flush=True)
    resolver = Resolver(wiki, inputs["links"])
    targets = {target for lines in parsed.values() for target in wanted_targets(lines)}

    for override in inputs["overrides"].values():
        targets.update(split_anchor(page)[0] for need in override["needs"] for page in need["items"])

    targets.update(inputs["common"]["items"])
    resolver.prepare(targets)

    built = {}

    for title in titles:
        if title in skipped:
            continue

        override = inputs["overrides"].get(title)

        if override:
            stats["quests overridden"] += 1
            stats["lines overridden"] += len(override["needs"])

            # The override was written against one revision; a newer page may have changed.
            if override.get("revision") != revisions.get(title):
                warnings.append(f"stale override {override['file']}: written for revision "
                                f"{override.get('revision')}, page is now {revisions.get(title)}")
                stats["stale overrides"] += 1

            built[title] = needs_from_override(override, resolver, problems)
        elif title in parsed:
            built[title] = build_needs(parsed[title], resolver, stats, problems, title)

    # --- 5. Common items (no icon) ----------------------------------------------------------
    common = {}

    for page, reason in inputs["common"]["items"].items():
        kind, ids, detail = resolver.resolve(*split_anchor(page))

        if kind not in ("item", "generic"):
            problems.append(f"common_items.json: {page} - {detail}")

        for number in ids:
            common[number] = page

    # --- 6. Noted IDs, only from a confirmed source -----------------------------------------
    noted = {int(plain): int(note) for plain, note in inputs["noted"].get("noted", {}).items()}
    noted_added = 0

    for needs in built.values():
        for need in needs:
            for number in list(need["items"]):
                note = noted.get(number)

                if note and note not in need["items"]:
                    need["items"].append(note)
                    noted_added += 1

                    if number in need["amounts"]:
                        need["amounts"][note] = need["amounts"][number]

    # --- 7. Match quests to the client, pick categories ------------------------------------
    with_items = sorted(title for title, needs in built.items() if needs)
    matches, unmatched = match_quests(with_items, inputs["client"], inputs["aliases"].get("aliases", {}))

    for title, reason in unmatched:
        problems.append(f"quest not matched to the client: {title} ({reason}); add it to "
                        "tools/data/aliases.json (aliases or skip)")

    out_quests = []

    for title in with_items:
        if title not in matches:
            continue

        client = matches[title]
        category = quest_category(categories.get(title, set()), client.get("type"), warnings, title)

        if category is None:
            problems.append(f"no category for {title}: {sorted(categories.get(title, set()))}")
            continue

        if category == "seasonal":
            skipped[title] = "holiday event quest (event items aren't tracked)"
            continue

        saga = "Fremennik Sagas" if "Fremennik Sagas quest series" in categories.get(title, set()) else None
        out_quests.append({"wiki": title, "id": client["id"], "config": client["config"],
                           "name": client["name"], "category": category, "saga": saga,
                           "revision": revisions.get(title), "needs": built[title]})

    # Two Wiki pages on one client quest would double its lines in the tooltip.
    counts = Counter(quest["id"] for quest in out_quests)

    for quest in out_quests:
        if counts[quest["id"]] > 1:
            problems.append(f"client quest {quest['id']} matched twice (incl. {quest['wiki']})")

    out_quests.sort(key=lambda quest: quest["id"])

    # --- 8. Cross-check against the client's ObjType.quests ---------------------------------
    cross_check = []

    if inputs["client_objects"]:
        given = {name: set(ids) for name, ids in inputs["client_objects"]["quests"].items()}

        for quest in out_quests:
            for need in quest["needs"]:
                for number in need["items"]:
                    if number in given.get(quest["name"], set()):
                        cross_check.append(f"{quest['name']}: item {number}")

    # --- 9. Report, then write only if nothing is unresolved --------------------------------
    usage = Counter(number for quest in out_quests for number in
                    {item for need in quest["needs"] for item in need["items"]})
    manual = {
        "overrides": len(inputs["overrides"]),
        "link_classes entries": len(inputs["links"]),
        "aliases and skips": len(inputs["aliases"].get("aliases", {})) + len(inputs["aliases"].get("skip", {})),
    }
    snapshot = datetime.date.today().isoformat()
    report = render_report(snapshot, titles, quests, skipped, out_quests, stats, problems, warnings,
                           manual, common, noted_added, cross_check, inputs, usage, resolver, wiki,
                           time.monotonic() - started, partial)

    target = (WORK / "sample_report.txt") if partial else REPORT
    target.parent.mkdir(parents=True, exist_ok=True)

    failed_report = WORK / "build_report_failed.txt"

    if problems and not partial:
        # Nothing is written to data/ while anything is unresolved; the report goes to work/.
        target = failed_report
    elif not partial and failed_report.exists():
        # An old failure report would only confuse the next reader.
        failed_report.unlink()

    target.write_text(report, encoding="utf-8", newline="\n")
    print(report.split("\n\n", 1)[0])
    print(f"report: {target.relative_to(ROOT)}")

    if args.suggest and problems:
        suggest_expansions(problems, resolver)

    # Whatever was built, for checking by eye. A partial run never replaces the real data file.
    write_json(WORK / ("sample_quests.json" if partial else "built_quests.json"), out_quests)

    if problems:
        print(f"FAILED: {len(problems)} problem(s), nothing written to data/", file=sys.stderr)
        return 1

    if partial:
        return 0

    coverage = {"matched": len(out_quests), "wikiQuests": len(quests)}
    write_lua(OUTPUT, snapshot, out_quests, common, coverage)
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(out_quests)} quests")
    return 0


def suggest_expansions(problems, resolver):
    """Helps write link_classes.json: lists the item pages each unresolved page links to.

    Only a suggestion. Someone still has to read the list, cut what doesn't fit ("any bow"
    pages link to every bow in the game) and write the entry by hand.
    """
    pages = sorted({match.group(1) for problem in problems
                    for match in [re.search(r"\[\[([^\]#]+)(?:#[^\]]*)?\]\]", problem)] if match})
    real = {page: resolver.info[page]["title"] for page in pages
            if page in resolver.info and resolver.info[page]["title"]}
    linked = page_links(resolver.wiki, set(real.values()))
    resolver.prepare({link for links in linked.values() for link in links})

    for page, title in sorted(real.items()):
        items = [link for link in linked.get(title, [])
                 if resolver.info.get(link, {}).get("title")
                 and resolver._ids_of(resolver.info[link]["title"])]
        print(f"\n{page} -> {title}: {len(items)} item pages")
        print("  " + json.dumps(items, ensure_ascii=False))


def render_report(snapshot, titles, quests, skipped, out_quests, stats, problems, warnings, manual,
                  common, noted_added, cross_check, inputs, usage, resolver, wiki, seconds, partial):
    lines = [
        f"Quest Item Marker build report - {snapshot}{' (PARTIAL RUN, not shipped)' if partial else ''}",
        f"Result: {'FAILED' if problems else 'OK'}",
        f"Wiki quests: {len(quests)} rows in bucket('quest'); {len(titles)} built this run",
        f"Quests written: {len(out_quests)}; skipped: {len(skipped)}",
        f"Requests: {wiki.sent} sent, {wiki.cached} from cache; {seconds:.0f} s",
        "",
        "Counts (requirement lines unless noted)",
        f"  automatic:                  {stats['lines automatic']}",
        f"  generic-expanded:           {stats['lines generic-expanded']}",
        f"  overridden:                 {stats['lines overridden']} lines in {stats['quests overridden']} quests",
        f"  non-item (no item links):   {stats['lines with no items (non-item)']}",
        f"  excluded (given/optional):  {stats['lines excluded (given by quest / optional)']}",
        f"  links ignored (not items):  {stats['links ignored (not items)']}",
        f"  links dropped (won't work): {stats['links dropped (\"will not work\")']}",
        f"  unknown #version, all used: {stats['links with an unknown #version (all versions used)']}",
        f"  unresolved:                 {len(problems)}",
        f"  stale overrides:            {stats['stale overrides']}",
        f"  manual fixes:               {sum(manual.values())} ("
        + ", ".join(f"{count} {name}" for name, count in manual.items()) + ")",
        f"  common items (unmarked):    {len(common)} ids from {len(inputs['common']['items'])} pages",
        f"  noted ids added:            {noted_added} (confirmed source: "
        f"{len(inputs['noted'].get('noted', {}))} pairs)",
        "  client ObjType cross-check: " + (f"{len(cross_check)} candidates" if inputs["client_objects"]
                                           else "not run (no tools/data/client_quest_objects.json yet)"),
    ]

    if problems:
        lines += ["", f"Problems ({len(problems)}) - each must be fixed before data/ is written"]
        lines += ["  " + problem for problem in problems]

    if warnings:
        lines += ["", "Warnings"] + ["  " + warning for warning in warnings]

    if cross_check:
        lines += ["", "Cross-check: required items the client ties to the same quest "
                      "(likely given by the quest; review, not removed)"]
        lines += ["  " + entry for entry in cross_check]

    lines += ["", "Items needed by the most quests (candidates for common_items.json)"]

    for number, count in usage.most_common(25):
        mark = " (common)" if number in common else ""
        lines.append(f"  {count:3} quests  item {number}{mark}")

    lines += ["", "Skipped quests"] + [f"  {title}: {reason}" for title, reason in sorted(skipped.items())]

    generic = sorted({f"{title} -> {', '.join(pages)}" for title, pages in resolver.disambiguation.items()})
    lines += ["", "Disambiguation pages expanded automatically"] + ["  " + entry for entry in generic]

    lines += ["", "Quests written (client id, category, needs)"]

    for quest in out_quests:
        lines.append(f"  {quest['id']:4} {quest['category']:9} {len(quest['needs']):2}  {quest['name']}"
                     + (f"  [wiki: {quest['wiki']}]" if quest["wiki"] != quest["name"] else ""))

    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    try:
        sys.exit(main())
    except WikiError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
