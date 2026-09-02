# The interaction ladder

How to choose *how* to make something happen in the game.

## The ordering principle

> **Absent a measurement, prefer the primitive that forges the least state.**

Forging less state means fewer assumptions about how the game works, which means
fewer things a game update can break. (Not "what is hardest to notice" — that
framing leads to fragile code.)

**This ordering is a default prior, not a permission ladder.** It tells you where to
start looking when you know nothing about a target. Once you have measured, choose by
measured cost: throughput, latency, and how much maintenance the choice will cost
when the game updates. A lower rung that is demonstrably faster and holds up is the
right answer, and picking it needs a note in a comment saying what you measured —
not a justification for going lower.

The two directions genuinely do agree more often than not, which is the useful part:
the measured-cheapest option is usually also the highest rung. `Garden.CollectFruit`
below is the canonical case — the remote (rung 1) beat teleport-and-prompt (rung 4)
on both robustness *and* speed. But when they disagree, the measurement wins.

The one asymmetry worth keeping in mind: rung 5 is the fastest to *react* (it is
event-driven, with no interval to wait out) and the most expensive to *maintain*
(first thing to break on a game update). Trading maintenance for latency is a real
trade and sometimes the right one — see `throughput.md`.

## The rungs

| # | Rung | Robustness | Divergence | Where it breaks |
|---|---|---|---|---|
| 0 | **Read only** — catalogs, prices, state from the game's own modules; call the game's own calculation functions | high | none | nothing. A changed module shows up in your load-time counts |
| 1 | **The game's own API** — its controller functions / networking definitions, with correct arity and types | high | minimal | wrong arity or types; server requires prior state (tool equipped, a confirm round-trip) |
| 2a | **`fireproximityprompt`** — the designed interaction path | med-high | low | `MaxActivationDistance`, `HoldDuration`, `Enabled`. Costs a teleport. Prompts themselves are barely rate-limited — the teleport is the expensive part |
| 2b | **`fireclickdetector(d, distance, event)`** | medium | low | the distance is an *argument you assert*; the game may cross-check it server-side |
| 2c | **`firetouchinterest(a, b, 0/1)`** | medium | medium | must be fired as a **begin/end pair**; a dangling begin leaves the server believing you are still touching. Approach vector and speed may be checked |
| 3 | **Signal replication** — `cansignalreplicate` → `replicatesignal` | medium | medium | only whitelisted signals replicate (`getsignalwhitelist`). `firesignal` is **client-only** and never reaches the server |
| 4 | **Character / state forging** — teleport (CFrame), WalkSpeed, Gravity, PlatformStand | low | high | most validation lives here: distance per tick, velocity, altitude, ground raycasts. Without network ownership it does not replicate at all |
| 5 | **Hooks** — `hookfunction`, `hookmetamethod`/`__namecall`, `hooksignal` | lowest | highest | changes behaviour for *all* code; breaks on game updates; detectable in principle via `getfunctionhash`, `isuntouched`, `checkcaller` |

*Off-ladder special case:* OS-level input synthesis (`keypress`, `mouse1click`,
`mousemoveabs`). Highest fidelity of all — the game sees genuine input — but the
lowest throughput, it requires window focus (`iswindowactive`), and it is
Windows-only. Reach for it when fidelity matters more than speed, not as a general
rung.

## Rules that follow

**Measure before you move.** Rung 4 is expensive: teleporting per item is slow, it
fights anything else that moves the character, and it is often not required at all.
A real case: an automation teleported to each item to trigger its proximity prompt,
until someone tested the underlying remote and found it accepted 12 of 12 calls
fired from 300 studs away. The remote was rung 1; the teleport was rung 4. The
cheaper rung was also the higher one. Run `snippets/probe-interaction.lua` and read
the distances before deciding.

**`firesignal` is not a substitute for `replicatesignal`.** Firing a signal locally
never reaches the server. But firing locally is often the *better* move: if it makes
the game's own client code perform the action, you are back on rung 1, not rung 3.

**Ask instead of guessing.** `cansignalreplicate(signal)` answers "does this reach
the server" directly. Use it rather than firing and hoping.

**Check ownership before physics.** `isnetworkowner(part)` tells you whether the
client simulates that part at all. If it does not, rung 4 changes replicate nowhere.

**Pairs must be paired.** Every `firetouchinterest(a, b, 0)` needs its `1`.

**Every rung inherits the acceptance rule.** A successful `pcall` means the call did
not error, not that the server did anything. Confirm against observable state — a
count dropped, a model despawned, a pending list emptied — and return *that*. See
`game-data.md`.

## Where it breaks: what the server can independently verify

Roblox is server-authoritative by default, and the platform documents exactly this.
Read the first-party guidance rather than folklore:

```
rbx-docs.py --page /docs/en-us/scripting/security/client-server-boundary.md
rbx-docs.py --page /docs/en-us/scripting/security/access-control.md
```

Property names and limits used above are verifiable at the source:

```
rbx-docs.py --class ProximityPrompt --grep 'MaxActivationDistance|HoldDuration'
rbx-docs.py --class ClickDetector   --grep MaxActivationDistance
```

Things that are easy to miss, all of them classes of failure rather than one game's
quirks:

- **Some actions require the tool to be EQUIPPED.** The server resolves the item
  through the character's equipped tool, so firing with the backpack copy is
  silently rejected. Equip → fire → confirm → unequip, and only unequip if you were
  the one who equipped.
- **Positional actions are validated against tagged parts**, not visual bounds. A
  plot's size reference is usually much larger than its actually-valid regions, so
  random points inside it mostly land somewhere invalid.
- **A convenience remote may not return everything.** An inventory "layout" call
  that returns 5 entries for a 45-item inventory is returning the hotbar. Scan the
  container when you need the whole thing.
- **The same item can exist in more than one form** (a Tool *or* a proxy object).
  Checking for only one class finds nothing the moment the game switches
  representation.
- **A follow-up may be fired for you.** If the game's own controller sends a
  confirm when it receives the server's reply, sending both double-confirms.

## Deciding, concretely

1. Run `snippets/probe-interaction.lua` against the target.
2. Start at the highest rung it reports as available.
3. Measure what that actually costs — per-item latency, and whether it needs a
   teleport. `throughput.md` has the procedure.
4. Take a lower rung when the measurement says it is cheaper, and record the number
   you measured in a comment so the next person can re-check it instead of
   re-deriving it.
5. Verify acceptance against observable state, not against `pcall`.
