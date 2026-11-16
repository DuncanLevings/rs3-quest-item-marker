Quest Item Marker - offline data tools
======================================

These tools build data/quest_items.lua, the list of items each quest needs, from the
RuneScape Wiki. They run on the author's machine and are never shipped with the plugin.
The plugin itself makes no network requests.

Requirements: Python 3.11 or newer (standard library only).


Files
-----

  build_quest_items.py   the build: fetch, parse, resolve, match, check, write
  quest_parser.py        reads one quest's "Items required" text (no network; tested)
  wiki.py                polite cached Wiki client (forked from monster-data-core, see below)
  import_probe_log.py    reads the probe plugin's console log into tools/data (see below)
  tests/                 unit tests for the parser (test_quest_parser.py) and for quest
                         matching and categories (test_build.py)
  data/                  hand-reviewed inputs (all JSON, all checked in):
    client_quests.json     client quest ids, config names, names, deprecated flags
    aliases.json           Wiki title -> client quest, for names that don't match; "skip" list
    link_classes.json      decisions for links that aren't item pages (expand or ignore)
    common_items.json      items the plugin never marks (hammer, coins, runes...)
    noted_ids.json         unnoted -> noted item id pairs confirmed in the client
    overrides/*.json       per-quest replacements for the whole item list
    client_quest_objects.json (optional) the client's ObjType.quests dump, for the cross-check

Outputs:

  data/quest_items.lua     the generated data file (only written when the build passes)
  data/build_report.txt    counts and lists from the last passing build (not shipped)
  work/                    Wiki answer cache, failed-build reports, samples (gitignored)


Running it
----------

From the plugin folder:

  py -3 -I tools/build_quest_items.py --sample     the 10 sample quests; report in work/
  py -3 -I tools/build_quest_items.py              the full build
  py -3 -I tools/build_quest_items.py --offline    rebuild from the cache, no network
  py -3 -I tools/build_quest_items.py --refresh    ask the Wiki again (a new snapshot)
  py -3 -I tools/build_quest_items.py --suggest    also list item pages linked from each
                                                   unresolved page (to write link_classes)
  py -3 -I -m unittest discover -s tools/tests     unit tests

-I keeps anything in work/ from being imported as code.

--offline only finds answers that were cached by a run that asked for the same things in
the same batches. Changing tools/data (a new alias, a new link_classes entry) can change
the batches, and an offline run then stops at the first missing answer; run once without
--offline to fill the gaps.

The build is all-or-nothing. If any link can't be resolved, or any quest with items can't
be matched to a client quest, nothing is written to data/ and the report goes to
work/build_report_failed.txt with one line per problem. Fix each problem in tools/data/
and run again; with the cache in place a rerun sends almost no requests.


Being polite to the Wiki
------------------------

The Wiki's own rules: https://runescape.wiki/w/RuneScape:How_to_safely_use_wiki_data_in_RuneScape_plugins

- Every request carries the User-Agent
  "QuestItemMarker-build/0.1 (https://github.com/DuncanLevings/rs3-quest-item-marker; Discord: Tatsuya)".
- At most one request a second, with maxlag=5 and back-off on errors.
- Only the Bucket and MediaWiki query APIs are used; no HTML pages are fetched.
- Every answer is cached in work/wiki-cache/, keyed by the exact request. A full build
  is about 95 requests (plus a few hundred with --suggest); reruns use the cache. Use
  --refresh only when you mean to take a new snapshot.


How a quest's items are decided
-------------------------------

Source: bucket('quest'), field json.items: the quest page's "Items required" text, with
templates already expanded. Step 0 (2026-11-16) found these json keys across all 395 rows:
members, kills, name, start, length, items (291 rows), requirements (237),
league_region, league_region_req, league_region_auto. There is no separate "recommended"
key and no numeric quest id, so quests are matched to the client by name.

The rule leans towards marking: a missing icon is worse than an extra one.

1. Lines. Each bullet line is one requirement. Table markup and hatnotes are skipped.

2. Exclusions (the whole line is left out). Only when a clause *starts* with:
     "(can be / may be / will be) obtained|obtainable|acquired|gathered|collected|given ...
      during|in|as part of the (mini)quest"
     "given to you", "given by"
     "optional" or "recommended" on its own: "(optional, ...)"
   A "but" in the same clause cancels it ("obtained during quest but this is a rare drop").
   A line that starts by asking for backpack or inventory space ("At least 5 backpack
   spaces for the [[ransom letter]]", "8-12 backpack spaces") is not an item requirement.
   A plain-text header with the phrase anywhere in it ("Items obtainable during the
   quest:") leaves out the bullets under it, up to the next header. A bullet with no
   items of its own ("* Obtained during quest:") leaves out its sub-bullets.

3. Links. Every [[link]] on a required line is a candidate item, except:
     - links inside a clause that says they don't work: "will not work", "won't work",
       "do not work", "cannot be used", "not including", "excluding", "except",
       "neither ... nor", or a clause starting with "not";
     - [[File:]], [[Category:]] and other non-article namespaces;
     - skill requirement badges.
   "208 coins" and coin spans count as [[Coins]].

4. Groups. A line with several items and "or", "/", "either", "one of" is "any one of".
   Its alternatives can be several items together (added 2026-11-16): links joined by
   "and" / "+" stay together, "or" / "/" / "such as" / "e.g." starts a new alternative, and
   a comma means whatever the next "and" or "or" after it means (inside "(or ..." with no
   connector after it, "and"). "[[Irit potion (unfinished)]] (or [[clean irit]] and a
   [[vial of water]])" gives the need sets = { {potion}, {irit, vial} }. A combination
   holding a generic link ("any [[light source]]") is split back into single choices. If
   only one alternative is left once people and places drop out, the need is "all of
   these" (Swan Song: "[[Empty pot]] and [[pot lid]] (... a [[potter's wheel]] ...)").
   Sub-bullets join their parent's requirement as alternatives when the parent ends with
   "or", "either", "one of", "any set of", or says "one of the following", or when the
   sub-bullet starts with "Alternatively" / "Or". Other sub-bullets are requirements of
   their own.

5. Amounts. A number right before a link (after the previous link): "25 [[pure essence]]",
   "Five [[death rune]]s", "3 spools of [[bronze wire]]", "4-6 [[wolf bones]]" (kept as
   the text "4-6"), "1,000 or more [[coins]]", or "[[Redberries]] (1)". Amounts are per
   item, so "50 [[rune essence]] or 25 [[pure essence]]" keeps both.

6. Resolving a link to item IDs, in this order:
     a. tools/data/link_classes.json: "expand" to listed item pages, or "ignore" with a
        reason. A reviewed decision always wins.
     b. Redirects are followed first (MediaWiki query API).
     c. An item page in bucket('infobox_item'): every ID of every version. A
        [[Page#Version]] link keeps only that version_anchor; if no version matches, all
        versions are used and the report counts it. Only physical items you carry count:
        a page in Category:Glyphs or Category:Furniture (drawn or built, never held) is
        ignored even though it has an item infobox (NOT_CARRIED_CATEGORIES).
     d. A disambiguation page: every item page it links to ("generic-expanded").
     e. A page in a clearly non-item category (characters, locations, shops, spells,
        quests, skills, combat classes, rituals...; see NON_ITEM_CATEGORIES): ignored.
     f. Anything else is unresolved and fails the build.

7. Noted IDs. The Wiki has no noted-id field (infobox_item only has "noteable"), so noted
   ids come only from tools/data/noted_ids.json, filled from a client check. Until then the
   noted form of an item is not marked. Never add an unchecked +1 guess.

8. Quest matching. Live (non-deprecated) client quests from client_quests.json, by name,
   ignoring "(quest)" / "(... event)" suffixes and "&" vs "and", then "Series: Part" by
   its part name. Anything else goes in aliases.json. Pages in the Wiki's "Removed content"
   category are skipped (the original Prince Ali Rescue, Romeo & Juliet, Doric's Quest
   and Black Knights' Fortress are among them, even though the client still lists them);
   the report lists every skipped page.

9. Categories (closed list, a storage contract for the plugin's filter): tutorial if in
   Category:Tutorials; miniquest if in Category:Miniquests; otherwise quest.
   Holiday event quests are not tracked: a page in Category:Seasonal quests is skipped
   before it is parsed, and listed in the report. "<year> ... event" categories alone don't
   make a quest seasonal, because permanent quests that began as events (Swept Away, Violet
   is Blue) carry them too. Once client_quests.json has the client's QuestType.type
   (1 holiday, 2 tutorial), it decides seasonal (skipped) and tutorial, and disagreements
   with the Wiki are reported. "Fremennik Sagas" is a separate saga tag, not a category.

10. Overrides. tools/data/overrides/<name>.json replaces a quest's whole list:
      { "quest": "<Wiki title>", "revision": <revision id it was checked against>,
        "note": "why",
        "needs": [ { "items": ["Page", "Page#Version"], "amounts": {"Page": 5},
                     "anyOf": true } ] }
    When the page's revision changes, the build warns that the override is stale.

11. Common items. common_items.json lists pages whose items the plugin never marks (no
    icon, no tooltip). Each addition removes marks, so add deliberately. The report lists the items needed by the
    most quests as candidates.

12. Cross-check. If tools/data/client_quest_objects.json exists ({"quests": {"<client quest
    name>": [item ids]}}, from the client's ObjType.quests), the report lists required items
    the client ties to the same quest. Those are often items the quest gives you; review
    them by hand, nothing is removed automatically. An item the author confirms is given or
    sold by the quest goes in link_classes.json as "ignore" with the reason.


Client inputs from the probe plugin
-----------------------------------

Three inputs can only come from the game client: noted ids, the ObjType.quests cross-check
and each quest's type. The probe plugin (dev_plugins/quest-item-marker-probe) prints them:

1. Load the probe in the game and open its panel, section "D. Quests".
2. Press "Dump quest states" (QUEST lines, with the type column) and
   "M1: dump QOBJ + NOTED for the build". The second scans object ids 0-70000 and prints
   nothing until it ends; then it prints packed lines (QOBJS <quest> | id,id,... and
   NOTEDS id,id,...) and an "M1 SUMMARY" line with the totals.
3. Copy the console output to a text file. The console keeps only its newest lines, so
   copy right after the scan ends; the importer compares the lines it finds with the
   summary and refuses a log that lost any.
4. From the plugin folder:
     py -3 -I tools/import_probe_log.py <log file> --client "<client build, eg 951-1>"
   This updates client_quests.json (type), client_quest_objects.json and noted_ids.json.
   A section missing from the log leaves its file alone.
5. Rebuild and read the cross-check and category warnings in data/build_report.txt.

An id on a NOTEDS line means: the next object id has the same name and always stacks, and
this one doesn't. Spot-check a few in game before trusting the list.


Where the code came from
------------------------

wiki.py is forked from monster-data-core/tools/fetch_wiki_data.py at commit ba4bbd5
(2026-10-22): the request loop, literal(), scan(), category_members() and the revision
lookup. The cache and redirect handling follow skill-tips/tools/skilling_tools/wiki.py
(commit 733c756). Keeping every item ID and version_anchor per page, and reporting pages
with no item ID, follow skill-tips/tools/list_item_ids.py (commit 733c756). Both are the
author's own projects.
