# Environments and state

Two questions: where your own variables belong, and how to find something in a game
whose identifiers are meaningless.

---

## Part A — Where your own variables belong

| Location | Visible to game code | Reach | Verdict |
|---|---|---|---|
| **`getgenv()`** — the executor global environment, *"shared across all executor-made threads"* | no | every executor script, whole session | **The right home for hub state.** Survives separate loads; the basis for single-instance guards and teleport persistence |
| **local upvalues** in your own chunk | no | this script only | **The most private option** — it lives in no table. But not shareable, and still reachable through `debug.getupvalue` on your own functions |
| **`_G`** / **`shared`** | **yes, readable and writable** | game + executor | **Not for hub state.** Collides with game code and gets overwritten. Only when interop with game scripts is the actual goal |
| **`getrenv()`** — the game global environment | yes | whole game | Read only. sUNC warns: *"Changes to this environment will affect your executor environment as well"* |
| **`getreg()`** — the Luau registry | — | internal | Analysis surface, never a storage location |
| `getsenv(script)` / `gettenv(thread)` | — | someone else's | Tools for reading *other* environments, not places to put things |

Verify any of these claims at the source:

```
exec-api.py getgenv
exec-api.py getrenv
```

### Rules

- **Exactly one namespaced table.** `getgenv()` is shared with every other hub
  running in that session, so loose keys are a collision you only discover when two
  scripts run at once:

  ```lua
  local G = getgenv()
  G.MyHub = G.MyHub or {}      -- everything of yours lives under here
  ```

- **The single-instance guard and teleport persistence hang off that same handle.**
  Re-running a hub must tear down its predecessor, and the driver loop must re-check
  that flag *before each run* — between ticks is not enough when a run can yield for
  a minute:

  ```lua
  if G.MyHub.session then G.MyHub.session.stopped = true end
  local session = { stopped = false }
  G.MyHub.session = session
  -- inside the loop, and inside each job:
  if session.stopped then return end
  ```

- **Only what must survive a reload goes there.** `getgenv()` is for persistence,
  not for everything. Anything scoped to one run stays a local.

- **Queue across teleports deliberately.** `queueonteleport` persists a script
  across a server hop; `clearqueueonteleport` exists so you do not stack duplicates
  when you queue more than once.

---

## Part B — Against obfuscation: match on values, never on names

This is the direct counterpart to "never hardcode a list the game already has".

> Obfuscation renames identifiers. It **cannot hide runtime values** — the code
> still has to compare against the real string, index the real key, and hold the
> real remote reference. So match on those.

### The toolchain

- **`filtergc(kind, options, returnOne)`** — the precision instrument. Filters
  garbage-collected functions and tables by constants, upvalues, proto info and
  table keys. Tested in sUNC, so portable. `getgc(true)` is the blunt version when
  you want to filter yourself.
- **`debug.getconstants` / `getupvalues` / `getprotos` / `getinfo`** on a located
  closure — read what it actually compares against.
- **`getloadedmodules` / `getscripts` / `getrunningscripts` / `getinstances` /
  `getnilinstances`** — enumerate rather than trusting a path. `getnilinstances`
  finds what the game removed from the tree.
- **`getsenv(script)`** — read an obfuscated LocalScript's environment and see the
  real values.
- **`getscripthash` / `getfunctionhash`** (both SHA-384) — stable identity within
  and across sessions for something whose name is garbage.
- **`gethiddenproperty` / `gethiddenproperties` / `getproperties` / `isscriptable` /
  `setscriptable`** — read non-scriptable properties. Server-set state the game does
  not expose often lives exactly there.
- **`isnetworkowner(part)`** — whether the client simulates that part at all.
- **`getcallbackvalue`** — read `OnClientInvoke` and friends: what the server can
  ask the client to do.
- **`getthreadidentity` / `setthreadidentity`** — often the precondition for
  touching protected instances and properties at all.

Use `snippets/find-by-value.lua`, which wraps `filtergc` with a `getgc` fallback and
reports `debug.getinfo` plus `getfunctionhash` for every hit.

```lua
find.fn({ constants = { "PlantSeed" } })          -- a function that mentions it
find.fn({ upvalues = { workspace.Map } })         -- a function that closes over it
find.tbl({ keys = { "WalkSpeed", "MaxHealth" } }) -- a config/state table
```

More than one hit means the filter is too loose. Add another constant or upvalue —
do not take `[1]` and hope.

### The rule that keeps it from rotting

**Resolve at every load. Never freeze the result into a constant.** Baking a found
offset, index or id into the source recreates exactly the hardcoded list that goes
stale on the next update, except now it looks authoritative.

Record hashes instead of values:

```lua
local hash = getscripthash(theScript)
if hash ~= KNOWN_HASH then
    -- the game changed; this automation is unverified until someone re-checks it
end
```

That converts a silent breakage into a visible one, which is the whole point.
