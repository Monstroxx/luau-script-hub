# Luau and the Roblox runtime — the parts that bite

**This is deliberately not a language tutorial.** Numbers, strings, `if`, loops and
recursion are not where hub bugs come from. What follows is only the *deltas*: where
Luau differs from Lua, and where the Roblox runtime constrains what hub code can do.

Admission rule: **every entry here must connect to a rule stated elsewhere in this
skill.** Anything that does not, does not belong.

Anything beyond this is looked up, not memorised:

```
rbx-docs.py -s <topic>
rbx-docs.py --page /docs/en-us/luau.md
rbx-docs.py --class <ClassName>
```

---

## Part A — Luau is not Lua 5.1

Constructs Luau has that Lua 5.1 rejects:

| Luau | Lua 5.1 |
|---|---|
| `x += 1`, `s ..= "a"` | syntax error |
| `continue` | syntax error |
| `local x: number`, `-> ()` type annotations | syntax error |
| `` `count: {n}` `` string interpolation | syntax error |
| `//` floor division | syntax error |
| `if a then b else c` as an *expression* | syntax error |
| `table.create` / `table.clear` / `table.freeze` | missing at runtime |
| generalized iteration (`for k, v in t do`) | needs `pairs` |
| `bit32` library | no bitwise ops at all |

Luau also has **no `goto`** (Lua 5.2+ does).

**Why this matters for verification.** `scripts/syntax-check.sh` prefers a real Luau
parser and falls back to Lua 5.1's `luac -p`, rewriting compound assignments so the
file at least parses. That fallback is weak evidence in both directions:

- a fallback **failure** may be a false alarm — `continue`, type annotations,
  backtick strings, `//` and if-expressions all trip it, and the rewrite only
  handles compound assignments;
- a fallback **pass** means the ends and parens balance. Nothing more.

Install `luau-analyze` where you can. Either way: **a parse check is not a runtime
check.** After moving code around, call the functions.

## Part B — The scheduler and threads

This is what the driver loop rules are actually about.

**Use `task.*`, not the legacy globals.** `wait`, `spawn` and `delay` are superseded
by `task.wait`, `task.spawn`, `task.defer` and `task.delay`. The legacy ones carry a
throttled resumption that is a classic cause of "why is my loop 30× slower than the
interval says". Confirm the status from the source rather than from memory:

```
rbx-docs.py --deprecated wait
rbx-docs.py --page /docs/en-us/scripting/scheduler.md
```

**Errors inside `task.spawn` are swallowed.** A job that throws simply stops, with
nothing printed and its in-flight flag possibly still set. Wrap the body in `pcall`
and clear state in the failure path — the driver-loop sketch does exactly this.

**Know what yields.** `task.wait`, `:WaitForChild`, `RemoteFunction:InvokeServer`,
`HttpGet`, and most "wait for the server" helpers. The rule "runs must never block
the loop" is nothing but a statement about these calls: run each job on its own
thread so its yields cost only that job.

**Know where you must never yield:** inside a `__namecall` hook, inside a signal
handler, and inside anything running on the game's thread. Those run on the caller's
thread; yielding stalls the game's own code. Hand off with `task.spawn` and return.

## Part C — The client/server boundary and the tree

The foundation under the interaction ladder.

**Server authority is always on.** What makes ladder rungs 4 and 5 risky is
documented first-party — cite it rather than folklore:

```
rbx-docs.py --page /docs/en-us/scripting/security/client-server-boundary.md
rbx-docs.py --page /docs/en-us/scripting/security/access-control.md
```

**`ServerStorage` and `ServerScriptService` do not exist on the client.** This is
the single most common wrong assumption behind "read the game's data modules". You
can reach only what replicates: `ReplicatedStorage`, `Workspace`, `Players`,
`PlayerGui`, `ReplicatedFirst`, `Lighting`. If a module is not there, it is not
missing — it was never sent.

**`RemoteEvent` vs `RemoteFunction`.** Events are fire-and-forget: the server
ignoring your request looks exactly like success, which is why acceptance must be
confirmed against observable state. Functions round-trip and therefore **yield** —
never call one inline in a loop tick. The server can also invoke the *client*
through `OnClientInvoke`, readable with `getcallbackvalue`.

**`StreamingEnabled` means parts may not exist yet.** For any automation that ranges
over the map, "not there" and "not there *yet*" are different failures. Do not treat
an empty scan as proof of absence:

```
rbx-docs.py --page /docs/en-us/workspace/streaming.md
```

**Respawn invalidates character references.** The character, humanoid and root part
are all replaced. Resolve them through helpers on every use rather than caching them
at startup — this is why hub scaffolding has `getChar` / `getHumanoid` style
accessors instead of locals.

**`Destroy()` vs `Parent = nil`.** A destroyed instance is locked and unusable; a
reparented one is merely detached and still fully alive. That is why
`getnilinstances` finds things at all, and why a "deleted" object can still be
driving behaviour.

---

## Entry points for anything else

- `https://create.roblox.com/docs/luau` — the language
- `https://create.roblox.com/docs/creation` — the platform and its objects

Both are reachable as Markdown through `rbx-docs.py`. Note the routing warning the
Roblox docs give themselves: the **Engine API** (Luau objects via
`game:GetService()`) and **Open Cloud** (HTTP with an `x-api-key`, from outside
Roblox) are separate systems. A script hub always wants the Engine API.
