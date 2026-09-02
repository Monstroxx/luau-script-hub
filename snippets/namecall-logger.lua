--!nolint
-- namecall-logger.lua -- observe before you hook.
--
-- Step 1 of the hooking protocol (references/hooking-protocol.md), and it is not
-- optional: a hook that has never run as a pure logger does not get written.
--
-- This installs a __namecall hook that changes NOTHING. It counts calls, records
-- argument shapes, and passes everything straight through. Its job is to tell you
-- two things you cannot guess:
--   * the blast radius -- a __namecall hook fires on EVERY method call in the
--     game, and you need the real rate before you put logic in the hot path
--   * the actual call surface -- which methods, on which objects, with what
--     arguments
--
-- Usage:
--     local log = loadstring(game:HttpGet(URL .. "/snippets/namecall-logger.lua"))()
--     local session = log.start({ seconds = 10, filter = "FireServer" })
--     -- ... play/idle ...
--     session.report()          -- prints the tally; auto-restores when time is up
--     session.stop()            -- restore early
--
-- Options:
--     seconds  how long to observe before auto-restoring   (default 10)
--     filter   only record namecalls containing this string (default: all)
--     samples  max argument samples kept per method         (default 3)

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

local function describe(v)
	local t = typeof(v)
	if t == "Instance" then return "Instance<" .. v.ClassName .. ">"
	elseif t == "string" then return string.format("string(%q)", #v > 24 and (v:sub(1, 24) .. "..") or v)
	elseif t == "number" or t == "boolean" then return t .. "(" .. tostring(v) .. ")"
	elseif t == "table" then
		local n = 0
		for _ in pairs(v) do n = n + 1 end
		return "table(" .. n .. ")"
	end
	return t
end

function M.start(opts, lib)
	opts = opts or {}
	local seconds = opts.seconds or 10
	local filter = opts.filter
	local maxSamples = opts.samples or 3

	local hookmetamethod = resolve("hookmetamethod", lib)
	local getnamecallmethod = resolve("getnamecallmethod", lib)
	local checkcaller = resolve("checkcaller", lib)
	local restorefunction = resolve("restorefunction", lib)

	if not hookmetamethod or not getnamecallmethod then
		warn("[namecall-logger] hookmetamethod/getnamecallmethod unavailable on this executor")
		return nil
	end

	local counts, samples, selfKinds = {}, {}, {}
	local total, recorded = 0, 0
	local startedAt = os.clock()
	local active = true
	local original

	original = hookmetamethod(game, "__namecall", function(self, ...)
		-- Pass-through first and always: this hook must be observably inert.
		if not active then return original(self, ...) end
		total = total + 1

		-- Skip our own calls so the tally reflects the GAME's behaviour.
		local mine = false
		if checkcaller then
			local ok, r = pcall(checkcaller)
			mine = ok and r
		end
		if not mine then
			local ok, method = pcall(getnamecallmethod)
			if ok and type(method) == "string" then
				if (not filter) or string.find(method, filter, 1, true) then
					counts[method] = (counts[method] or 0) + 1
					recorded = recorded + 1
					local sk = typeof(self) == "Instance" and self.ClassName or typeof(self)
					selfKinds[method] = selfKinds[method] or {}
					selfKinds[method][sk] = (selfKinds[method][sk] or 0) + 1
					samples[method] = samples[method] or {}
					if #samples[method] < maxSamples then
						local parts = {}
						for i = 1, select("#", ...) do
							table.insert(parts, describe((select(i, ...))))
						end
						table.insert(samples[method],
							(typeof(self) == "Instance" and self:GetFullName() or tostring(self))
							.. " (" .. table.concat(parts, ", ") .. ")")
					end
				end
			end
		end
		return original(self, ...)
	end)

	local session = {}

	function session.stop()
		if not active then return end
		active = false
		if restorefunction then
			pcall(function()
				local mt = getrawmetatable and getrawmetatable(game)
				if mt then restorefunction(mt.__namecall) end
			end)
		end
		print("[namecall-logger] stopped (restorefunction "
			.. (restorefunction and "used" or "UNAVAILABLE -- hook may still be live") .. ")")
	end

	function session.report()
		local elapsed = os.clock() - startedAt
		print(string.rep("-", 66))
		print(string.format("[namecall-logger] %.1fs observed", elapsed))
		print(string.format("  BLAST RADIUS: %d namecalls total = %.0f/sec",
			total, total / math.max(elapsed, 0.001)))
		print(string.format("  recorded (after filter/self-exclusion): %d", recorded))
		if total / math.max(elapsed, 0.001) > 2000 then
			print("  !! this hot path runs thousands of times a second. Any logic you")
			print("     add here costs frame time on EVERY game method call. Use a")
			print("     filter, and keep the fast path to a single comparison.")
		end
		local sorted = {}
		for m, c in pairs(counts) do table.insert(sorted, { m, c }) end
		table.sort(sorted, function(a, b) return a[2] > b[2] end)
		print("  methods seen:")
		for i, pair in ipairs(sorted) do
			if i > 25 then print(string.format("    ... %d more", #sorted - 25)) break end
			local kinds = {}
			for k, n in pairs(selfKinds[pair[1]] or {}) do
				table.insert(kinds, k .. "x" .. n)
			end
			print(string.format("    %-28s %6d   on: %s", pair[1], pair[2],
				table.concat(kinds, ", ")))
			for _, s in ipairs(samples[pair[1]] or {}) do
				print("        " .. s)
			end
		end
		print(string.rep("-", 66))
		print("  Now answer, IN WRITING, before changing any behaviour:")
		print("   1. what could be manipulated through these calls?")
		print("   2. which of that do we actually need?")
		print("  The gap between 1 and 2 is attack surface you would be building.")
	end

	task.delay(seconds, function()
		if active then
			session.stop()
			session.report()
		end
	end)

	print(string.format("[namecall-logger] observing for %ds%s -- pass-through only",
		seconds, filter and (" (filter: " .. filter .. ")") or ""))
	return session
end

return M
