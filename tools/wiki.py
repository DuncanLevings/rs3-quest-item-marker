"""A small, polite, cached client for the RuneScape Wiki API.

What this file does: sends the Bucket and MediaWiki API requests the build needs, and keeps
every answer on disk in work/wiki-cache/ so a rerun asks the Wiki nothing it already asked.
It owns nothing else: no parsing, no item logic.

Forked from monster-data-core/tools/fetch_wiki_data.py at commit ba4bbd5 (2026-10-22):
the Wiki class (1 request a second, maxlag, retries), literal(), scan(), category_members()
and latest_revisions(). The on-disk cache and the redirect lookup follow
skill-tips/tools/skilling_tools/wiki.py (commit 733c756). The Wiki asks plugin authors for
exactly this kind of one-off, cached, identified scrape:
https://runescape.wiki/w/RuneScape:How_to_safely_use_wiki_data_in_RuneScape_plugins
"""
import hashlib
import http.client
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://runescape.wiki/api.php"

# The Wiki wants a real way to reach whoever runs the scrape. Contact given by the author.
USER_AGENT = ("QuestItemMarker-build/0.1 "
              "(https://github.com/DuncanLevings/rs3-quest-item-marker; Discord: Tatsuya)")

BUCKET_PAGE = 5000      # the most rows one bucket request returns
TITLES_PER_QUERY = 50   # MediaWiki takes up to 50 titles per query for normal users
ITEMS_PER_QUERY = 40    # bucket.Or conditions per infobox_item request (as in monster-data-core)


class WikiError(Exception):
    """Something the Wiki sent back that we can't use. Printed without a traceback."""


def literal(value):
    # Bucket queries are Lua source, so a page name has to be quoted as a Lua string.
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def write_json(path, value):
    # Write to a temp file first, so a crash never leaves half a JSON file behind.
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    temporary.replace(path)


class Wiki:
    """Sends API requests one per second at most, and caches every answer on disk.

    offline=True only reads the cache and fails on anything missing; refresh=True ignores the
    cache and asks again (the new answer replaces the old one).
    """

    def __init__(self, cache, offline=False, refresh=False, delay=1.0):
        if offline and refresh:
            raise WikiError("--offline and --refresh can't be combined")

        self.cache = Path(cache)
        self.offline = offline
        self.refresh = refresh
        self.delay = max(delay, 1.0)
        self.last = 0.0
        self.sent = 0       # real network requests this run
        self.cached = 0     # answers served from disk

    def get(self, params):
        params = dict(params, format="json", formatversion=2, maxlag=5)

        # The cache key is the exact request, so a changed query never reuses an old answer.
        key = hashlib.sha256(json.dumps(params, sort_keys=True).encode("utf-8")).hexdigest()
        path = self.cache / (key[:2] + "/" + key + ".json")

        if path.exists() and not self.refresh:
            saved = json.loads(path.read_text(encoding="utf-8"))

            if saved.get("params") != params:
                raise WikiError(f"cache file {path} doesn't match its request; delete it")

            self.cached += 1
            return saved["response"]

        if self.offline:
            raise WikiError(f"not in the cache (run without --offline): {params}")

        data = self._fetch(params)
        write_json(path, {"params": params, "fetched": int(time.time()), "response": data})
        return data

    def _fetch(self, params):
        url = API + "?" + urllib.parse.urlencode(params)

        for attempt in range(6):
            # Keep at least `delay` seconds between requests, whatever happened last time.
            wait = self.last + self.delay - time.monotonic()

            if wait > 0:
                time.sleep(wait)

            self.last = time.monotonic()
            self.sent += 1
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                # Rate limited or a server hiccup: back off and try again.
                if error.code in (429, 500, 502, 503, 504):
                    time.sleep(int(error.headers.get("Retry-After") or 5 * (attempt + 1)))
                    continue

                raise WikiError(f"HTTP {error.code} for {url}") from error
            except (urllib.error.URLError, TimeoutError, ConnectionError,
                    http.client.HTTPException, json.JSONDecodeError):
                # Dropped connections and cut-off bodies are worth another go.
                time.sleep(5 * (attempt + 1))
                continue

            # The Wiki asks bots to wait while its database replicas are lagging.
            if data.get("error", {}).get("code") == "maxlag":
                time.sleep(5 * (attempt + 1))
                continue

            if "error" in data:
                raise WikiError(f"API error {data['error']} for {params}")

            return data

        raise WikiError(f"giving up on {url}")

    def bucket(self, query):
        rows = self.get({"action": "bucket", "query": query}).get("bucket")

        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise WikiError(f"unexpected bucket answer for {query}")

        return rows


def scan(wiki, bucket, fields, label):
    # Reads a whole bucket, a page of rows at a time. Only the named fields are asked for.
    rows, offset = [], 0
    select = ",".join(literal(field) for field in fields)

    while True:
        page = wiki.bucket(f"bucket({literal(bucket)}).select({select}).limit({BUCKET_PAGE})"
                           f".offset({offset}).run()")
        rows.extend(page)
        print(f"  {label}: {len(rows)} rows", flush=True)

        if len(page) < BUCKET_PAGE:
            return rows

        offset += BUCKET_PAGE


def category_members(wiki, category, kind="page"):
    # Every page (or subcategory, with kind="subcat") in one Wiki category.
    titles, cursor = [], None

    while True:
        params = {"action": "query", "list": "categorymembers", "cmtitle": category,
                  "cmtype": kind, "cmlimit": 500}

        if cursor:
            params["cmcontinue"] = cursor

        data = wiki.get(params)
        titles.extend(member["title"] for member in data["query"]["categorymembers"])
        cursor = data.get("continue", {}).get("cmcontinue")

        if not cursor:
            return titles


def page_info(wiki, titles):
    """Follows redirects and reads each page's latest revision, 50 titles a request.

    Returns {asked title: {"title": real title or None if missing, "revid": int or None}}.
    The bucket only knows real page names, so links must go through this first.
    """
    result = {}
    titles = sorted(set(titles))

    for start in range(0, len(titles), TITLES_PER_QUERY):
        batch = titles[start:start + TITLES_PER_QUERY]
        data = wiki.get({"action": "query", "prop": "info", "redirects": 1,
                         "titles": "|".join(batch)})
        query = data.get("query", {})

        # MediaWiki tidies titles ("rune essence" -> "Rune essence") and then follows
        # redirects; both maps are needed to get from what we asked to where it landed.
        normal = {entry["from"]: entry["to"] for entry in query.get("normalized", [])}
        redirect = {entry["from"]: entry for entry in query.get("redirects", [])}
        pages = {page["title"]: page for page in query.get("pages", [])}

        for asked in batch:
            title = normal.get(asked, asked)
            fragment = None

            if title in redirect:
                fragment = redirect[title].get("tofragment")
                title = redirect[title]["to"]

            page = pages.get(title, {})
            missing = page.get("missing") or page.get("invalid") or not page

            result[asked] = {
                "title": None if missing else title,
                "revid": page.get("lastrevid"),
                # a redirect can point at a section, eg "Bronze bar#..." - kept for reporting
                "fragment": fragment,
            }

    return result
