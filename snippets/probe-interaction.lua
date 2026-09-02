--!nolint
-- probe-interaction.lua -- which rung of the interaction ladder applies to a target?
--
-- Read-only. Fires nothing, moves nothing, hooks nothing. Run this BEFORE
-- choosing how to interact with something, so the choice is measured instead of
-- guessed. See references/interaction-ladder.md.
--
-- Usage inside the executor:
--     local probe = loadstring(game:HttpGet(URL .. "/snippets/probe-interaction.lua"))()
--     probe(workspace.Map.SomeModel)        -- an Instance, or
--     probe(workspace.Map.SomeModel, Lib)   -- pass your UI library to reuse its compat layer
--
-- The second argument is optional and expects a library exposing
-- `lib.Compat:Get(name)`. If yours resolves executor functions differently, adapt
-- makeGetter below -- it is the only place that knows the shape.
--
-- Without a library it falls back to raw globals, which is fine for a one-off
-- probe but is NOT how shipped hub code should resolve executor functions.

local function makeGetter(lib)
	-- Prefer the project's compat accessor; some executors expose their API only
	-- through getgenv(), so a raw global lookup misses it.
	if lib and lib.Compat and lib.Compat.Get then
		return function(name)
			local ok, fn = pcall(function() return lib.Compat:Get(name) end)
			return ok and fn or nil
		end
	end
	return function(name)
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
end

local function descendantsOfClass(root, class, limit)
	local found = {}
	if not root then return found end
	if root:IsA(class) then table.insert(found, root) end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA(class) then
			table.insert(found, d)
			if #found >= limit then break end
		end
	end
	return found
end

local function rootPart()
	local plr = game:GetService("Players").LocalPlayer
	local ch = plr and plr.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end

return function(target, lib)
	local get = makeGetter(lib)
	local out = {}
	local function say(fmt, ...)
		local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		table.insert(out, line)
		print("[probe] " .. line)
	end

	if typeof(target) ~= "Instance" then
		say("target is %s, expected an Instance", typeof(target))
		return out
	end

	say("target: %s (%s)", target:GetFullName(), target.ClassName)

	local hrp = rootPart()
	if hrp and target:IsA("BasePart") then
		say("distance from HumanoidRootPart: %.1f studs",
			(hrp.Position - target.Position).Magnitude)
	end

	-- Rung 1: does the game expose its own API surface here?
	local remotes = {}
	for _, d in ipairs(target:GetDescendants()) do
		if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			table.insert(remotes, d.ClassName .. " " .. d.Name)
		end
	end
	if #remotes > 0 then
		say("RUNG 1  remotes under target: %s", table.concat(remotes, ", "))
		say("        prefer these over any engine primitive below")
	else
		say("RUNG 1  no remotes under this target (they usually live in ReplicatedStorage)")
	end

	-- Rung 2a: ProximityPrompt. The designed path, but distance-validated.
	local prompts = descendantsOfClass(target, "ProximityPrompt", 8)
	for _, p in ipairs(prompts) do
		say("RUNG 2a ProximityPrompt %q  MaxActivationDistance=%s HoldDuration=%s Enabled=%s",
			p.Name, tostring(p.MaxActivationDistance), tostring(p.HoldDuration),
			tostring(p.Enabled))
		if hrp and p.Parent and p.Parent:IsA("BasePart") then
			local d = (hrp.Position - p.Parent.Position).Magnitude
			say("        anchored to %s, currently %.1f studs away (%s)",
				p.Parent.Name, d,
				d <= p.MaxActivationDistance and "IN RANGE" or "OUT OF RANGE - needs a teleport")
		end
	end
	say("        fireproximityprompt available: %s", tostring(get("fireproximityprompt") ~= nil))

	-- Rung 2b: ClickDetector. Note distance is an ARGUMENT you supply.
	local clicks = descendantsOfClass(target, "ClickDetector", 8)
	for _, c in ipairs(clicks) do
		say("RUNG 2b ClickDetector %q  MaxActivationDistance=%s",
			c.Name, tostring(c.MaxActivationDistance))
	end
	if #clicks > 0 then
		say("        fireclickdetector available: %s (distance is an argument you assert;",
			tostring(get("fireclickdetector") ~= nil))
		say("        the game may still validate it server-side)")
	end

	-- Rung 2c: touch. Must be fired as a begin/end PAIR.
	if target:IsA("BasePart") then
		say("RUNG 2c target is a BasePart; firetouchinterest available: %s",
			tostring(get("firetouchinterest") ~= nil))
		say("        remember: 0 begins contact, 1 ends it. Always fire both, or the")
		say("        server keeps believing you are still touching.")
	end

	-- Rung 3: can any signal here actually replicate?
	local canrep = get("cansignalreplicate")
	local whitelist = get("getsignalwhitelist")
	if canrep then
		local sigs = {}
		if #prompts > 0 then
			table.insert(sigs, { "ProximityPrompt.Triggered", prompts[1].Triggered })
		end
		if #clicks > 0 then
			table.insert(sigs, { "ClickDetector.MouseClick", clicks[1].MouseClick })
		end
		if target:IsA("BasePart") then
			table.insert(sigs, { "BasePart.Touched", target.Touched })
		end
		for _, pair in ipairs(sigs) do
			local ok, res = pcall(canrep, pair[2])
			say("RUNG 3  cansignalreplicate(%s) = %s", pair[1],
				ok and tostring(res) or ("error: " .. tostring(res)))
		end
		if whitelist and #sigs > 0 then
			local ok, wl = pcall(whitelist, sigs[1][2])
			if ok and type(wl) == "table" then
				local n = 0
				for _ in pairs(wl) do n = n + 1 end
				say("        getsignalwhitelist returned %d entr(ies) for %s", n, sigs[1][1])
			end
		end
	else
		say("RUNG 3  cansignalreplicate unavailable -- cannot measure whether a signal")
		say("        reaches the server. firesignal is CLIENT-ONLY and never does.")
	end

	-- Rung 4: is client-side physics even authoritative here?
	local isowner = get("isnetworkowner")
	if isowner and target:IsA("BasePart") then
		local ok, owns = pcall(isowner, target)
		say("RUNG 4  isnetworkowner = %s", ok and tostring(owns) or ("error: " .. tostring(owns)))
		if ok and owns == false then
			say("        client does NOT own this part's simulation; moving it will not replicate")
		end
	end

	say("choose the HIGHEST rung that works. Going lower needs a reason you can state.")
	return out
end
