#!/usr/bin/env python3
"""Query the official Roblox platform documentation as machine-readable Markdown.

Roblox publishes an llms.txt retrieval surface, same idea as sUNC's and Madium's.
Use it instead of recalling platform behaviour from memory.

  concepts    https://create.roblox.com/docs/llms.txt
              ~3150-line index of the conceptual docs; every entry resolves to a
              /docs/en-us/<path>.md Markdown page.
  engine      https://create.roblox.com/docs/reference/engine/llms.txt
              Engine class/property/event reference -> classes/<Name>.md.
              This is the authority for property names such as
              ProximityPrompt.MaxActivationDistance.
  deprecated  https://create.roblox.com/docs/reference/engine/deprecated.md
              Answers "is wait/spawn/delay deprecated" from the source.

ROUTING (the Roblox docs warn about this themselves): the Engine API and the Open
Cloud API are separate systems. Engine APIs are Luau objects reached through
game:GetService() inside a running experience. Open Cloud APIs are HTTP endpoints
called with an x-api-key from outside Roblox. A script hub always wants the Engine
API. Using the wrong one produces code that cannot work.

llms-full.txt (23 MB) is deliberately never fetched.

Usage:
    rbx-docs.py -s streaming            search both indexes
    rbx-docs.py --class ProximityPrompt  engine class reference
    rbx-docs.py --deprecated wait        deprecation status
    rbx-docs.py --page /docs/en-us/scripting/scheduler.md
    rbx-docs.py --class Humanoid --grep WalkSpeed
"""

import argparse
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CACHE = Path.home() / ".cache" / "luau-script-hub"
TTL = 7 * 24 * 3600
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0 Safari/537.36"
)
ROOT = "https://create.roblox.com"
IDX_CONCEPTS = f"{ROOT}/docs/llms.txt"
IDX_ENGINE = f"{ROOT}/docs/reference/engine/llms.txt"
DEPRECATED = f"{ROOT}/docs/reference/engine/deprecated.md"

# Refuse this no matter how it is spelled -- 23 MB would blow up the context.
FORBIDDEN = "llms-full"

ENTRY = re.compile(r"^\s*-\s*\[([^\]]+)\]\(([^)]+)\)\s*:?\s*(.*)$")


class Offline(Exception):
    pass


def fetch(url: str, offline=False, refresh=False) -> str:
    if FORBIDDEN in url:
        sys.exit(f"refusing to fetch {url} -- it is ~23 MB. Use -s / --page instead.")
    CACHE.mkdir(parents=True, exist_ok=True)
    key = re.sub(r"[^A-Za-z0-9._-]", "_", url)[-180:]
    path = CACHE / key
    if path.exists() and not refresh:
        if offline or (time.time() - path.stat().st_mtime) < TTL:
            return path.read_text(encoding="utf-8")
    if offline:
        raise Offline(f"not cached and --offline given: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=45) as r:
        body = r.read().decode("utf-8", "replace")
    path.write_text(body, encoding="utf-8")
    return body


def parse_index(text: str):
    out = []
    for line in text.splitlines():
        m = ENTRY.match(line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3).strip()))
    return out


def abs_url(path: str) -> str:
    if path.startswith("http"):
        return path
    if not path.endswith(".md"):
        path = path.rstrip("/") + ".md"
    return ROOT + path


def show_page(path, offline, refresh, grep=None, full=False):
    url = abs_url(path)
    try:
        text = fetch(url, offline, refresh)
    except (urllib.error.URLError, Offline) as e:
        sys.exit(f"could not fetch {url}: {e}")
    print(f"# source: {url}\n")
    lines = text.splitlines()
    if grep:
        pat = re.compile(grep, re.I)
        hits = [(i + 1, l) for i, l in enumerate(lines) if pat.search(l)]
        if not hits:
            print(f"(no line matches /{grep}/ in {len(lines)} lines)")
            return
        for n, l in hits:
            print(f"{n:5}  {l}")
        return
    if full or len(lines) <= 400:
        print(text)
        return
    print("\n".join(lines[:250]))
    print(f"\n... [{len(lines) - 250} more lines] "
          f"-- rerun with --full, or narrow with --grep PATTERN")


def search(term, offline, refresh):
    pat = re.compile(re.escape(term), re.I)
    total = 0
    for label, idx in (("concepts", IDX_CONCEPTS), ("engine", IDX_ENGINE)):
        try:
            entries = parse_index(fetch(idx, offline, refresh))
        except (urllib.error.URLError, Offline) as e:
            print(f"  ! {label} index unavailable: {e}", file=sys.stderr)
            continue
        hits = [e for e in entries if pat.search(e[0]) or pat.search(e[2])]
        if not hits:
            continue
        print(f"\n=== {label} ({len(hits)}) ===")
        for title, path, summary in hits[:40]:
            print(f"  {title}")
            print(f"      {path}")
            if summary:
                print(f"      {summary[:110]}")
        if len(hits) > 40:
            print(f"  ... {len(hits) - 40} more")
        total += len(hits)
    if not total:
        print(f"no matches for {term!r} in either index")
    else:
        print("\nFetch one with:  rbx-docs.py --page <path>")


def engine_class(name, offline, refresh, grep, full):
    try:
        entries = parse_index(fetch(IDX_ENGINE, offline, refresh))
    except (urllib.error.URLError, Offline) as e:
        sys.exit(f"engine index unavailable: {e}")
    exact = [e for e in entries if e[0].lower() == name.lower()]
    if not exact:
        near = [e for e in entries if name.lower() in e[0].lower()][:15]
        print(f"no engine class named {name!r}.")
        if near:
            print("did you mean:")
            for t, p, _ in near:
                print(f"  {t}   {p}")
        sys.exit(1)
    show_page(exact[0][1], offline, refresh, grep, full)


def deprecated(name, offline, refresh):
    try:
        text = fetch(DEPRECATED, offline, refresh)
    except (urllib.error.URLError, Offline) as e:
        sys.exit(f"deprecated inventory unavailable: {e}")
    print(f"# source: {DEPRECATED}\n")
    pat = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])", re.I)
    hits = [(i + 1, l) for i, l in enumerate(text.splitlines()) if pat.search(l)]
    if not hits:
        print(f"{name!r} does not appear in the deprecated inventory.")
        print("That is evidence it is NOT deprecated, not proof -- the inventory")
        print("lists Engine API members; language-level globals may not appear.")
        return
    print(f"{name!r} appears {len(hits)} time(s):\n")
    for n, l in hits[:30]:
        print(f"{n:5}  {l.strip()}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--search", metavar="TERM")
    ap.add_argument("--page", metavar="PATH")
    ap.add_argument("--class", dest="klass", metavar="NAME")
    ap.add_argument("--deprecated", metavar="NAME")
    ap.add_argument("--grep", metavar="PATTERN", help="filter page output")
    ap.add_argument("--full", action="store_true", help="print long pages whole")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--offline", action="store_true")
    a = ap.parse_args()

    if a.search:
        search(a.search, a.offline, a.refresh)
    elif a.klass:
        engine_class(a.klass, a.offline, a.refresh, a.grep, a.full)
    elif a.deprecated:
        deprecated(a.deprecated, a.offline, a.refresh)
    elif a.page:
        show_page(a.page, a.offline, a.refresh, a.grep, a.full)
    else:
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
