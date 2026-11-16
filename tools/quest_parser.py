"""Turns one quest's "Items required" wikitext into requirement lines. No network, no item IDs.

What this file does: the Wiki's bucket('quest') rows carry each quest's "Items required" as
free wikitext in json.items (templates already expanded, so {{plink}} arrives as a plain
[[link]] next to a [[File:...]] icon). This module reads that text line by line and decides,
for every line, whether it lists required items, and which links on it are the items. It
owns nothing; build_quest_items.py turns the links into item IDs afterwards.

The rule leans towards marking: a missing icon is the dangerous mistake, an extra icon is
only noise. So a line is only dropped when it clearly says the quest gives you the item
(or that it's optional), and a link is only dropped when its own clause says it won't work.
Everything else stays required. See tools/README.txt for the full rule list.
"""
import html
import re
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------------------
# Phrases. These are the fixed lists the design talks about; change them deliberately, and
# rerun the build to see what moved.
# ---------------------------------------------------------------------------------------

# "The quest gives you this": only counts when the clause *starts* with it, eg
# "(can be obtained during the quest)". In the middle of a sentence ("though a torch can be
# obtained during quest") it's too unclear, so the line stays marked.
GIVEN_BY_QUEST = re.compile(
    r"^(?:it |these |they )?(?:(?:can|may|will|could) (?:also |easily |all )?(?:be )?)?"
    r"(?:is |are )?(?:obtain(?:ed|able)?|acquired?|gathered|collected|received|given|"
    r"retrieved|re-obtained|picked up|found)"
    r"(?: (?:for free|easily|again|back))?"
    r" (?:during|in|as part of|throughout) (?:the )?(?:mini)?quest\b"
    r"|^(?:(?:will be |is |are )?given (?:to you|by)\b)",
    re.IGNORECASE,
)

# The same idea for a header line with no items of its own, where the phrase can be anywhere.
HEADER_GIVEN = re.compile(
    r"\b(?:obtain(?:ed|able)|given|acquired)\b(?: (?:for free|easily))? "
    r"(?:during|in|as part of) (?:the )?(?:mini)?quest\b"
    r"|\beither given or not necessary\b",
    re.IGNORECASE,
)

# Optional or recommended items aren't marked (brief §3). Only when the word is the whole
# comma piece: "(optional, but highly recommended)" yes; "(6 recommended; ...)" and
# "(recommended [[Seer's headband]], ...)" no, those recommend something else.
OPTIONAL = re.compile(r"^(?:optional|recommended)$", re.IGNORECASE)

# A line that asks for free backpack space isn't an item requirement, even when it names
# what the space is for ("At least 5 backpack spaces for the [[ransom letter]]"). Only at the
# start of the line, so "To use fewer backpack space, ..." in a hint doesn't count.
BACKPACK_SPACE = re.compile(
    r"^(?:must have )?(?:at least |about |around )?"
    r"(?:[\d,]+(?:-\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|some|enough|a few|several)?"
    r"\s*(?:free |empty |spare )?(?:backpack|inventory) (?:space|slot)s?\b",
    re.IGNORECASE,
)

# A clause that says the items in it *don't* do the job: "([[protean plank]]s do not work)",
# "(not a [[plant pot]])", "excluding the [[training bow]]". Links in it are dropped.
NEGATED = re.compile(
    r"\b(?:will|do|does|did|would|can|could)(?:n't| not) (?:\w+ )?(?:work|be used|count)\b"
    r"|\bwon't (?:\w+ )?work\b|\bcannot be used\b|\bcan't be used\b|\bnot including\b"
    r"|\bexcluding\b|\bexcept\b|\bneither\b|^not\b|\bnot allowed\b|\bnot accepted\b",
    re.IGNORECASE,
)

# A parent line that introduces alternatives for the sub-bullets under it, eg
# "8 [[mithril bar]]s or", "Either one to defeat [[Chronozon]]:", "One of the following".
ALTERNATIVES_INTRO = re.compile(
    r"(?:\bor\b|\beither\b|\bone of\b|\bany set\b|\bany one\b|\balternatively\b|or a set of)"
    r"[\s:;,.]*$|\bone of the following\b|\beither one\b|\bany one of\b|\bany set of\b",
    re.IGNORECASE,
)

# A sub-bullet that is itself an alternative to its parent: "Alternatively, ...", "Or ...".
ALTERNATIVE_CHILD = re.compile(r"^(?:alternatively|or)\b", re.IGNORECASE)

# Words that turn a line with several item links into "any one of these".
ANY_OF_WORDS = re.compile(r"\bor\b|/|\beither\b|\bone of\b|\bany of\b|\balternatively\b",
                          re.IGNORECASE)

WORD_NUMBERS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

# Words allowed between a number and its link: "3 spools of [[thread]]", "6 normal [[plank]]s".
AMOUNT_FILLER = (r"(?:of|pieces?|suits?|buckets?|spools?|rolls?|coils?|bowls?|loaves|bunch|"
                 r"sets?|regular|normal|wooden|cooked|raw|cut|uncut|unlit|un-noted|unnoted|"
                 r"noted|full|empty|extra|core|more|or more)")
AMOUNT_BEFORE = re.compile(
    r"(?:^|[\s(])(?:up to |at least |about |around |over |roughly )?"
    r"(?P<amount>\d[\d,]*(?:\s*[-–]\s*\d[\d,]*)?\+?|"
    + "|".join(WORD_NUMBERS) +
    r")(?:\s+" + AMOUNT_FILLER + r"){0,3}\s*$",
    re.IGNORECASE,
)
AMOUNT_AFTER = re.compile(r"^[a-z]*\s*\((?P<amount>\d[\d,]*)\)")

# Wiki namespaces whose links are never items (images, categories, calculators...).
NON_ITEM_NAMESPACES = ("file:", "image:", "category:", "calculator:", "bucket:", "template:",
                       "module:", "runescape:", "user:", "help:", "update:", "transcript:")

LINK = re.compile(r"\[\[([^\[\]|]*)(?:\|([^\[\]]*))?\]\]")


@dataclass
class Link:
    """One [[link]] on a line, after the line was cleaned up."""
    target: str              # page name as written, without the #fragment
    fragment: str | None     # the #part, used as a version_anchor for item pages
    label: str               # what the reader sees
    amount: int | str | None = None   # 25, or "4-6" / "38+" when the Wiki gives a range
    negated: bool = False    # its clause says this one doesn't work


@dataclass
class Line:
    """One line of the Items required text, with what the parser decided about it."""
    number: int              # 1-based line number in the quest's text, for the report
    depth: int               # 0 = plain text / header, 1 = "*", 2 = "**" ...
    raw: str
    text: str = ""           # cleaned text, links replaced by their labels
    links: list[Link] = field(default_factory=list)
    status: str = "required"  # required | excluded | markup
    reason: str = ""         # why it was excluded, for the report
    any_of: bool = False     # several links, any one of them is enough
    # On an any_of line whose alternatives are combinations ("[[irit potion (unfinished)]]
    # (or [[clean irit]] and a [[vial of water]])"): the alternative each link belongs to,
    # one number per link, eg [0, 1, 1]. None when every alternative is a single link.
    groups: list[int] | None = None
    parent: int | None = None    # index of the line this sub-bullet belongs to
    merge_into: int | None = None    # index of the line whose need this line joins


# ---------------------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------------------

def clean_markup(text):
    """Strips the HTML and formatting the bucket leaves in, keeping links and words."""
    # Skill requirement badges ("15 [[File:Thieving-icon.png]] [[Thieving]]") aren't items,
    # and their number would look like an amount, so drop the whole badge.
    text = re.sub(r'<span class="skillreq".*?</span>', " ", text)

    # Coin amounts are rendered as <span class="nocoins">50 coins</span>; make them a link
    # so they count like any other "50 [[coins]]".
    text = re.sub(r'<span class="nocoins[^"]*">\s*([\d,]+)\s*coins?\s*</span>', r"\1 [[Coins]]", text)

    # Footnote markers and the "boostable" superscript are noise.
    text = re.sub(r"<sup\b.*?</sup>", "", text)

    # Any other tag: keep what's inside it.
    text = re.sub(r"<[^>]+>", "", text)

    # Images and categories are never items. File links can carry their own "link=Skill",
    # which would otherwise read as a link to that page.
    text = re.sub(r"\[\[(?:File|Image|Category):[^\[\]]*\]\]", "", text, flags=re.IGNORECASE)

    # Bold and italic quotes, entities (&nbsp; &#107;) and the † "easily obtained" marker.
    text = text.replace("'''", "").replace("''", "")
    text = html.unescape(text).replace("\xa0", " ").replace("†", "")

    # Plain "208 coins" with no link still means coins; lean towards marking.
    text = re.sub(r"(?<![\w\[|])(\d[\d,]*)\+? coins?\b(?![^\[]*\]\])", r"\1 [[Coins]]", text,
                  flags=re.IGNORECASE)

    return re.sub(r"\s+", " ", text).strip()


def split_link(target):
    # "Watering can#(8)" -> ("Watering can", "(8)"). A bare "#Section" stays as written,
    # because it points at a part of the quest page itself.
    target = target.strip().replace("_", " ")

    if target.startswith("#") or "#" not in target:
        return target, None

    page, fragment = target.split("#", 1)
    return page.strip(), fragment.strip() or None


def parse_amount(value):
    # "1,000" -> 1000, "five" -> 5, "4-6" / "15–30" / "38+" stay text so the tooltip can
    # show the range as the Wiki gives it.
    value = value.replace(",", "").replace("–", "-").replace(" ", "")

    if value.lower() in WORD_NUMBERS:
        return WORD_NUMBERS[value.lower()]

    if value.isdigit():
        return int(value)

    return value


# ---------------------------------------------------------------------------------------
# Alternatives that are combinations
# ---------------------------------------------------------------------------------------

# "such as" / "e.g." introduce examples, each one a choice of its own ("any other [[light
# source]], such as a [[lantern]]" in Shilo Village).
SEPARATOR_OR = re.compile(r"\bor\b|/|\beither\b|\balternatively\b|\binstead\b|\bsuch as\b"
                          r"|\be\.g\.|\bfor example\b|\blike\b", re.IGNORECASE)
SEPARATOR_AND = re.compile(r"\band\b|\+|&", re.IGNORECASE)
OPENS_ALTERNATIVE = re.compile(r"\(\s*or\b", re.IGNORECASE)


def separator_kind(text):
    """What the text between two links says: "or", "and", "comma" or None."""
    if SEPARATOR_OR.search(text):
        return "or"
    if SEPARATOR_AND.search(text):
        return "and"
    if "," in text:
        return "comma"
    return None


def group_links(text, positions):
    """Splits an any_of line's links into alternatives, each one or more links needed together.

    Links joined by "and" / "+" belong together; "or" / "/" starts a new alternative. A comma
    means whatever the next "and" or "or" after it means ("[[gold ore]], [[diamond]], and
    [[cosmic rune]]" vs "[[cat]], [[kitten]], or [[hellcat]]"). A comma with no connector
    after it joins when it sits inside a "(or ..." clause ("[[chopped onion]] (or [[bowl]],
    [[onion]])") and separates otherwise. Text with no connector at all ("5 [[coins]] to obtain
    from [[Aggie]]") separates, which is what the build did before for every link.

    Returns one group number per link, or None if no alternative has more than one link.
    """
    if len(positions) < 2:
        return None

    kinds = [separator_kind(text[positions[index][1]:positions[index + 1][0]])
             for index in range(len(positions) - 1)]

    for index, kind in enumerate(kinds):
        if kind != "comma":
            continue

        following = next((later for later in kinds[index + 1:] if later in ("or", "and")), None)

        if following is not None:
            kinds[index] = following
        elif OPENS_ALTERNATIVE.search(text[:positions[index][1]]):
            kinds[index] = "and"
        else:
            kinds[index] = "or"

    groups = [0]

    for kind in kinds:
        groups.append(groups[-1] if kind == "and" else groups[-1] + 1)

    if len(set(groups)) == len(groups):
        return None

    return groups


# ---------------------------------------------------------------------------------------
# Clauses
# ---------------------------------------------------------------------------------------

def clauses(text):
    """Splits a cleaned line into clauses: each (parenthesis), and each ; or sentence.

    Returns [(depth, start, end)] spans in `text`. Links are later checked against the
    innermost clause they sit in, so "(protean planks do not work)" only drops its own links.
    """
    spans, stack, start, depth = [], [], 0, 0

    for index, character in enumerate(text):
        if character == "(":
            spans.append((depth, start, index))
            stack.append(index)
            depth += 1
            start = index + 1
        elif character == ")" and stack:
            spans.append((depth, start, index))
            stack.pop()
            depth -= 1
            start = index + 1
        elif character == ";" or (character == "." and text[index + 1:index + 2] == " "):
            spans.append((depth, start, index))
            start = index + 1

    spans.append((depth, start, len(text)))
    return [span for span in spans if text[span[1]:span[2]].strip()]


def clause_starts(clause_text):
    # The pieces of a clause between commas, eg "tool belt will not work, can be obtained
    # during the quest" -> two pieces. Exclusion phrases are matched at the start of a piece.
    pieces = []

    for piece in clause_text.split(","):
        piece = piece.strip(" :.-*")
        # "A [[phoenix feather]] ... (obtained during quest)": the leading article isn't
        # part of the phrase.
        piece = re.sub(r"^(?:and|but|then)\s+", "", piece, flags=re.IGNORECASE)

        if piece:
            pieces.append(piece)

    return pieces


# ---------------------------------------------------------------------------------------
# One line
# ---------------------------------------------------------------------------------------

def read_line(number, raw):
    """Cleans one raw line and finds its links, amounts and exclusions."""
    stripped = raw.strip()
    line = Line(number=number, depth=0, raw=raw)

    # Table markup from the collapsible "Ironmen:" boxes, and hatnotes ("Main article: ..."),
    # carry no requirement of their own.
    if re.match(r"^(?:\{\||\|\}|\|-|\|\s*$)", stripped) or 'class="hatnote' in stripped:
        line.status = "markup"
        return line

    # "|}[[Category:...]]" and "| class=... | '''Ironmen:'''" are table cells around a header.
    stripped = re.sub(r"^\|\}?(?:[^|]*\|)?", "", stripped).strip() if stripped.startswith("|") else stripped

    # Bullets: "*", "**", "***". A ";term" line is a definition-list header.
    bullets = re.match(r"^([*#]+)\s*", stripped)

    if bullets:
        line.depth = len(bullets.group(1))
        stripped = stripped[bullets.end():]
    elif stripped.startswith(";"):
        stripped = stripped[1:]

    cleaned = clean_markup(stripped)

    # Swap each link for its label, remembering where each label landed.
    text_parts, positions, cursor = [], [], 0

    for match in LINK.finditer(cleaned):
        text_parts.append(cleaned[cursor:match.start()])
        target, label = match.group(1), match.group(2)
        page, fragment = split_link(target)
        label = (label or target).strip()
        offset = sum(len(part) for part in text_parts)
        positions.append((offset, offset + len(label)))
        line.links.append(Link(target=page, fragment=fragment, label=label))
        text_parts.append(label)
        cursor = match.end()

    text_parts.append(cleaned[cursor:])
    line.text = "".join(text_parts)

    if not line.text.strip():
        line.status = "markup"
        return line

    # Clauses are found on a copy where every label is blanked out, because a label like
    # "Ring of Wealth (4)" has brackets of its own that would throw the clause split off.
    masked = list(line.text)

    for start, end in positions:
        masked[start:end] = "x" * (end - start)

    spans = clauses("".join(masked))

    # Which clause each link sits in (innermost wins, because spans never overlap).
    def clause_of(position):
        for depth, start, end in spans:
            if start <= position[0] and position[1] <= end:
                return depth, start, end
        return 0, 0, len(line.text)

    # Amounts and negation, link by link.
    previous_end = 0

    for link, position in zip(line.links, positions):
        depth, start, end = clause_of(position)

        # The amount must sit right before the link, after the previous link, so
        # "1 [[cosmic rune]] and [[water rune]]" doesn't give the water rune a 1.
        before = line.text[max(start, previous_end):position[0]]
        previous_end = position[1]
        found = AMOUNT_BEFORE.search(before)

        if found:
            link.amount = parse_amount(found.group("amount"))
        else:
            after = AMOUNT_AFTER.match(line.text[position[1]:])

            if after:
                link.amount = parse_amount(after.group("amount"))

        if NEGATED.search(line.text[start:end]):
            link.negated = True

    if BACKPACK_SPACE.search(line.text.strip()):
        line.status, line.reason = "excluded", "backpack space, not an item: " + line.text.strip()

    # Exclusions: check the start of every comma piece of every clause.
    for depth, start, end in spans if line.status != "excluded" else ():
        clause_text = line.text[start:end]

        # "obtained during quest but this is a rather uncommon drop" is a hint, not a
        # promise, so a "but" anywhere in that clause keeps the line marked.
        if re.search(r"\bbut\b", clause_text, re.IGNORECASE):
            continue

        for piece in clause_starts(clause_text):
            if GIVEN_BY_QUEST.search(piece):
                line.status, line.reason = "excluded", "given by the quest: " + piece
                break

            if OPTIONAL.search(piece):
                line.status, line.reason = "excluded", "optional: " + piece
                break

        if line.status == "excluded":
            break

    # A plain-text header has no items of its own, so the phrase can sit anywhere in it:
    # "Items obtainable during the quest:", "All of these can be obtained for free during
    # the quest." A "but" still keeps it from counting ("...also be obtained during the
    # quest, but ... you will need to bring them").
    is_header = line.depth == 0 or not line.links

    if line.status == "required" and is_header and HEADER_GIVEN.search(line.text) \
            and not re.search(r"\bbut\b", line.text, re.IGNORECASE):
        line.status, line.reason = "excluded", "given by the quest (header): " + line.text

    # Several items on one line joined by "or" / "/" mean any one of them will do.
    live = [link for link in line.links if not link.negated]
    line.any_of = len(live) > 1 and bool(ANY_OF_WORDS.search(line.text))

    if line.any_of:
        line.groups = group_links(line.text, positions)

    return line


# ---------------------------------------------------------------------------------------
# A whole quest
# ---------------------------------------------------------------------------------------

def parse_items(text):
    """Parses a quest's json.items text into Line objects, with parents and groups set."""
    lines = []

    for number, raw in enumerate(text.split("\n"), 1):
        if raw.strip():
            lines.append(read_line(number, raw))

    # Sub-bullets: find each one's parent (the closest earlier line with a smaller depth).
    for index, line in enumerate(lines):
        if line.depth < 2 or line.status == "markup":
            continue

        for earlier in range(index - 1, -1, -1):
            if lines[earlier].status != "markup" and lines[earlier].depth < line.depth:
                line.parent = earlier
                break

    # A plain-text header like "Items obtainable during the quest:" covers the bullets after
    # it, up to the next header. Same for a bullet with no links of its own ("* Obtained
    # during quest:") and its sub-bullets. A header with "but" in it ("These items can also be
    # obtained during the quest, but ... you will need to bring them") covers nothing.
    header_excluded = False

    for index, line in enumerate(lines):
        if line.status == "markup":
            continue

        if line.depth == 0:
            header_excluded = line.status == "excluded" and not line.links
            continue

        if header_excluded and line.status != "excluded":
            line.status, line.reason = "excluded", "under an excluded header"
            continue

        parent = lines[line.parent] if line.parent is not None else None

        if parent is None or parent.status != "excluded" or line.status == "excluded":
            continue

        # Under an excluded bullet: "* Obtained during quest:" covers everything below it,
        # and so does an excluded "** 90 [[zemomark]]s or" for the alternatives under it.
        # Lines are in order, so a whole chain of sub-bullets inherits in one pass.
        if not parent.links or ALTERNATIVES_INTRO.search(parent.text) or parent.reason.startswith("under"):
            line.status, line.reason = "excluded", "under an excluded bullet"

    # Sub-bullets that are alternatives join their parent's requirement as "any one of".
    for line in lines:
        if line.parent is None or line.status != "required":
            continue

        parent = lines[line.parent]

        if parent.status != "required":
            continue

        if ALTERNATIVES_INTRO.search(parent.text) or ALTERNATIVE_CHILD.search(line.text):
            # Follow the chain up, so *** under ** under * all land in the top requirement.
            target = line.parent

            while lines[target].merge_into is not None:
                target = lines[target].merge_into

            line.merge_into = target

    return lines
