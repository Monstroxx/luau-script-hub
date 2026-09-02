---
name: luau-script-hub
description: Build and maintain Roblox Luau script hubs and executor scripts — UI libraries, per-game automation, driver loops, executor API compatibility. Use when working with loadstring(game:HttpGet(...)) scripts, UNC/sUNC executor function names, aliases or capability detection, fireproximityprompt/firetouchinterest/fireclickdetector, hookfunction/hookmetamethod/__namecall or remote hooking, getgenv/getgc/filtergc, Roblox game automation, or when asked which interaction method to use against a game.
---

# Luau script hubs

For building Roblox executor scripts: UI libraries, per-game automation hubs, and
the compatibility layer between them.

## The operating rule

Executor APIs cannot run outside Roblox, and function names, aliases and platform
behaviour all change. So: **look things up, do not recall them.** Three
machine-readable sources are wired into this skill, all cached locally.

Never claim something is verified when the layer that would have verified it was
unavailable. Say which layer was missing.

---

## Step 0 — Probe before anything else

```
scripts/probe-env.sh
```

Reports the Luau toolchain, image backend, dev-server port and repository state.

It cannot see MCP servers — those attach to *you*, not the shell. **Check your own
tool list for a Roblox-capable MCP** (names differ per machine: Madium, Potassium,
roblox-mcp, …). Never assume one exists. If none is attached, the live-verification
layer is unavailable and you must say so.

→ `references/environment.md`

## Step 1 — Read the project before proposing structure

Which UI library is this, and what is its compat accessor called? A hub built on
Rayfield, Fluent, OrionLib or a bespoke library is just as valid as any other. This
skill describes *roles*, not filenames or a specific library.

Where a concrete pattern is quoted below, it is an example to match against what the
project already does — not a requirement to impose on it.

## Step 2 — Architecture

Layer strictly: game cheats never live in the UI library. Per game, split into
`core` (logic) / `registry` (declarative entries) / `hub` (UI + the one driver loop),
so a new feature is one registry entry and nothing else.

Watch for the construction-callback trap: most libraries fire every element callback
once while building, so opening the hub writes `WalkSpeed`, `Gravity` and
`PlatformStand` unless guarded by a `uiReady` flag set after the last element exists.

→ `references/architecture.md`

## Step 3 — The driver loop, and how fast it should run

One loop. Every job on its own thread. A failing guard pays its full interval. Stamp
cooldowns after the run. Re-check the teardown flag before each run, not just
between ticks.

Then make it fast. Every rate limit, interval and `maxPerRun` should be a number
someone **measured against the server's actual ceiling**, dated in a comment — a
conservative constant nobody measured costs throughput forever and looks responsible
doing it. Where the game announces a change itself, connect to that instead of
polling for its effects.

→ `references/driver-loop.md`, `references/throughput.md`

## Step 4 — Choose the interaction primitive

**Absent a measurement, prefer the primitive that forges the least state.** The
ladder is a default prior, not a permission ladder — once you have measured, choose
by measured cost and record the number in a comment.

```
0  read only                        5  hooks
1  the game's own API               4  character/state forging
2  engine primitives (prompt,       3  signal replication
   click, touch)                       (cansignalreplicate first)
```

Measure instead of guessing — `snippets/probe-interaction.lua` reports which rungs
actually apply to a target, including whether a signal can reach the server at all
and whether the client even owns the part's physics. The measured-cheapest option is
usually also the highest rung (a remote landed 12 of 12 collects from 300 studs, so
the teleport it replaced was pure cost) — but when robustness and speed disagree, the
measurement wins.

Note: `firesignal` is **client-only** and never reaches the server; `replicatesignal`
is the one that does.

→ `references/interaction-ladder.md`

## Step 5 — State, and finding things in obfuscated games

`getgenv()` is the home for hub state — one namespaced table, never loose keys.
`_G` and `shared` are the game's, not yours. `getrenv()` is read-only.

Against obfuscation: **match on values, never on names.** Identifiers get renamed;
runtime constants, upvalues and table keys cannot be hidden. `filtergc` is the
precision tool — `snippets/find-by-value.lua` wraps it.

Whatever you find is resolved at every load, never frozen into a constant.

→ `references/environments-state.md`

## Step 6 — Executor function names

**Never guess a name, and never copy one from an individual executor's docs.**

```
scripts/exec-api.py <name>
```

Queries sUNC (tested + portable signatures), Madium (broadest coverage, best alias
source) and the archived UNC list at once, prints a candidate list in the right
order, and flags when a signature is an executor extension that would break
portability.

Two traps it exists to catch: absence from sUNC is *not* proof a function is fake,
and the sources disagree about which spelling is canonical — keep both candidates
and match the project's existing order rather than churning it.

→ `references/executor-api.md`

## Step 7 — Language and platform deltas

Only the parts that bite: where Luau differs from Lua 5.1 (and why the fallback
syntax check is weak evidence), the scheduler (`task.*` vs the legacy globals, what
yields, where you must never yield), and the client/server boundary
(`ServerStorage` does not exist on the client; `StreamingEnabled` means "not
there *yet*").

```
scripts/rbx-docs.py -s <topic>
scripts/rbx-docs.py --class ProximityPrompt --grep MaxActivationDistance
scripts/rbx-docs.py --deprecated wait
```

→ `references/luau-and-roblox.md`

## Step 8 — Hooks

A `__namecall` hook fires on **every** method call in the game and changes behaviour
for all code, not just yours. It is also the fastest way to react to something,
because it is event-driven and waits out no interval — a legitimate reason to pick
one.

With a live client, `snippets/namecall-logger.lua` is the cheapest way to see the
real call surface and measure the rate. **Without one, write the hook anyway**: keep
the fast path to a single comparison and reject early, which is correct whether the
real rate is 50/s or 5000/s, and build the logger's pass-through shape in as its
first-run mode so the measurement still happens later.

A hook is session infrastructure, not a registry entry: it installs once, its restore
hangs off the same teardown handle as the single-instance guard, and a UI toggle
gates the *effect* inside the callback rather than installing and removing the hook.
Keep the original, call through it, and never yield inside it.

→ `references/hooking-protocol.md`

## Step 9 — Game data and proving acceptance

Catalogs start **empty** and are filled from the game's own modules at load; a stale
fallback list rots invisibly. Reuse the game's own calculation functions.

**`pcall` succeeding is not the server accepting.** These remotes are
fire-and-forget. Confirm against observable state — a count dropped, a model
despawned — and return *that*, or a rejected action reads as success and repeats
forever.

→ `references/game-data.md`

## Step 10 — Icons

**Never guess an asset ID.** The glyphs are white on transparent, so a raw thumbnail
looks blank and the name alone proves nothing.

```
scripts/icon-sheet.py home settings crown
```

Then **open the PNG and look at it**. Producing the file is not the verification.

→ `references/icons.md`

## Step 11 — Verify, in three layers

1. **Syntax** — `scripts/syntax-check.sh <files>`; prove the checker works first
   with `--selftest`.
2. **Live** — serve the working tree, load it in the executor, read real state
   through an attached Roblox MCP if there is one.
3. **In-game** — the hub's diagnostics screen.

**A parse check is not a runtime check.** After moving code around, call the
functions.

---

## Contents

| File | For |
|---|---|
| `references/architecture.md` | layering, three-file split, registry contract, `uiReady`, single-instance guard |
| `references/driver-loop.md` | the eight loop rules and the `tryRun` sketch |
| `references/throughput.md` | measuring the server's ceiling; batching, sampling, event-driven work |
| `references/interaction-ladder.md` | which primitive to use, and where each breaks |
| `references/hooking-protocol.md` | the mandatory analysis before any hook |
| `references/environments-state.md` | where state lives; finding things by value |
| `references/luau-and-roblox.md` | Luau≠Lua deltas, scheduler, client/server boundary |
| `references/executor-api.md` | naming standards, alias tables, compat layer |
| `references/game-data.md` | catalogs, remote signatures, proving acceptance |
| `references/icons.md` | icon sources and eye-verification |
| `references/environment.md` | what varies per machine and how to degrade |
| `scripts/probe-env.sh` | capability report |
| `scripts/exec-api.py` | executor function lookup across three standards |
| `scripts/rbx-docs.py` | Roblox platform + Engine API docs |
| `scripts/icon-sheet.py` | asset IDs → labeled contact sheet on dark |
| `scripts/syntax-check.sh` | best available Luau parser, with self-test |
| `snippets/probe-interaction.lua` | which ladder rung applies to a target |
| `snippets/namecall-logger.lua` | read-only hook observation |
| `snippets/find-by-value.lua` | locate code by constants/upvalues/keys |
