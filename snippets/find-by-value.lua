--!nolint
-- find-by-value.lua -- locate code in an obfuscated game by what it HOLDS,
-- not by what it is called.
--
-- Obfuscation renames identifiers. It cannot hide runtime values: the code still
-- has to compare against the real string, index the real key, and hold the real
-- remote reference. So match on those. See references/environments-state.md.
--
-- Usage:
--     local find = loadstring(game:HttpGet(URL .. "/snippets/find-by-value.lua"))()
--
--     -- a function whose bytecode contains a string constant:
--     find.fn({ constants = { "PlantSeed" } })
--
--     -- a function that closes over a known value:
--     find.fn({ upvalues = { workspace.Map } })
--
--     -- a table that has these keys (a catalog, a config, a state store):
--     find.tbl({ keys = { "WalkSpeed", "MaxHealth" } })
--
--     -- narrow further, and stop at the first hit:
--     find.fn({ constants = { "FireServer" }, ignore_executor = true }, true)
--
-- Every hit is reported with debug.getinfo and, where available, getfunctionhash,
-- so you can recognise the same target in a later session even though its name is
-- meaningless.

local M = {}

local function resolve(name, lib)
	if lib and lib.Compat and lib.Compat.Get then
		local ok, fn = pcall(function() return lib.Compat:Get(name) end)
		if ok and type(fn) == "function" then return fn end
	end
	local env = getfenv(0)
	if type(rawget(env, name)) == "function" then return rawget(env, name) end
	if type(getgenv) == "function" then
		local ok, g = pcall(getgenv)
		if ok and type(g) == "table" and type(rawget(g, name)) == "function" then
			return rawget(g, name)
		end
	end
	return nil
end

local function hasAll(list, wanted)
	for _, w in ipairs(wanted) do
		local seen = false
		for _, v in pairs(list) do
			if v == w then seen = true break end
		end
		if not seen then return false end
	end
	return true
end

-- Manual fallback when filtergc is missing: walk getgc ourselves.
local function manualScan(kind, opts, returnOne, lib)
	local getgc = resolve("getgc", lib)
	if not getgc then return nil, "neither filtergc nor getgc is available" end
	local ok, pool = pcall(getgc, kind == "table")
	if not ok then return nil, "getgc failed: " .. tostring(pool) end

	local getconstants = resolve("debug.getconstants", lib) or (debug and debug.getconstants)
	local getupvalues = resolve("debug.getupvalues", lib) or (debug and debug.getupvalues)
	local isexecutorclosure = resolve("isexecutorclosure", lib)

	local hits = {}
	for _, v in ipairs(pool) do
		local match = false
		if kind == "function" and type(v) == "function" then
			match = true
			if opts.ignore_executor and isexecutorclosure then
				local o, r = pcall(isexecutorclosure, v)
				if o and r then match = false end
			end
			if match and opts.constants and getconstants then
				local o, c = pcall(getconstants, v)
				match = o and type(c) == "table" and hasAll(c, opts.constants)
			end
			if match and opts.upvalues and getupvalues then
				local o, u = pcall(getupvalues, v)
				match = o and type(u) == "table" and hasAll(u, opts.upvalues)
			end
		elseif kind == "table" and type(v) == "table" then
			match = true
			if opts.keys then
				for _, k in ipairs(opts.keys) do
					if rawget(v, k) == nil then match = false break end
				end
			end
		end
		if match then
			table.insert(hits, v)
			if returnOne then break end
		end
	end
	return hits
end

local function search(kind, opts, returnOne, lib)
	opts = opts or {}
	local filtergc = resolve("filtergc", lib)
	local hits, err

	if filtergc then
		-- filtergc's option table is executor-defined; pass through what we were
		-- given and fall back if it rejects the shape.
		local ok, res = pcall(filtergc, kind, opts, false)
		if ok and type(res) == "table" then
			hits = res
		else
			warn("[find-by-value] filtergc rejected these options ("
				.. tostring(res) .. "); falling back to a manual getgc scan")
		end
	end
	if not hits then
		hits, err = manualScan(kind, opts, returnOne, lib)
		if not hits then
			warn("[find-by-value] " .. tostring(err))
			return {}
		end
	end
	if returnOne and #hits > 1 then
		hits = { hits[1] }
	end
	return hits
end

local function reportFunctions(hits, lib)
	local getfunctionhash = resolve("getfunctionhash", lib)
	local getconstants = resolve("debug.getconstants", lib) or (debug and debug.getconstants)
	print(string.format("[find-by-value] %d function match(es)", #hits))
	for i, f in ipairs(hits) do
		if i > 15 then print(string.format("  ... %d more", #hits - 15)) break end
		local src, line = "?", "?"
		local ok, info = pcall(function() return debug.getinfo(f) end)
		if ok and type(info) == "table" then
			src = tostring(info.source or info.short_src or "?")
			line = tostring(info.linedefined or info.currentline or "?")
		end
		local hash = ""
		if getfunctionhash then
			local o, h = pcall(getfunctionhash, f)
			if o then hash = "  hash=" .. string.sub(tostring(h), 1, 16) .. ".." end
		end
		print(string.format("  [%d] %s:%s%s", i, src, line, hash))
		if getconstants then
			local o, c = pcall(getconstants, f)
			if o and type(c) == "table" then
				local shown = {}
				for _, v in pairs(c) do
					if type(v) == "string" and #shown < 8 then
						table.insert(shown, string.format("%q", v))
					end
				end
				if #shown > 0 then
					print("       constants: " .. table.concat(shown, ", "))
				end
			end
		end
	end
	if #hits > 1 then
		print("  more than one hit: add another constant/upvalue to narrow it,")
		print("  rather than picking [1] and hoping.")
	end
end

local function reportTables(hits)
	print(string.format("[find-by-value] %d table match(es)", #hits))
	for i, t in ipairs(hits) do
		if i > 15 then print(string.format("  ... %d more", #hits - 15)) break end
		local n, sample = 0, {}
		for k in pairs(t) do
			n = n + 1
			if #sample < 8 then table.insert(sample, tostring(k)) end
		end
		print(string.format("  [%d] %d key(s): %s", i, n, table.concat(sample, ", ")))
	end
end

--- Find functions. opts: { constants = {...}, upvalues = {...}, ignore_executor = bool }
function M.fn(opts, returnOne, lib)
	local hits = search("function", opts, returnOne, lib)
	reportFunctions(hits, lib)
	return hits
end

--- Find tables. opts: { keys = {...} }
function M.tbl(opts, returnOne, lib)
	local hits = search("table", opts, returnOne, lib)
	reportTables(hits)
	return hits
end

--- Reminder, because this is the step people skip.
function M.note()
	print("Resolve what you found at EVERY load. Freezing the result into a")
	print("constant recreates the hardcoded list that rots on the next update.")
	print("Record getfunctionhash/getscripthash instead: when the hash changes,")
	print("the game changed and the automation needs re-verifying.")
end

return M
