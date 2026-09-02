# Hooking protocol

Applies to `hookfunction`, `hookmetamethod` / `__namecall`, `hooksignal`, and any
interception of remotes.

Hooks are the most powerful primitive available and the highest-maintenance one.
They change behaviour for **all** code in the game, not just yours. They are also
frequently the *fastest* option: a hook is event-driven, so it reacts the moment
the game does, with no polling interval to wait out. Choosing one for that reason
is a legitimate throughput decision — see `throughput.md`.

**None of the steps below are permission gates.** Each is here because skipping it
produces a specific, recurring failure, and each says which. Where a step needs a
live client you may not have, it says what to do instead. Nothing here blocks
writing a hook.

---

## 1. Observe first, when you have a live client

`snippets/namecall-logger.lua` installs a hook that changes nothing and only counts.
With a client running, it is by far the cheapest way to learn the real call surface:
which methods actually fire, on which object classes, with which argument shapes.
Guessing that from source reading takes far longer and is often wrong.

**Without a live client, write the hook anyway.** Build the logger's pass-through
shape into it as its first-run mode, so the measurement happens the first time
someone does run it, and note in a comment that the rate is still unmeasured. An
unmeasured hook that exists beats a measured one that was never written.

## 2. Quantify the blast radius

A `__namecall` hook fires on **every** method call in the game, so its cost is
whatever you do per call multiplied by the game's own call rate. The logger prints
that rate in calls/second.

**Absent a measurement, assume the hot path runs in the thousands per second and
write for it.** That costs nothing: keep the fast path to a single comparison and
reject early, before any other work.

```lua
-- The whole fast path: one comparison, then out.
if getnamecallmethod() ~= "FireServer" then return original(self, ...) end
```

Written that way the hook is cheap whether the real rate turns out to be 50/s or
5000/s, and the measurement becomes a confirmation rather than a prerequisite.

## 3. Enumerate the call surface

Separate the game's code from your own:

```lua
local cons = getconnections(someSignal)
for _, c in ipairs(cons) do
    print(isgamescriptconnection(c), isluaconnection(c))
end
```

`checkcaller()` inside the hook tells you whether the current call came from your
own thread — exclude your own traffic or the tally is meaningless.

For each remote you intercept, establish: arity, argument types, semantics, and
**whether the server sends a confirm the game's own controller responds to**. If it
does, and you also send that confirm, you double-confirm.

Read arity and types from the game's networking definitions rather than by
decompiling a 40k-character controller. Where the definitions hold reader functions
per argument, the reader's source line identifies the type:

```lua
for i, f in ipairs(SomeNetworking.Namespace.Name.Reads) do
    print(i, select(2, debug.info(f, "sl")))
end
```

Calibrate those line numbers against a call whose signature you already know from
working code. This yields arity and types but **not** semantics — which of three
strings is the id still needs the controller or a live experiment.

## 4. Write down what it could do, before changing what it does

Answer both, explicitly:

1. What could be manipulated through this hook?
2. Which of that do we actually need?

**The gap between the two is attack surface you are building into your own tool.**
A `__namecall` hook that intercepts every `FireServer` in order to change one call
is a hook that can change every call — including when a later edit, or a game
update, shifts what flows through it. Narrow the hook until the gap is small.

## 5. Constrain the blast radius

Filter early and cheaply. Prefer a filter object over an `if`-cascade in the hot
path where the executor provides one — but treat those as **extensions**:

```lua
-- Portable: the 3-argument sUNC form.
local original
original = hookmetamethod(game, "__namecall", function(self, ...)
    if getnamecallmethod() ~= "FireServer" then return original(self, ...) end
    ...
    return original(self, ...)
end)
```

Some executors accept extra parameters (an argument guard, a filter object) and ship
a filter library for exactly this. Those are not portable. Gate them:

```lua
local hasFilters = Compat:Has("NamecallFilter.new")
```

Verify portability before relying on a signature:

```
exec-api.py hookmetamethod     # reports sUNC 3 params vs Madium 5, and says so
```

## 6. Keep the original, and clean up

Always store the return value, always call through it, and restore on teardown:

```lua
local mt = getrawmetatable(game)
restorefunction(mt.__namecall)     -- or restoresignal() for hooksignal
```

A hub that reloads without restoring stacks hooks on top of each other.

## 7. Never yield inside a hook

`__namecall` hooks and signal handlers run on the caller's thread. Yielding there
(`task.wait`, `:InvokeServer`, `HttpGet`, `:WaitForChild`) stalls the game's own
code. Hand work off with `task.spawn` and return immediately.

## 8. Pass through what you have not analysed

Calls you do not understand are best passed through untouched rather than swept into
whatever transformation you are applying. "Probably unrelated" is how a hook breaks
an unrelated feature — and a hook that broke something unrelated costs a debugging
session, which is the most expensive thing that can happen to a fast build.

---

## Integrity: why this rung is the most fragile

The same primitives that let you hook let anything else detect hooks:
`getfunctionhash`, `getscripthash`, `isuntouched`, `isfunctionhooked`,
`issignalhooked`, `checkcaller`, `isexecutorclosure`.

The practical consequence is not drama, it is churn: hooks are the first thing to
break when a game updates, and the hardest thing to debug when they do. Record
`getscripthash` for the scripts you depend on — when the hash changes, the game
changed and your automation needs re-verifying rather than silent failure.
