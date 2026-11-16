"""Tests for the pure parts of tools/build_quest_items.py: quest matching and categories.

Run from the plugin folder:  py -3 -I -m unittest discover -s tools/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from build_quest_items import Resolver, build_needs, dedupe, match_quests, quest_category  # noqa: E402
from quest_parser import parse_items  # noqa: E402

CLIENT = {"quests": [
    {"id": 55, "config": "RUNE_MYSTERIES", "name": "Rune Mysteries", "deprecated": False},
    {"id": 358, "config": "ARIANE1", "name": "Rune Mysteries", "deprecated": False},
    {"id": 6, "config": "COOK_QUEST", "name": "Cook's Assistant", "deprecated": True},
    {"id": 257, "config": "COOKS_ASSISTANT", "name": "Cook's Assistant", "deprecated": False},
    {"id": 17, "config": "ROMEO_AND_JULIET", "name": "Romeo and Juliet", "deprecated": False},
    {"id": 505, "config": "NECRO_BAND", "name": "Flesh and Bone", "deprecated": False},
    {"id": 99, "config": "LANIAKEA", "name": "Helping Laniakea", "deprecated": False},
]}


class Matching(unittest.TestCase):
    def test_deprecated_duplicates_are_ignored(self):
        matches, unmatched = match_quests(["Cook's Assistant"], CLIENT, {})

        self.assertEqual(matches["Cook's Assistant"]["id"], 257)
        self.assertEqual(unmatched, [])

    def test_suffixes_ampersands_and_subquest_prefixes(self):
        titles = ["Romeo & Juliet", "That Old Black Magic: Flesh and Bone"]
        matches, unmatched = match_quests(titles, CLIENT, {})

        self.assertEqual([matches[title]["id"] for title in titles], [17, 505])

    def test_duplicate_live_names_need_an_alias(self):
        matches, unmatched = match_quests(["Rune Mysteries"], CLIENT, {})

        self.assertEqual(unmatched, [("Rune Mysteries", "duplicate client name")])

        matches, unmatched = match_quests(["Rune Mysteries"], CLIENT, {"Rune Mysteries": 358})

        self.assertEqual(matches["Rune Mysteries"]["id"], 358)

    def test_name_alias(self):
        aliases = {"Helping Laniakea (miniquest)": "Helping Laniakea"}
        matches, unmatched = match_quests(["Helping Laniakea (miniquest)"], CLIENT, aliases)

        self.assertEqual(matches["Helping Laniakea (miniquest)"]["id"], 99)


class Categories(unittest.TestCase):
    def test_wiki_categories_without_a_client_type(self):
        warnings = []

        self.assertEqual(quest_category({"Quests", "Tutorials"}, None, warnings, "x"), "tutorial")
        self.assertEqual(quest_category({"Quests", "Seasonal quests"}, None, warnings, "x"), "seasonal")
        # permanent quests that began as events keep their year-event category
        self.assertEqual(quest_category({"Quests", "2008 Halloween event"}, None, warnings, "x"), "quest")
        self.assertEqual(quest_category({"Miniquests"}, None, warnings, "x"), "miniquest")
        self.assertEqual(quest_category({"Quests"}, None, warnings, "x"), "quest")
        self.assertEqual(warnings, [])

    def test_the_client_type_wins_and_conflicts_are_reported(self):
        warnings = []

        self.assertEqual(quest_category({"Quests", "Seasonal quests"}, 0, warnings, "x"), "quest")
        self.assertEqual(len(warnings), 1)
        self.assertEqual(quest_category({"Quests"}, 1, warnings, "x"), "seasonal")
        self.assertEqual(quest_category({"Miniquests"}, 0, [], "x"), "miniquest")


class PhysicalItemsOnly(unittest.TestCase):
    def test_glyphs_and_furniture_are_not_items_despite_an_infobox(self):
        resolver = Resolver(None, {})
        resolver.info = {page: {"title": page, "revid": 1, "fragment": None}
                         for page in ("Elemental I", "Clockmaker's bench 3", "Rope")}
        resolver.items = {"Elemental I": [{"version": "", "ids": [55638]}],
                          "Clockmaker's bench 3": [{"version": "", "ids": [62037]}],
                          "Rope": [{"version": "", "ids": [954]}]}
        resolver.categories = {"Elemental I": {"Items", "Glyphs"},
                               "Clockmaker's bench 3": {"Items", "Furniture"},
                               "Rope": {"Items"}}

        self.assertEqual(resolver.resolve("Elemental I")[0], "ignored")
        self.assertEqual(resolver.resolve("Clockmaker's bench 3")[0], "ignored")
        self.assertEqual(resolver.resolve("Rope")[:2], ("item", [954]))


class Dedupe(unittest.TestCase):
    def test_identical_needs_collapse(self):
        need = {"items": [1, 2], "amounts": {1: 3}, "anyOf": True}

        self.assertEqual(dedupe([need, dict(need)]), [need])

    def test_different_sets_stay_apart(self):
        flat = {"items": [1, 2, 3], "amounts": {}, "anyOf": True}
        grouped = dict(flat, sets=[[1], [2, 3]])

        self.assertEqual(dedupe([flat, grouped]), [flat, grouped])


class FakeResolver:
    # Every link is an item whose id is listed here; anything else is a person or place.
    def __init__(self, ids):
        self.ids = ids

    def resolve(self, target, fragment=None):
        if target.lower() in self.ids:
            return "item", self.ids[target.lower()], ""
        return "ignored", [], ""


class Combinations(unittest.TestCase):
    def needs(self, text, ids):
        from collections import Counter

        return build_needs(parse_items(text), FakeResolver(ids), Counter(), [], "Test")

    def test_an_alternative_of_two_items_becomes_a_set(self):
        needs = self.needs("* [[Irit potion (unfinished)]] (or [[clean irit]] and a [[vial of water]])",
                           {"irit potion (unfinished)": [101, 102], "clean irit": [259, 260],
                            "vial of water": [227, 228]})

        self.assertEqual(needs, [{"items": [101, 102, 259, 260, 227, 228], "amounts": {},
                                  "anyOf": True, "sets": [[101, 102], [259, 260, 227, 228]]}])

    def test_a_generic_link_is_never_part_of_a_combination(self):
        class Generic(FakeResolver):
            def resolve(self, target, fragment=None):
                if target.lower() == "light source":
                    return "generic", [32, 33], ""
                return super().resolve(target, fragment)

        from collections import Counter

        needs = build_needs(parse_items("* [[Lit torch]] (or [[light source]] and [[lantern]])"),
                            Generic({"lit torch": [594], "lantern": [4524]}), Counter(), [], "Test")

        self.assertNotIn("sets", needs[0])
        self.assertTrue(needs[0]["anyOf"])

    def test_plain_choices_keep_the_old_shape(self):
        needs = self.needs("* [[Lockpick]] (or [[hair clip]])", {"lockpick": [1523], "hair clip": [11682]})

        self.assertEqual(needs, [{"items": [1523, 11682], "amounts": {}, "anyOf": True}])

    def test_people_drop_out_and_one_combination_left_means_all_of_it(self):
        # Swan Song: the potter's wheel isn't an item, so pot and lid are both needed.
        needs = self.needs("* [[Empty pot]] and [[pot lid]] (there's a [[potter's wheel]] in Draynor "
                           "if you need it, or the [[Barbarian Village]] has everything)",
                           {"empty pot": [1931], "pot lid": [4440]})

        self.assertEqual(needs, [{"items": [1931, 4440], "amounts": {}, "anyOf": False}])
