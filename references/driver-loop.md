# One driver loop, and runs never block it

All timing lives in a **single** loop in the hub file. Every rule below was paid for
by a real failure.

- **Run each job on its own thread** (`task.spawn`), with an in-flight flag per key.
  Runs yield — a sweep that waits ~1s per item is normal — and running them inline
  freezes the whole tick. Measured: **1 tick per 6 seconds instead of 20**, with the
  status readout apparently dead and short-interval automations missing their
  windows entirely.

- **Give jobs that teleport a shared lock** (`movesCharacter`) so two of them do not
  fight over where the character stands.

- **A failing guard pays its full interval.** Guards are not free — most fire
  blocking remotes. Re-checking a failed guard early turned eight idle "cheap, safe
  to leave running" toggles into **~32 remote round-trips per second**, none of
  which the rate limiter saw. This penalty is the price of *polling*: if the state
  the guard reads is observable through a signal, wake on the signal instead and the
  penalty disappears with the poll (`throughput.md`).

- **Stamp the cooldown after the run**, not at tick start, or a job that yielded
  past its own interval comes back off cooldown immediately.

- **Let a guard hand its result to `run`** by returning it as a second value.
  Otherwise both fetch the same state; the worst case was a full descendant walk of
  every spawn model, twice per cycle.

- **Rate-limit where the remotes actually are.** A bucket that counts *runs* is
  meaningless when one run sells 200 items. Batched functions take a `maxPerRun` and
  defer the rest to the next interval. **Size the bucket by measurement, not by
  feel** — `throughput.md` has the procedure for finding the server's actual ceiling,
  and the rule that every such constant carries the number, the date and the method
  in its comment.

- **Walk the job list from a rotating offset**, or the entries at the front drain
  the budget every tick and the tail never runs. (A bucket that refills once a
  second, with a loop ticking four times, starves everything past the first few.)

- **Guard against a second instance.** Re-running the script stacks driver loops
  that keep firing after their window is destroyed. Each load tears down its
  predecessor through a `getgenv()` handle, and the loop **re-checks that flag
  before each run** — between ticks is not enough when a run can yield for a minute.

## Sketch

```lua
local function tryRun(entry, now)
    if inFlight[entry.key] then return false end
    local interval = entry.interval or 1
    local last = cooldowns[entry.key]
    if last and (now - last) < interval then return false end

    local ctx
    if entry.guard then
        local ok, pass, guardCtx = pcall(entry.guard, S)
        if not ok or not pass then
            cooldowns[entry.key] = now       -- full interval; guards cost remotes
            return false
        end
        ctx = guardCtx
    end
    if entry.movesCharacter and characterBusy then return false end
    if budget <= 0 then return false end
    budget = budget - 1
    if session.stopped then return false end

    inFlight[entry.key] = true
    if entry.movesCharacter then characterBusy = true end
    task.spawn(function()
        local ok, result = pcall(entry.run, S, ctx)
        local finished = os.clock()          -- after the run, not tick start
        cooldowns[entry.key] = (ok and result) and finished
            or (finished - interval * 0.5)   -- retry sooner on failure
        inFlight[entry.key] = nil
        if entry.movesCharacter then characterBusy = false end
    end)
    return true
end
```

Note the `pcall`: errors inside `task.spawn` are swallowed, so without it a throwing
job would leave `inFlight` set forever and that key would never run again.

## Instrument the loop when it looks dead

Patching a counter into the source before loading it turns "the UI isn't updating"
into "the loop ticked once in six seconds", which points straight at a blocking run:

```lua
src = src:gsub("if stopped then break end",
    "if stopped then break end getgenv().__HB.ticks = getgenv().__HB.ticks + 1", 1)
```

Where the executor provides one, a real console (`rconsoleprint`) is easier to read
than `warn` spam during this.

## Interval selection

- Match the interval to how fast the underlying state actually changes, not to how
  responsive it feels. **This cuts both ways**: an interval well above the rate the
  state changes at is not caution, it is latency you chose. The interval is a
  measured floor, not a comfort setting — see `throughput.md`.
- A guard that costs a remote round-trip sets a floor on how often a job can be
  cheap. Two jobs polling the same state at 1s are four round-trips a second. Share
  the fetch or merge the jobs rather than slowing both.
- Prefer one job that batches over several that each fire.
- Where the game announces the change itself, prefer no interval at all: connect to
  the signal instead of polling for its effects.
