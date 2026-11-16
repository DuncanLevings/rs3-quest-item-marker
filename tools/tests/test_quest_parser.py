"""Tests for tools/quest_parser.py, on real lines copied from the Wiki's bucket('quest').

Run from the plugin folder:  py -3 -I -m unittest discover -s tools/tests -t tools
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quest_parser import parse_items  # noqa: E402


def links(line):
    # (target, amount, negated) for every link on a parsed line
    return [(link.target, link.amount, link.negated) for link in line.links]


class AmountsAndChoices(unittest.TestCase):
    def test_choice_dependent_amounts_stay_per_item(self):
        # Priest in Peril: the amount depends on which essence you bring.
        line = parse_items("* 50 [[rune essence]] or 25 [[pure essence]] "
                           "(the essence ''must'' be un-noted)")[0]

        self.assertEqual(line.status, "required")
        self.assertTrue(line.any_of)
        self.assertEqual(links(line), [("rune essence", 50, False), ("pure essence", 25, False)])

    def test_word_numbers_ranges_and_filler_words(self):
        lines = parse_items("* Five [[death rune]]s\n* 4-6 [[wolf bones]]\n"
                            "* 3 spools of [[bronze wire]]\n* 1,000 or more [[coins]] to buy")

        self.assertEqual(links(lines[0]), [("death rune", 5, False)])
        self.assertEqual(links(lines[1]), [("wolf bones", "4-6", False)])
        self.assertEqual(links(lines[2]), [("bronze wire", 3, False)])
        self.assertEqual(links(lines[3]), [("coins", 1000, False)])

    def test_an_amount_belongs_to_the_link_right_after_it(self):
        line = parse_items("* 1 [[cosmic rune|cosmic]] and [[water rune]], or a tablet.")[0]

        self.assertEqual(links(line), [("cosmic rune", 1, False), ("water rune", None, False)])

    def test_coin_spans_and_bare_coins_become_coin_links(self):
        lines = parse_items('* <span class="nocoins  coins-pos">875 coins</span> to enter\n'
                            "* 208 coins to buy all the required liquor")

        self.assertEqual(links(lines[0]), [("Coins", 875, False)])
        self.assertEqual(links(lines[1]), [("Coins", 208, False)])

    def test_skill_badges_and_file_links_are_not_links(self):
        line = parse_items('** <span class="skillreq" data-skill="Thieving">15 '
                           "[[File:Thieving-icon.png|21x21px|link=Thieving|alt=Thieving]] "
                           "[[Thieving]]</span> to pickpocket from a [[H.A.M. Member]] or")[0]

        self.assertEqual([link.target for link in line.links], ["H.A.M. Member"])

    def test_version_fragment_is_kept(self):
        line = parse_items("* [[Watering can#(8)|Watering can (8)]] or [[magic watering can]]")[0]

        self.assertEqual((line.links[0].target, line.links[0].fragment), ("Watering can", "(8)"))


class Exclusions(unittest.TestCase):
    def test_given_by_the_quest_at_the_start_of_a_clause(self):
        lines = parse_items("* [[Empty pot]] (can be obtained during quest)\n"
                            "* [[Vial]] (given by [[Sanfew]] if none are in your backpack)\n"
                            "* [[Secateurs]] (tool belt will not work, can be obtained during the quest)")

        self.assertEqual([line.status for line in lines], ["excluded"] * 3)

    def test_the_phrase_in_mid_sentence_keeps_the_line(self):
        # "though a torch can be obtained" is too vague to drop the line.
        line = parse_items("* Any [[light sources|light source]] (recommended [[Seer's headband]], "
                           "though a torch can be obtained during quest)")[0]

        self.assertEqual(line.status, "required")

    def test_but_keeps_the_line(self):
        line = parse_items("* 2 or more [[clean tarromin]] (obtained during quest but this is a "
                           "rather uncommon drop)")[0]

        self.assertEqual(line.status, "required")

    def test_optional_only_at_the_start(self):
        lines = parse_items("* [[Pat of butter]] (optional, not needed if picking the locks)\n"
                            "* 3 [[cabbage seed]]s (6 recommended)")

        self.assertEqual(lines[0].status, "excluded")
        self.assertEqual(lines[1].status, "required")

    def test_backpack_space_lines_are_not_items(self):
        lines = parse_items("* At least 5 backpack spaces for the [[ransom letter]] and materials\n"
                            "* 8-12 backpack spaces\n"
                            "* Enough backpack space to hold all your armour\n"
                            "* [[Cabbage]]s can be found in [[Rellekka]]. To use fewer backpack "
                            "space, fill an [[empty sack]]")

        self.assertEqual([line.status for line in lines[:3]], ["excluded"] * 3)
        self.assertEqual(lines[3].status, "required")

    def test_a_header_excludes_the_lines_under_it(self):
        lines = parse_items("* [[Raw tuna]]\n''Items obtainable during the quest:''\n"
                            "* [[Raw shark]]\n** [[Rope]]")

        self.assertEqual([line.status for line in lines], ["required", "excluded", "excluded", "excluded"])

    def test_a_header_with_but_excludes_nothing(self):
        lines = parse_items("These items can also be obtained during the quest, but it's possible "
                            "you already have them:\n* [[New key]]")

        self.assertEqual(lines[1].status, "required")

    def test_an_excluded_bullet_covers_its_sub_bullets(self):
        lines = parse_items("* Obtained during quest:\n** [[Cabbage]]\n** 90 [[Zemomark]]s or\n"
                            "*** [[Black hood]]")

        self.assertEqual([line.status for line in lines], ["excluded"] * 4)


class NegationAndGroups(unittest.TestCase):
    def test_links_in_a_will_not_work_clause_are_dropped(self):
        line = parse_items("* 10 [[oak plank]]s ([[protean plank]]s and [[plank box]] will not work)")[0]

        self.assertEqual(links(line), [("oak plank", 10, False), ("protean plank", None, True),
                                       ("plank box", None, True)])

    def test_brackets_in_a_label_do_not_break_clauses(self):
        line = parse_items("* Any [[ring]] (some rings, like the [[opal ring]] and "
                           "[[Ring of Wealth (4)]], do not work. The [[gold ring]] works)")[0]

        self.assertEqual([link.negated for link in line.links], [False, True, True, False])

    def test_not_a_at_the_start_of_a_clause(self):
        line = parse_items("* An [[empty pot]] (not a [[plant pot]])")[0]

        self.assertEqual(links(line), [("empty pot", None, False), ("plant pot", None, True)])

    def test_sub_bullets_under_an_or_join_the_parent(self):
        lines = parse_items("* 12 [[rune bar]]s or\n** 6 rune bars\n** 3 [[rune sword]]s\n"
                            "* [[Steel bar]]")

        self.assertEqual([line.merge_into for line in lines], [None, 0, 0, None])

    def test_alternatively_children_join_the_parent(self):
        lines = parse_items("* [[Cake]] (a slice, or full)\n** Alternatively, [[chocolate cake]]")

        self.assertEqual(lines[1].merge_into, 0)

    def test_plain_sub_bullets_stay_separate(self):
        lines = parse_items("* For completing the quest solo:\n** [[Lockpick]]")

        self.assertIsNone(lines[1].merge_into)

    def test_table_markup_is_skipped(self):
        lines = parse_items('{| class="mw-collapsible"\n|-\n* 24 [[limestone brick]]s\n'
                            "|}[[Category:Pages with Ironman information]]")

        self.assertEqual([line.status for line in lines], ["markup", "markup", "required", "markup"])


class Combinations(unittest.TestCase):
    # Alternatives that are several items together ("X, or Y and Z").

    def groups(self, text):
        return parse_items(text)[0].groups

    def test_and_inside_an_or_parenthesis(self):
        # A Guild of Our Own: the potion, or the herb and the vial together.
        self.assertEqual(self.groups("* [[Irit potion (unfinished)]] (or [[clean irit]] and a "
                                     "[[vial of water]])"), [0, 1, 1])

    def test_comma_inside_an_or_parenthesis_joins(self):
        self.assertEqual(self.groups("* [[Chopped onion]] (or [[bowl]], [[onion]])"), [0, 1, 1])

    def test_commas_take_the_meaning_of_the_next_connector(self):
        # Dimension of Disaster: Curse of Arrav.
        self.assertEqual(self.groups("* [[Ring of life]] (or [[gold ore]], [[diamond]], 10 "
                                     "[[earth rune]]s, and 1 [[cosmic rune]])"), [0, 1, 1, 1, 1])
        # Wanted!
        self.assertEqual(self.groups("* Either 10,000 [[coins]], or an [[enchanted gem]], "
                                     "[[molten glass]], and a [[law rune]]"), [0, 1, 1, 1])

    def test_a_plain_list_of_choices_has_no_groups(self):
        self.assertIsNone(self.groups("* [[Cat]], [[hellcat]], [[wily cat]], or [[kitten]]"))
        self.assertIsNone(self.groups("* 50 [[rune essence]] or 25 [[pure essence]]"))

    def test_such_as_lists_examples_not_a_combination(self):
        # Shilo Village.
        self.assertIsNone(self.groups("* A [[Lit torch|torch]] (or any other [[Light sources|light "
                                      "source]], such as a [[Oil lantern|lantern]] can be used)"))

    def test_text_without_a_connector_separates(self):
        # Goblin Diplomacy: Aggie and Rana are people; they get groups of their own.
        self.assertEqual(self.groups("* [[Blue dye]] (or 2 [[Woad leaf|woad leaves]] and 5 "
                                     "[[coins]] to obtain from [[Aggie]] or [[Rana the dyer]])"),
                         [0, 1, 1, 2, 3])


if __name__ == "__main__":
    unittest.main()
