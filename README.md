# Luau Script Hub — Claude Code Skill

A Claude Code skill for building Roblox Luau script hubs and executor scripts:
UI libraries, per-game automation, driver loops, and the compatibility layer
between them.

## Install

```bash
npx skills add Monstroxx/luau-script-hub
```

Targets Claude Code by default; use `-a` to install to other agents, `-g` for a
global install:

```bash
npx skills add Monstroxx/luau-script-hub -g -a claude-code -y
```

Manual alternative:

```bash
git clone https://github.com/Monstroxx/luau-script-hub ~/.claude/skills/luau-script-hub
```

## What it does

The skill encodes a working discipline for Roblox executor development. Its core
rule: **executor APIs cannot run outside Roblox, and function names, aliases and
platform behaviour all change — so look things up, do not recall them.** Three
machine-readable sources are wired in and cached locally.

It covers, in workflow order:

1. **Probe the environment first** — Luau toolchain, image backend, dev server,
   repo state, and whether a Roblox MCP is attached for live verification.
2. **Read the project** before proposing structure — any UI library (Rayfield,
   Fluent, OrionLib, bespoke) is treated as valid; the skill describes roles,
   not filenames.
3. **Architecture** — strict layering: game logic never lives in the UI
   library; per-game `core` / `registry` / `hub` split so a new feature is one
   registry entry. Includes the construction-callback trap and the `uiReady`
   guard.
4. **The driver loop and throughput** — one loop, every job on its own thread,
   cooldown stamped after the run, teardown re-checked inside each tick; then
   every limit sized by a measurement of the server's actual ceiling rather
   than by a conservative guess.
5. **Interaction ladder** — absent a measurement, prefer the primitive that
   forges the least state, from read-only up to hooks; a probe script measures
   which rung actually applies to a target, and the measurement outranks the
   ladder when the two disagree.
6. **State and obfuscation** — `getgenv()` namespacing, matching on values
   instead of names, `filtergc` as the precision tool.
7. **Executor function names** — cross-checked against sUNC, Madium and the
   archived UNC list at once, with alias detection and portability flags.
8. **Luau/platform deltas** — where Luau differs from Lua 5.1, the scheduler,
   and the client/server boundary.
9. **Hooks** — pass-through logging and blast-radius analysis where a live
   client allows it, a single-comparison fast path where it does not, and the
   session lifecycle a hook has to be wired into.
10. **Game data** — catalogs start empty and are filled from the game's own
    modules; `pcall` succeeding is not the server accepting.
11. **Icons** — never guess an asset ID; the sheet script renders a labeled
    contact sheet you must actually open and look at.
12. **Three-layer verification** — syntax, live, in-game.

## Contents

| Path | Purpose |
|---|---|
| `SKILL.md` | The 11-step workflow, entry point for the agent |
| `references/` | Deep-dive docs for each step (11 files) |
| `scripts/probe-env.sh` | Capability report for the local machine |
| `scripts/syntax-check.sh` | Best available Luau parser, with self-test |
| `scripts/exec-api.py` | Executor function lookup across three standards |
| `scripts/rbx-docs.py` | Roblox platform + Engine API docs |
| `scripts/icon-sheet.py` | Asset IDs to labeled contact sheet on dark |
| `snippets/` | Drop-in Lua probes: interaction rung, `__namecall` logger, `filtergc` finder |

## Requirements

- bash and Python 3 (scripts use the standard library only)
- Optional: a Luau CLI (`luau`, `luau-lsp`) for stronger syntax checks
- Optional: a Roblox MCP server attached to the agent for live in-game
  verification — the skill degrades honestly when it is missing

## License

[MIT](LICENSE)