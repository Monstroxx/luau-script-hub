# Hooking protocol

Applies to `hookfunction`, `hookmetamethod` / `__namecall`, `hooksignal`, and any
interception of remotes.

Hooks are rung 5 of the interaction ladder: the most powerful primitive and the
most fragile. They change behaviour for **all** code in the game, not just yours.
So the bar is higher than "it worked once".

**No hook gets written before this analysis exists.** Not as a formality — each
step exists because skipping it produces a specific, recurring failure.

---

## 1. Observe first, in pure pass-through

Run `snippets/namecall-logger.lua`. It installs a hook that changes nothing and
only counts.

> A hook that has never run as a logger does not ship.

You cannot reason about a call surface you have not seen. The logger tells you
which methods actually fire, on which object classes, with which argument shapes.

## 2. Quantify the blast radius

A `__namecall` hook fires on **every** method call in the game. Before putting any
logic in it, know the real rate — the logger prints calls/second.

If that number is in the thousands, every comparison you add costs frame time on
every game method call. Keep the fast path to a single comparison, and reject early.

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

## 8. Never change behaviour for code you have not analysed

If the logger showed calls you do not understand, the hook passes them through
untouched. "Probably unrelated" is how a hook breaks an unrelated feature.

---

## Integrity: why this rung is the most fragile

The same primitives that let you hook let anything else detect hooks:
`getfunctionhash`, `getscripthash`, `isuntouched`, `isfunctionhooked`,
`issignalhooked`, `checkcaller`, `isexecutorclosure`.

The practical consequence is not drama, it is churn: hooks are the first thing to
break when a game updates, and the hardest thing to debug when they do. Record
`getscripthash` for the scripts you depend on — when the hash changes, the game
changed and your automation needs re-verifying rather than silent failure.
