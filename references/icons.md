# Icons

Most Roblox UI libraries ship a small curated icon table, but anything taking an
icon accepts any `rbxassetid://`. The table is a convenience shortlist, not a limit
— the Lucide set alone has 1500+ mapped to Roblox assets.

## RULE: never guess an asset ID, verify it by eye

**Never trust the name alone, and never recall an ID from memory.**

The failure mode is specific: these icons are **white on a transparent background**,
so a raw thumbnail renders white-on-white and looks blank. "It downloaded fine" tells
you nothing.

```
scripts/icon-sheet.py home settings crown flame skull
scripts/icon-sheet.py 7733960981 rbxassetid://7734053495
scripts/icon-sheet.py --list arrow          # search available Lucide names
```

The script batches the thumbnails API, composites each asset **onto a dark
background**, labels it with name and ID, and writes a contact sheet.

**Then open the PNG and look at it.** Producing the file is not the verification;
seeing the glyph is. Read the image — do not infer from the fact that the command
exited 0.

## Sources

1. **`https://www.icons.rest/`** — browse 1500+ Lucide icons mapped to Roblox asset
   IDs. Easiest way to find one by eye and copy its `rbxassetid`.
2. **`github.com/frappedevs/lucideblox`** — 565 icons as **individual assets**. Two
   things that are easy to get wrong: the default branch is **`master`**, not
   `main`, and the JSON is **nested under an `icons` key**, not a flat map. The path
   is `src/modules/util/icons.json`. Archived in 2022, but the asset IDs still
   resolve. `icon-sheet.py` reads this.
3. **`github.com/latte-soft/lucide-roblox`** — fuller and better maintained, but it
   ships a **spritesheet** (`ImageRectOffset` / `ImageRectSize`). If your
   `ImageLabel`s only set `Image`, its IDs will **not** work without adding rect
   support first. Do not reach for it by default.

## Naming

Keys in a library's icon table are conventionally **PascalCase**. Lucide names like
`repeat` are Lua keywords and `refresh-cw` is not a valid identifier, so `Repeat`
and `Refresh` sidestep both problems. Keep the mapping obvious — if the Lucide name
is not recoverable from the key, note it in a comment.

## Adding an entry

1. Find a candidate (`icon-sheet.py --list <term>` or icons.rest).
2. Render it together with the icons it will sit next to — a glyph that reads fine
   alone can be indistinguishable from its neighbour at 20px.
3. Look at the sheet.
4. Add the PascalCase key with the verified ID.
