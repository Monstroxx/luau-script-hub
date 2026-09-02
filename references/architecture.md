# Hub architecture

## Layering: cheats never live in the library

| Layer | Contains | Must not contain |
|---|---|---|
| **UI library** | elements, theming, config save/load, the compat layer, session helpers | anything game-specific |
| **Hub scaffold** | the tabs every hub gets (movement, server hop, settings) | per-game logic |
| **Per-game hub** | UI construction + the single driver loop | game logic |

Generic cheats (fly, walkspeed, gravity, infinite jump) belong in the scaffold, not
in the library. The library should be usable by someone who wants none of them.

## Three files per game, one job each

Splitting these is what keeps a hub readable past ~10 features:

| File | Contains | Must not contain |
|---|---|---|
| `<game>_core.lua` | game logic as plain functions on one table | any UI, any timing |
| `<game>_registry.lua` | one declarative entry per automation | logic, UI |
| `<Game>-<PlaceId>.lua` | UI construction + the single driver loop | game logic |

Each is loaded separately over HTTP at runtime. Keep the filenames stable: the dev
loader maps PlaceId → hub file, and users load a hub by its raw URL.

### The registry entry contract

```lua
{
    key      = "ClaimMail",          -- state field, cooldown key, flag suffix
    tab      = "Collect",
    section  = "Mail & Rewards",
    title    = "Auto-claim mailbox",
    content  = "Claims pending mailbox rewards",
    interval = 60,                   -- seconds between runs
    flag     = "hub_claimmail",      -- optional; keeps old saved configs working
    guard    = function(S) ... end,  -- optional precondition; may return a ctx
    run      = function(S, ctx) ... end,
    movesCharacter = false,          -- shares the character lock; see driver-loop.md
}
```

The hub generates the toggle, the state field and the loop job from that entry, so a
new feature is **one entry and nothing else**. Before this split, every automation
was declared in three places and drifted between them.

A registry usually also declares its tabs:

```lua
Registry.TABS = { { name = "Collect", icon = "Package" } }
```

where `icon` is a key the hub resolves against the library's icon table.

## Construction-time callbacks: the `uiReady` guard

Most UI libraries fire every element's callback once while building, so the element
reflects its initial state. That means **merely opening the hub writes
`Humanoid.WalkSpeed`, `workspace.Gravity` and `PlatformStand`** unless you guard it:

```lua
local uiReady = false
-- ... build every tab and element ...
uiReady = true

-- inside each callback:
if not uiReady then return end
```

Without this, a saved config that was never touched still stomps the character on
load. Set the flag *after* the last element exists.

## Single-instance guard

Re-running the script must tear down its predecessor, or driver loops stack up and
keep firing after their window is destroyed. The handle lives in `getgenv()` — see
`environments-state.md`:

```lua
local G = getgenv()
G.MyHub = G.MyHub or {}
if G.MyHub.session then G.MyHub.session.stopped = true end
local session = { stopped = false }
G.MyHub.session = session
```

**Re-check the flag before each run, not just between ticks** — a run can yield for
a minute, and the teardown may happen inside it.

## Feature gating for server-authoritative games

Some games validate movement server-side, so offering fly or walkspeed there is
worse than useless — it gets players kicked and looks like your bug. Let a hub
disable them by name:

```lua
Hub.createHub{
    Disable = { "Fly", "Walkspeed", "Gravity", "InfiniteJump" },
}
```

**Disabled controls must never be built**, not merely hidden. An element that exists
can be restored from a saved config; one that was never created cannot.

## Cleanup

Every connection and instance goes through a maid/janitor so a hub can be destroyed
and reloaded without leaking. Anything that connects must also disconnect —
including the driver loop's own subscriptions.

## Order of operations at startup

1. Load the library, then the core and registry modules.
2. Build the window and all tabs.
3. Configure session extras (auto-execute code, anti-AFK, auto-rejoin).
4. **Then** start config autosave — it must run after every element exists, or it
   snapshots a half-built UI.
5. Resume any cross-teleport state (a server hop in progress).
6. Set `uiReady = true` and start the driver loop.

## Hub infrastructure worth knowing about

- `request` — version checks, webhook notifications.
- `getcustomasset` — use a local image or font as a Roblox asset without uploading
  it. Useful for a hub logo.
- `writefileasync` / `readfileasync` — non-blocking config writes, where available.
  Debounced autosave that writes synchronously stutters the loop.
- `lz4compress` + `base64encode` — for configs large enough to matter.
- `WebSocket.connect` — live telemetry out of the driver loop.
- `rconsoleprint` / `rconsolewarn` — a real console beats `warn` spam when
  instrumenting a loop.
- `setfpscap` / `getfpscap` — the driver loop is timing-sensitive; an fps cap
  changes how often render-stepped work runs.

Check availability with `exec-api.py` before depending on any of these; several are
executor extensions rather than portable APIs.
