# Throughput: running at the speed the game actually allows

The rest of this skill is mostly about not breaking things. This file is the
counterweight: a hub that is correct and three times slower than it could be is a
worse hub. Every limit here should be a **number someone measured**, not a number
someone felt comfortable with.

The rule that makes the rest of it work:

> **A conservative constant nobody measured is a bug with good manners.**

It looks responsible, it never throws, and it silently costs throughput forever. The
same standard applies as everywhere else in this skill — do not hardcode what the
game can tell you.

---

## Finding the real ceiling

You already have the instrument. `game-data.md` says a `pcall` returning cleanly
proves nothing and that acceptance must be confirmed against observable state — a
count that dropped, a model that despawned. That confirmation *is* the rate meter:
**the first action the server silently ignores is the ceiling.**

The procedure:

1. Pick the action and its observable proof (the same one the automation already
   uses to confirm acceptance).
2. Fire a burst at a rate clearly below what you expect to be the limit. Confirm
   every single one.
3. Raise the rate step by step. Keep confirming every one.
4. The rate at which confirmations start failing — not erroring, *failing to
   change state* — is the ceiling.
5. Settle somewhere below it and **write the measured number, the date, and how you
   measured it into the comment next to the constant.**

The comment carries four things — the number, the date, what you confirmed against,
and where it broke:

```lua
-- <rate>: measured <date>, confirmed against <the observable proof>.
-- <higher rate> started being silently ignored; <this rate> held.
-- Re-measure if the game patches its rate limiter.
local MAX_ACTIONS_PER_SEC = <rate>
```

That comment is the whole point. Without it the next person inherits a magic number
and has no idea whether it is a measured limit or a guess, so they never raise it.

**Two rates are not the same rate.** A server will often accept cheap calls far
faster than expensive ones, so one hub-wide number is either throttling the cheap
actions or overrunning the expensive ones. Measure per action type.

## Where the time actually goes

Measure before optimising, because the intuition is usually wrong. The observations
already recorded elsewhere in this skill all point the same way — **the remote calls
are rarely the bottleneck**:

- **Teleports dominate.** An automation that teleported to each item to trigger its
  proximity prompt was replaced by firing the remote directly: 12 of 12 accepted from
  300 studs away (`interaction-ladder.md`). The teleport was the entire cost, and it
  was not needed at all.
- **Prompts themselves are barely rate-limited.** Where a prompt is genuinely
  required, the cost is the travel, not the prompt (`interaction-ladder.md`).
- **A blocking run costs more than every remote in it.** Running jobs inline instead
  of on their own thread took the loop from 20 ticks to 1 tick per 6 seconds
  (`driver-loop.md`). Nothing about that was the server's fault.
- **Per-item sleeps are the quiet tax.** A sweep that waits a fixed amount per item
  spends nearly all of its wall time waiting. Before adding a `task.wait` inside a
  loop, establish what it is waiting *for* — a client-side debounce, a confirmation
  round-trip, or nothing at all. If it is nothing, delete it. If it is a
  confirmation, see sampling below.

## Batch instead of adding jobs

One call that sells 200 items beats 200 calls, and it beats them at every level: one
budget token instead of 200, one confirmation instead of 200, one interval instead of
200. This is also why a token bucket that counts *runs* is meaningless when one run
sells 200 items (`driver-loop.md`) — count where the remotes actually are.

When a batched call takes a `maxPerRun`, that number is subject to the same rule as
any other limit: measure it, date it, and let the remainder fall to the next
interval rather than lowering it out of caution.

## Sampled confirmation

Confirming every action is right while you are establishing that an action works at
all — it is how you learn the arity, the semantics and the ceiling. It is not
required forever, and it is not free: each confirmation is a read-back, and some cost
a round trip.

Once an action has a proven pattern:

- confirm every *n*th action, and
- confirm immediately on any anomaly — an unexpected count, an empty result, a
  changed script hash (`environments-state.md`), a new game version.

That keeps the property that matters — a silently rejected action cannot loop forever
undetected (`game-data.md`) — while paying for it once every *n* actions instead of
every action. Drop back to confirming everything the moment something looks off.

## Event-driven beats polling

An interval is a latency floor: a job with `interval = 5` reacts, on average, 2.5
seconds late no matter how fast the rest of the hub is. Where the game itself
announces the thing you are waiting for, connect to that announcement instead of
polling for its effects:

- a signal the game already fires, connected directly,
- a remote arriving from the server, observed with a hook (`hooking-protocol.md`).

This is the case where dropping to a lower rung is unambiguously the faster choice,
and it is worth taking deliberately. A restock, a spawn, a weather change or a trade
request are all things the server *tells* the client about — polling for them is
paying an interval to learn something you were already sent.

Two constraints carry over unchanged: never yield inside a hook or a signal handler
(hand off with `task.spawn`), and an event-driven feature is installed once for the
session rather than being a registry entry — both in `hooking-protocol.md`.

**A failed guard's full-interval penalty only applies to polled guards**
(`driver-loop.md`). If the state the guard reads is observable through a signal, wake
on the signal and the penalty disappears along with the poll.

## Interval selection, in the other direction

`driver-loop.md` says to match the interval to how fast the underlying state actually
changes. Read that in both directions: it is a **measured floor**, not a comfort
setting. If the state changes every 2 seconds and the guard is cheap, a 30-second
interval is not caution, it is 28 seconds of nothing happening.

The genuine floors, both measurable:

- **guard cost** — a guard that fires a blocking remote sets how often the job can be
  cheap. Two jobs polling the same state at 1s are four round-trips a second
  (`driver-loop.md`). Share the fetch or merge the jobs rather than slowing both.
- **the server's ceiling** — measured above.

Anything above those two floors is a number to justify or lower.

## Parallelism, and its two real limits

Jobs already run on their own threads (`driver-loop.md`), so the concurrency is
there. What actually serialises a hub is:

- **the shared budget** — sized by the measurement above,
- **the character lock** (`movesCharacter`) — only jobs that move the character
  contend for it. A job marked `movesCharacter` that does not actually move the
  character is giving away parallelism for free; check the flag is honest.

Neither is a reason to add sleeps. If two jobs fight, the fix is usually to make one
of them stop needing the character (fire the remote directly, as above), not to slow
both down.
