# Reading game data, and proving the server accepted

## RULE: Pull lists from the game, never hardcode them

Hand-written name lists rot silently between game updates. One real audit found a
hub's lists had drifted to **69 of 91 seeds, 30 of 35 pets, four watering cans that
no longer existed and an invented item tier** — while looking perfectly plausible in
the dropdowns.

- Every catalog starts **empty** and is filled at load by one `LoadCatalogs()` that
  reads the game's own data modules. **Start empty, not with a stale fallback:** an
  empty list is visible in the returned counts and in diagnostics; a wrong one is
  not.
- **Return per-item detail alongside the names** (price, rarity, base value). It
  removes the next round of hardcoding before it happens.
- **Have `LoadCatalogs()` return counts, and surface them.** A counts table is how
  you notice a module changed shape.
- **Reuse the game's own calculations.** If the game ships a value calculator that
  accounts for size exponent, diminishing returns, multipliers and bonuses, call it.
  Reimplementing it would be both wrong and pointless.
- **If something genuinely cannot be enumerated** (a module exporting only
  functions), hardcode it **once**, say why in a comment, and record how you
  verified the values and when.
- **Do not assume a convenience remote returns everything.** A "get layout" call
  that returns 5 entries for a 45-item inventory is returning the hotbar. Scan the
  container itself when you need the whole thing.

Where the module is obfuscated, find it by value rather than by name — see
`environments-state.md` and `snippets/find-by-value.lua`. What you find is resolved
at every load, never frozen into a constant.

Remember what is reachable at all: **`ServerStorage` and `ServerScriptService` do
not replicate to the client.** A module that is not in `ReplicatedStorage`,
`Workspace`, `Players` or `ReplicatedFirst` is not hidden — it was never sent.

## RULE: Never guess a remote's arguments

Read the arity off the live networking definition rather than by decompiling a
40k-character controller:

```lua
#Networking.<Namespace>.<Name>.Writes
```

Where the definitions hold reader functions per argument, the reader's source line
identifies the type:

```lua
for i, f in ipairs(Networking.Namespace.Name.Reads) do
    print(i, select(2, debug.info(f, "sl")))
end
```

Calibrate those line numbers against a remote whose signature you already know from
working code, then reuse the mapping. This yields arity and types but **not**
semantics — which of three strings is the id and which is the target still needs the
controller or a live experiment.

**When you do decompile**, look for the *sending* side, and check whether the game
fires a follow-up. If the game's own controller sends a confirm when it receives the
server's reply, sending both double-confirms.

## RULE: `pcall` succeeding is not the server accepting

These remotes are fire-and-forget and the server silently ignores invalid requests.
Verify against observable state and return *that*:

| action | proof it worked |
|---|---|
| planting/consuming an item | the tool's `Count` dropped |
| buying a spawned entity | the model despawned (`model.Parent == nil`) |
| spending an upgrade point | the point total dropped |
| claiming a reward | the pending list was non-empty to begin with |

Without this, a rejected action reads as success, resets its cooldown, and repeats
forever. The clearest case: a server ignores requests for an already-maxed upgrade,
so a capped first entry absorbed every point while the rest of the priority list was
never reached — silently, indefinitely.

Confirm every action while you are establishing that one works at all — it is also
how you find the server's rate ceiling. Once the pattern is proven, the confirmation
can drop to every *n*th action plus on any anomaly, which keeps the property that
matters (a rejection cannot loop undetected) without paying a read-back every time.
See `throughput.md`.

## RULE: Check the game's wiki, not just its code

The code says what a remote *accepts*; it rarely says what a feature *is for* or how
players are meant to reach it. Two examples where a wiki settled what the code could
not:

- **A "missing" shop that never existed.** Pets were bought from wild spawns roaming
  the map before a despawn timer expired; eggs came from weekly guild rewards
  delivered to a mailbox. Searching the code for a shop turns up nothing and looks
  like an unimplemented feature.
- **Weekly-rotating scoring.** One week a guild competition counted hatched eggs,
  another each member's single highest sale — which inverts the optimal strategy. It
  is invisible in remote signatures and readable at runtime, so read it instead of
  assuming.

Fold what you learn into the design, and cite the source in a comment when the
behaviour would otherwise look arbitrary.
