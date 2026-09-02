#!/usr/bin/env python3
"""Render Roblox image assets to a labeled contact sheet so you can LOOK at them.

Why this exists: Lucide-style UI icons are white on transparent. A raw thumbnail
renders white-on-white and looks blank, so "the name sounds right" is the only
thing people check -- and they ship the wrong glyph. This composites every asset
onto a dark background and labels it, which turns "never guess an asset ID" from
a rule into a step you actually perform.

After running this, OPEN THE PNG AND LOOK AT IT. Producing the file is not the
verification; seeing the glyph is.

Inputs may be:
  * bare asset ids          7733960981
  * rbxassetid:// URIs      rbxassetid://7733960981
  * Lucide names            home  settings  refresh-cw
    (resolved against frappedevs/lucideblox, branch `master`, where the JSON is
     nested under an "icons" key -- 565 individually-uploaded assets)

Usage:
    icon-sheet.py home settings crown
    icon-sheet.py 7733960981 rbxassetid://7734053495
    icon-sheet.py --list arrow          search available Lucide names
    icon-sheet.py --out /tmp/sheet.png home bug
"""

import argparse
import io
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CACHE = Path.home() / ".cache" / "luau-script-hub"
TTL = 30 * 24 * 3600
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

# Archived 2022, branch is `master` (not `main`), and the map is nested under
# an "icons" key -- both are easy to get wrong.
LUCIDEBLOX = ("https://raw.githubusercontent.com/frappedevs/lucideblox/"
              "master/src/modules/util/icons.json")
THUMBS = "https://thumbnails.roblox.com/v1/assets?assetIds={}&size=150x150&format=Png"

BG = (24, 24, 27)
FG = (228, 228, 231)
MUTED = (140, 140, 150)
CELL, PAD, LABEL_H, COLS = 150, 14, 30, 5


def get(url: str, binary=False, cache=True):
    key = re.sub(r"[^A-Za-z0-9._-]", "_", url)[-180:]
    path = CACHE / key
    if cache and path.exists() and (time.time() - path.stat().st_mtime) < TTL:
        return path.read_bytes() if binary else path.read_text("utf-8")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=45) as r:
        data = r.read()
    if cache:
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return data if binary else data.decode("utf-8", "replace")


def lucide_map():
    try:
        raw = json.loads(get(LUCIDEBLOX))
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"  ! lucideblox unavailable: {e}", file=sys.stderr)
        return {}
    # Nested under "icons"; tolerate a flat map in case that ever changes.
    return raw.get("icons", raw) if isinstance(raw, dict) else {}


def resolve(tokens, names):
    """-> [(label, asset_id)], plus a list of unresolved tokens."""
    out, bad = [], []
    for t in tokens:
        m = re.fullmatch(r"(?:rbxassetid://)?(\d{6,})", t.strip())
        if m:
            out.append((t.strip(), m.group(1)))
            continue
        key = t.strip().lower()
        if key in names:
            out.append((key, re.sub(r"\D", "", names[key])))
        else:
            bad.append(t)
    return out, bad


def thumb_urls(ids):
    """Batch the thumbnails API; it accepts comma-separated ids."""
    found = {}
    for i in range(0, len(ids), 50):
        chunk = ids[i:i + 50]
        try:
            data = json.loads(get(THUMBS.format(",".join(chunk)), cache=False))
        except (urllib.error.URLError, json.JSONDecodeError) as e:
            print(f"  ! thumbnails API failed: {e}", file=sys.stderr)
            continue
        for row in data.get("data", []):
            if row.get("state") == "Completed" and row.get("imageUrl"):
                found[str(row["targetId"])] = row["imageUrl"]
            else:
                print(f"  ! asset {row.get('targetId')}: state="
                      f"{row.get('state')} -- no image", file=sys.stderr)
    return found


def build_pillow(items, urls, out):
    from PIL import Image, ImageDraw, ImageFont
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/TTF/DejaVuSans.ttf", 13)
    except OSError:
        try:
            font = ImageFont.truetype("DejaVuSans.ttf", 13)
        except OSError:
            font = ImageFont.load_default()

    n = len(items)
    cols = min(COLS, max(1, n))
    rows = (n + cols - 1) // cols
    W = cols * (CELL + PAD) + PAD
    H = rows * (CELL + LABEL_H + PAD) + PAD
    sheet = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(sheet)

    for idx, (label, aid) in enumerate(items):
        cx = PAD + (idx % cols) * (CELL + PAD)
        cy = PAD + (idx // cols) * (CELL + LABEL_H + PAD)
        url = urls.get(aid)
        if url:
            try:
                icon = Image.open(io.BytesIO(get(url, binary=True))).convert("RGBA")
                icon = icon.resize((CELL, CELL), Image.LANCZOS)
                # The whole point: composite over dark, or white-on-transparent
                # renders invisible.
                cellimg = Image.new("RGBA", (CELL, CELL), BG + (255,))
                cellimg.alpha_composite(icon)
                sheet.paste(cellimg.convert("RGB"), (cx, cy))
            except (urllib.error.URLError, OSError) as e:
                draw.rectangle([cx, cy, cx + CELL, cy + CELL], outline=(120, 60, 60))
                draw.text((cx + 8, cy + CELL // 2), f"load failed", fill=(200, 90, 90),
                          font=font)
                print(f"  ! {label}: {e}", file=sys.stderr)
        else:
            draw.rectangle([cx, cy, cx + CELL, cy + CELL], outline=(120, 60, 60))
            draw.text((cx + 8, cy + CELL // 2), "no thumbnail", fill=(200, 90, 90),
                      font=font)
        draw.text((cx + 2, cy + CELL + 4), label[:22], fill=FG, font=font)
        draw.text((cx + 2, cy + CELL + 17), aid, fill=MUTED, font=font)

    sheet.save(out)
    return out


def build_magick(items, urls, out):
    """ImageMagick fallback: flatten each onto dark, label, montage."""
    import shutil
    import subprocess
    import tempfile
    magick = shutil.which("magick") or shutil.which("convert")
    if not magick:
        return None
    base = [magick] if magick.endswith("magick") else [magick]
    tmp = Path(tempfile.mkdtemp(prefix="iconsheet."))
    tiles = []
    hexbg = "#%02x%02x%02x" % BG
    for label, aid in items:
        url = urls.get(aid)
        if not url:
            continue
        src = tmp / f"{aid}.png"
        src.write_bytes(get(url, binary=True))
        tile = tmp / f"t_{aid}.png"
        subprocess.run(base + [str(src), "-background", hexbg, "-flatten",
                               "-resize", f"{CELL}x{CELL}",
                               "-gravity", "south", "-splice", "0x22",
                               "-pointsize", "13", "-fill", "#e4e4e7",
                               "-annotate", "+0+4", f"{label}\n{aid}", str(tile)],
                       check=False, capture_output=True)
        if tile.exists():
            tiles.append(str(tile))
    if not tiles:
        return None
    montage = shutil.which("montage")
    if montage:
        subprocess.run([montage, *tiles, "-tile", f"{COLS}x", "-geometry", "+7+7",
                        "-background", hexbg, str(out)], check=False)
    else:
        subprocess.run(base + [*tiles, "-append", "-background", hexbg, str(out)],
                       check=False)
    return out if Path(out).exists() else None


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tokens", nargs="*", help="lucide names, asset ids, or rbxassetid:// URIs")
    ap.add_argument("--list", metavar="TERM", help="search available Lucide names")
    ap.add_argument("--out", default=None, help="output PNG (default: /tmp/icon-sheet.png)")
    a = ap.parse_args()

    names = lucide_map()

    if a.list:
        t = a.list.lower()
        hits = sorted(k for k in names if t in k)
        print(f"{len(hits)} match(es) for {a.list!r} (of {len(names)} icons):\n")
        for k in hits[:120]:
            print(f"  {k:34} {names[k]}")
        if len(hits) > 120:
            print(f"  ... {len(hits) - 120} more")
        return 0

    if not a.tokens:
        ap.print_help()
        return 2

    items, bad = resolve(a.tokens, names)
    for b in bad:
        print(f"  ! unknown icon name {b!r} -- try: icon-sheet.py --list {b[:6]}",
              file=sys.stderr)
    if not items:
        print("nothing to render.", file=sys.stderr)
        return 1

    urls = thumb_urls([aid for _, aid in items])
    out = Path(a.out) if a.out else Path("/tmp/icon-sheet.png")
    out.parent.mkdir(parents=True, exist_ok=True)

    try:
        import PIL  # noqa: F401
        path = build_pillow(items, urls, out)
    except ImportError:
        path = build_magick(items, urls, out)
        if not path:
            print("no image backend. install Pillow (pip install Pillow) or "
                  "ImageMagick.", file=sys.stderr)
            return 1

    print(f"\nwrote {path}  ({len(items)} asset(s))")
    print("NOW OPEN IT AND LOOK AT IT. Creating the file is not the verification.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
