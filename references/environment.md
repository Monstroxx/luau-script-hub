# What varies per machine, and how to degrade

Nothing in this skill assumes a particular toolchain, editor, or MCP server. Probe,
then adapt. **Run this first, every session:**

```
scripts/probe-env.sh
```

## The three verification layers, and when each is unavailable

| Layer | Needs | If missing |
|---|---|---|
| **1. Syntax** | a Luau parser, or Lua 5.1 as a fallback | say the file is unverified. Do not claim it parses |
| **2. Live** | a dev server + a Roblox-capable MCP attached to the agent | you can still serve files; you **cannot** read live game state. Say so |
| **3. In-game** | the hub's own diagnostics screen | requires a human in the game |

**A parse check is not a runtime check.** After moving code around, call the
functions. Reordering a module may parse cleanly and still leave an upvalue bound
before its local existed; calling every public function with harmless arguments is
what proves it did not.

## Luau toolchain

Installation differs per machine and none of it is guaranteed. `syntax-check.sh`
picks the best available, in order: `luau-analyze` → `luau-lsp analyze` →
`luau --check` → `luac -p` (Lua 5.1 fallback).

The Lua 5.1 fallback cannot parse Luau. It rewrites compound assignments so the file
parses at all, which makes it a usable ends/parens check and nothing more — see
`luau-and-roblox.md` for the full list of constructs that false-alarm. Set `$LUAC`
if a Lua 5.1 `luac` exists somewhere off `PATH`.

Prove the checker can actually fail before trusting a pass:

```
scripts/syntax-check.sh --selftest
```

A checker that never fails is worse than no checker.

## MCP servers

Roblox-capable MCPs (Madium, Potassium, roblox-mcp, others) are configured
differently on every machine, and may not be present at all.

- **Discover, never assume.** Check your own tool list for one. Do not hardcode a
  server's name into instructions or code.
- If one is attached, prefer reading real values out of the running client — module
  contents, remote signatures, instance attributes — over assuming them.
- **If none is attached, the live layer is unavailable.** Report that plainly rather
  than implying a change was verified against a real game.

## Serving the working tree

The pattern, not a specific script: serve the repository over HTTP so the executor
loads your working copy, and have a small loader pick the right hub by `PlaceId`.

- Serve `.lua`/`.luau` as `text/plain`, set `Cache-Control: no-store`, and **strip
  `Last-Modified` and `ETag`** — otherwise an executor happily serves stale bytes and
  you debug yesterday's code.
- Point the raw-URL variable at the dev server so nested loads resolve locally too,
  and cache-bust with a query parameter.
- **Compile separately from running** (`loadstring(src, "@" .. name)`) so a syntax
  error reports as a syntax error instead of a mysterious runtime failure.
- Host, port and the environment variable names are all project choices. Probe
  whether the port is free rather than assuming 8080.

If the repository is private, `raw.githubusercontent.com` returns 404 without auth —
which is usually why a local dev server exists in the first place.

## Image tooling

`icon-sheet.py` uses Pillow if importable, otherwise ImageMagick. Neither is
guaranteed; the probe reports which is present and how to install one. Do not write
platform-specific image code — a PowerShell/System.Drawing pipeline is not portable
to a machine being worked from Linux.

## Documentation retrieval

Three machine-readable sources, all cached under `~/.cache/luau-script-hub/`:

| For | Use |
|---|---|
| executor function names, aliases, signatures | `scripts/exec-api.py` |
| Roblox platform concepts and Engine API | `scripts/rbx-docs.py` |
| icon assets | `scripts/icon-sheet.py` |

All support `--offline` where a cache exists. Prefer these over recalling any of it
from memory — the whole point is that names, aliases and deprecations change.
