#!/usr/bin/env python3
"""Look up a Roblox executor function across the three naming authorities.

Sources, in the order they are trusted:

  1. sUNC   https://docs.sunc.io/api/{mini,jumbo}.json
            Actively maintained; documents ONLY what the sUNC test script actually
            exercises (~79 functions). Authority on "is this real and tested today"
            and on portable signatures. Absence is NOT proof a function is fake --
            sUNC has deliberately dropped functions that every executor still ships
            (setclipboard, queue_on_teleport).
  2. Madium https://getmadium.net/llm/index.json (484 functions)
            Broadest coverage and the best ALIAS source. Its per-function markdown
            is canonical for that executor. Some entries document Madium-specific
            extensions -- this script flags those, because using them breaks
            portability to other executors.
  3. UNC    github.com/unified-naming-convention/NamingStandard/tree/main/api
            Archived May 2024. Authority on historically documented aliases only.

Usage:
    exec-api.py <function>            look one up
    exec-api.py -s <term>             search names/aliases/summaries
    exec-api.py --refresh             re-download the indexes
    exec-api.py --offline <function>  never hit the network
    exec-api.py --json <function>     machine-readable
"""

import argparse
import json
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

SUNC_JUMBO = "https://docs.sunc.io/api/jumbo.json"
MADIUM_INDEX = "https://getmadium.net/llm/index.json"
MADIUM_ROOT = "https://getmadium.net"
UNC_API = (
    "https://raw.githubusercontent.com/unified-naming-convention/"
    "NamingStandard/main/api/{}.md"
)
UNC_FILES = [
    "Drawing", "WebSocket", "cache", "closures", "console", "crypt", "debug",
    "filesystem", "input", "instances", "metatable", "misc", "scripts",
]

# Executor namespaces that historically prefixed these APIs. Last-resort
# candidates only -- every one of these executors is dead or renamed.
LEGACY_NAMESPACES = ["syn", "protosmasher", "krnl", "fluxus"]


class Offline(Exception):
    pass


def fetch(url: str, offline: bool = False, refresh: bool = False) -> str:
    """GET with an on-disk cache. Madium 403s without a browser UA."""
    CACHE.mkdir(parents=True, exist_ok=True)
    key = re.sub(r"[^A-Za-z0-9._-]", "_", url)[-180:]
    path = CACHE / key
    if path.exists() and not refresh:
        if offline or (time.time() - path.stat().st_mtime) < TTL:
            return path.read_text(encoding="utf-8")
    if offline:
        raise Offline(f"not cached and --offline given: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode("utf-8", "replace")
    path.write_text(body, encoding="utf-8")
    return body


def load_sunc(offline, refresh):
    """Flatten sUNC's jumbo.json into {name: (library, signature, description)}."""
    try:
        data = json.loads(fetch(SUNC_JUMBO, offline, refresh))
    except (urllib.error.URLError, Offline, json.JSONDecodeError) as e:
        print(f"  ! sUNC unavailable: {e}", file=sys.stderr)
        return {}
    out = {}
    for lib, entries in data.items():
        for name, meta in entries.items():
            if name.startswith("_") or not isinstance(meta, dict):
                continue
            out[name] = (lib, meta.get("signature", ""), meta.get("description", ""))
    return out


def load_madium(offline, refresh):
    try:
        return json.loads(fetch(MADIUM_INDEX, offline, refresh))["functions"]
    except (urllib.error.URLError, Offline, json.JSONDecodeError, KeyError) as e:
        print(f"  ! Madium unavailable: {e}", file=sys.stderr)
        return []


def load_unc(offline, refresh):
    """Return {filename: text}. Archived, so a cached copy is as good as a fresh one."""
    out = {}
    for f in UNC_FILES:
        try:
            out[f] = fetch(UNC_API.format(f), offline, refresh)
        except (urllib.error.URLError, Offline):
            pass
    return out


def madium_match(madium, name):
    low = name.lower()
    for r in madium:
        if r["name"].lower() == low:
            return r, "canonical"
    for r in madium:
        if low in [a.lower() for a in r.get("aliases", [])]:
            return r, "alias"
    return None, None


def sunc_match(sunc, name):
    for k in sunc:
        if k.lower() == name.lower():
            return k
    return None


def arity(sig: str) -> int | None:
    """Count declared parameters in a signature, for divergence detection."""
    m = re.search(r"\(([^)]*)\)", sig or "")
    if not m:
        return None
    inner = m.group(1).strip()
    if not inner:
        return 0
    return len([p for p in inner.split(",") if p.strip()])


def report(name, sunc, madium, unc, as_json, offline, refresh):
    mrec, how = madium_match(madium, name)
    skey = sunc_match(sunc, name)
    # An alias hit tells us the real canonical spelling; re-check sUNC under it.
    if not skey and mrec:
        skey = sunc_match(sunc, mrec["name"])

    result = {"query": name, "sunc": None, "madium": None, "unc": [], "candidates": [],
              "warnings": []}

    if as_json is False:
        print(f"\n=== {name} ===\n")

    # --- sUNC -------------------------------------------------------------
    if skey:
        lib, sig, desc = sunc[skey]
        result["sunc"] = {"name": skey, "library": lib, "signature": sig,
                          "description": desc}
        if not as_json:
            print(f"sUNC     TESTED  [{lib}]")
            for line in (sig or "").strip().splitlines():
                print(f"         {line}")
            if desc:
                flat = re.sub(r"\s+", " ", desc)
                print(f"         {flat[:300]}")
    else:
        if not as_json:
            print("sUNC     not documented")
            print("         Absence is NOT proof it does not exist -- sUNC only lists")
            print("         what its test script exercises. Check Madium below.")

    # --- Madium -----------------------------------------------------------
    if mrec:
        result["madium"] = {"name": mrec["name"], "library": mrec["library"],
                            "aliases": mrec.get("aliases", []),
                            "url": MADIUM_ROOT + mrec["path"]}
        if not as_json:
            print(f"\nMadium   {mrec['name']}  [{mrec['library']}]"
                  + ("   (queried name is an ALIAS)" if how == "alias" else ""))
            al = mrec.get("aliases") or []
            print(f"         aliases: {', '.join(al) if al else '(none)'}")
            print(f"         {mrec['summary']}")
            print(f"         {MADIUM_ROOT + mrec['path']}")
        if how == "alias" and mrec["name"].lower() != name.lower():
            result["warnings"].append(
                f"Madium considers '{mrec['name']}' canonical, not '{name}'. "
                "Sources disagree on spelling -- keep BOTH candidates and order them "
                "to match what the project already uses. Do not churn existing code."
            )
    elif not as_json:
        print("\nMadium   no match")

    # --- portability: signature divergence --------------------------------
    if skey and mrec:
        try:
            page = fetch(MADIUM_ROOT + mrec["path"], offline, refresh)
            m = re.search(r"```luau\n(.+?)\n```", page, re.S)
            msig = m.group(1).strip() if m else ""
            sa, ma = arity(sunc[skey][1]), arity(msig)
            if sa is not None and ma is not None and ma > sa:
                result["warnings"].append(
                    f"Signature divergence: sUNC declares {sa} parameter(s), Madium {ma}. "
                    f"The extra parameters are a Madium EXTENSION and are not portable. "
                    f"Use the {sa}-argument form, or gate the longer one behind a "
                    f"capability check.  madium: {msig}"
                )
        except (urllib.error.URLError, Offline):
            pass

    # --- UNC archive ------------------------------------------------------
    hits = [f for f, txt in unc.items() if re.search(rf"\b{re.escape(name)}\b", txt)]
    result["unc"] = hits
    if not as_json:
        print(f"\nUNC      {'api/' + ', api/'.join(hits) + '.md' if hits else 'no match'}"
              + ("" if hits else "  (archived May 2024)"))

    # --- candidate line ---------------------------------------------------
    cands = []
    canonical = mrec["name"] if mrec else (skey or name)
    for c in [canonical, name] + (mrec.get("aliases", []) if mrec else []):
        if c and c not in cands:
            cands.append(c)
    dotted = [f"{ns}.{name}" for ns in LEGACY_NAMESPACES]
    result["candidates"] = cands

    if not as_json:
        print("\nCandidate order (canonical -> documented alias -> legacy namespace):")
        print("    " + " , ".join(f'"{c}"' for c in cands))
        print(f"  legacy dotted fallbacks exist only for a few APIs; add e.g."
              f' "{dotted[0]}" ONLY if you have evidence that executor mattered.')

        for w in result["warnings"]:
            print(f"\n  !! {w}")
        if not skey and not mrec:
            print("\n  !! Not found in ANY source. Do not guess a fallback name.")
            print("     Re-check the spelling, or search:  exec-api.py -s <term>")
        print()

    if as_json:
        print(json.dumps(result, indent=2))
    return result


def search(madium, sunc, term):
    t = term.lower()
    print(f"\n=== search: {term} ===\n")
    seen = set()
    for r in madium:
        hay = " ".join([r["name"], r.get("summary", ""),
                        " ".join(r.get("aliases", [])), " ".join(r.get("terms", []))])
        if t in hay.lower() and r["name"] not in seen:
            seen.add(r["name"])
            mark = "sUNC" if sunc_match(sunc, r["name"]) else "    "
            print(f"  [{mark}] {r['name']:30} [{r['library']:14}] {r.get('summary','')[:70]}")
    for k, (lib, _, desc) in sunc.items():
        if t in (k + " " + desc).lower() and k not in seen:
            seen.add(k)
            print(f"  [sUNC] {k:30} [{lib:14}] (sUNC only)")
    if not seen:
        print("  no matches")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("function", nargs="?", help="function name to look up")
    ap.add_argument("-s", "--search", metavar="TERM", help="search instead of exact lookup")
    ap.add_argument("--refresh", action="store_true", help="re-download indexes")
    ap.add_argument("--offline", action="store_true", help="cache only, never fetch")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args()

    if not a.function and not a.search and not a.refresh:
        ap.print_help()
        return 2

    sunc = load_sunc(a.offline, a.refresh)
    madium = load_madium(a.offline, a.refresh)

    if a.refresh and not (a.function or a.search):
        load_unc(a.offline, True)
        print(f"refreshed: sUNC {len(sunc)} fn, Madium {len(madium)} fn, UNC api/ files")
        return 0
    if a.search:
        search(madium, sunc, a.search)
        return 0

    unc = load_unc(a.offline, a.refresh)
    r = report(a.function, sunc, madium, unc, a.json, a.offline, a.refresh)
    return 0 if (r["sunc"] or r["madium"]) else 1


if __name__ == "__main__":
    sys.exit(main())
