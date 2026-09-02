# Executor function names and compatibility

Before adding, renaming, or adding a fallback for **any** executor function
(`writefile`, `setclipboard`, `queueonteleport`, `fireproximityprompt`, …), consult
the naming standards.

**Never guess a name, and never copy one from an individual executor's docs.** Most
of those describe executors that no longer exist.

```
scripts/exec-api.py <name>        # all three sources at once
scripts/exec-api.py -s <term>     # search when you are not sure of the spelling
```

## The three sources, and what each is authoritative for

**1. sUNC — `https://docs.sunc.io/`** (note: `docs.sunc.su` now redirects here)

Actively maintained. Documents **only** what the sUNC test script actually
exercises — about 79 functions — so it is the authority on *"is this real and tested
today"* and on **portable signatures**.

It has deliberately diverged from the original UNC list. Critically:

> **Absence from sUNC is not proof a function does not exist.** `setclipboard` and
> `queueonteleport` are not in sUNC, yet every executor ships them.

Machine-readable: `api/mini.json` (names → descriptions), `api/jumbo.json`
(signatures, parameters, library grouping).

**2. Madium — `https://getmadium.net/`**

Broadest coverage (484 functions) and **the best alias source**. Exposes a proper
retrieval API — `llms.txt` → `llm/index.json` → one canonical Markdown file per
function. Do not scrape `/docs/`; it is a SPA and its own README says not to.

Some entries document **Madium-specific extensions**. `exec-api.py` flags these by
comparing parameter counts against sUNC, because using an extension breaks
portability to other executors.

**3. UNC archive — `github.com/unified-naming-convention/NamingStandard/api`**

Archived May 2024. Authority on **historically documented aliases** only, e.g.
`setclipboard` → `toclipboard`, `identifyexecutor` → `getexecutorname`.

## When the sources disagree on the canonical spelling

They do. Madium calls `queueonteleport` canonical with `queue_on_teleport` as an
alias; other sources have it the other way round.

**Keep both candidates. Order them to match what the project already uses. Do not
churn working code to match a source's preference.** The candidate list is what
matters, not which entry is called "canonical".

## Implementation rules

**One declarative alias table, no scattered ad-hoc fallbacks.** Candidate order:

1. the canonical name
2. documented aliases
3. a legacy executor namespace (dotted, e.g. `syn.queue_on_teleport`) as a last
   resort — and only with evidence that executor ever mattered here

Comment each entry with the source it came from.

**All executor calls go through the project's compat accessor** — validated and
cached — never through raw globals. Resolve in *both* environments:

```lua
pcall(function() resolveAliases(getfenv(0)) end)
pcall(function()
    if type(getgenv) == "function" then resolveAliases(getgenv()) end
end)
```

Some executors expose their API **only** through `getgenv()`. A lookup like
`rawget(getfenv(0), "fireproximityprompt")` therefore fails on those — and `rawget`
additionally skips any `__index`-backed environment proxy. It fails silently,
returning nil with no diagnostic, and the feature simply never works.

**A standalone module with no reference to the UI library should accept an injected
function** rather than reaching for a global itself:

```lua
-- in the logic module
function Core.SetPromptFirer(fn) promptFirer = type(fn) == "function" and fn or nil end

-- in the hub, which does have the library
pcall(function() Core.SetPromptFirer(Lib.Compat:Get("fireproximityprompt")) end)
```

**Register names so they show up in diagnostics.** Whatever list the compat layer
iterates for its status report, add new names to it — otherwise a missing function
is mysterious instead of reportable. Check for the inverse mistake too: a name with
an alias entry that is *not* in the iterated list never has its aliases walked and
never appears in diagnostics.

**Polyfills stay opt-in.** [Quartz](https://gitlab.com/upio/quartz) is the sanctioned
runtime polyfill for missing functions, docked explicitly by the host application.
**Never auto-load remote code from a library.**

**Validate capability, do not assume it.** Before using an extension signature or an
optional function, ask the compat layer whether it exists. For filesystem access
specifically, a presence check is not enough — do a real write → read → compare
round trip once and cache the result, because `writefile` existing does not mean it
works.
