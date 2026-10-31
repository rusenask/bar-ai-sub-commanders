-- Sub-Commanders asks (doctrine.asks): a sub-commander (its rules, the strategist or the player) asks the
-- team for units with a "units" request on the blackboard (sc_team.lua: { kind = "units", from, what,
-- count, note }); another sub-commander's factory that can make them builds them and hands them over.
--   WHATS                          what one can ask for, by name (or a unit's own name, e.g. "armpeep")
--   matches(what, d)               does unit def d answer it
--   pick(what, options, defs, cap, opts)   the defID a factory builds for it (options: its defIDs), or nil
--   due(r, frame)                  may a factory answer it now: under `count` on the way, `every` apart
--   sent(r, frame)                 a factory took it on (one more on the way)
--   arrived(r)                     one of them was handed over (a one-shot ask: one fewer wanted)
--
-- usage: local Asks = VFS.Include("LuaUI/Include/sc_asks.lua", nil, VFS.RAW_FIRST)
--        local A = Asks({ doctrine = D })
-- Pure Lua: unit-tested in widget/tests/asks_test.lua.

return function(ctx)
	local D = ctx.doctrine
	local A = {}

	local function mobileBuilder(d)
		return d.mobile and d.builder and not d.commander
	end

	-- each kind: which units answer it, and which of those to build ("cheap": the cheapest, "best": the
	-- dearest the factory can afford, "options": the most build options)
	A.WHATS = {
		constructor = { test = mobileBuilder, by = "cheap" },
		constructor2 = { test = function(d)
			return mobileBuilder(d) and (d.tech or 1) >= 2
		end, by = "options" },
		combat = { test = function(d)
			return d.combat and not d.aaOnly and not d.scout
		end, by = "best" },
		antiair = { test = function(d)
			return d.combat and d.aaOnly and not d.air
		end, by = "best" },
		fighter = { test = function(d)
			return d.air and d.armed and d.aaOnly
		end, by = "best" },
		bomber = { test = function(d)
			return d.air and d.kind == "bomber"
		end, by = "best" },
		gunship = { test = function(d)
			return d.air and d.kind == "gunship"
		end, by = "best" },
		raider = { test = function(d)
			return d.combat and (d.kind == "raider" or d.kind == "hover raider")
		end, by = "cheap" },
		scout = { test = function(d)
			return d.scout or (d.air and d.kind == "scout plane")
		end, by = "cheap" },
		radarplane = { test = function(d)
			return d.air and not d.armed and not d.transport and not d.builder
		end, by = "cheap" },
		radar = { test = function(d)
			return d.mobile and not d.air and not d.armed and not d.builder and (d.radarRange or 0) >= 1800
		end, by = "cheap" },
		sub = { test = function(d)
			return d.sub
		end, by = "cheap" },
		spy = { test = function(d)
			return d.spy
		end, by = "cheap" },
		amphibious = { test = function(d)
			return d.combat and d.deepWater
		end, by = "best" },
		transport = { test = function(d)
			return d.mobile and d.transport
		end, by = "cheap" },
	}

	function A.matches(what, d)
		local w = A.WHATS[what]
		if w then
			return w.test(d) and true or false
		end
		return d.name == what
	end

	-- opts.sonar: on a water map, sonar ones first (radar planes)
	function A.pick(what, options, defs, cap, opts)
		local w = A.WHATS[what] or { by = "cheap" }
		local best, bestKey
		for _, o in ipairs(options) do
			local d = defs[o]
			if d and (d.cost or 0) <= cap and A.matches(what, d) then
				local key
				if w.by == "best" then
					key = d.cost
				elseif w.by == "options" then
					key = #(d.options or {})
				else
					key = -d.cost
				end
				if opts and opts.sonar and d.mobileSonar then
					key = key + 1e6
				end
				if not bestKey or key > bestKey then
					best, bestKey = o, key
				end
			end
		end
		return best
	end

	-- r.onWay: frames when factories took it on; ones older than doctrine.asks.onWay are dropped (the unit
	-- was cancelled or its factory died)
	local function prune(r, frame)
		local keep = {}
		for _, f in ipairs(r.onWay or {}) do
			if frame - f <= D.asks.onWay then
				keep[#keep + 1] = f
			end
		end
		r.onWay = keep
	end

	function A.due(r, frame)
		prune(r, frame)
		return #r.onWay < (r.count or 1) and frame - (r.answered or -math.huge) >= D.asks.every
	end

	function A.sent(r, frame)
		prune(r, frame)
		r.onWay[#r.onWay + 1] = frame
		r.answered = frame
	end

	function A.arrived(r)
		if r.onWay and #r.onWay > 0 then
			table.remove(r.onWay, 1)
		end
		r.delivered = (r.delivered or 0) + 1
		-- a one-shot ask (nobody refreshes its count): one fewer wanted
		if r.oneShot then
			r.count = math.max(0, (r.count or 1) - 1)
		end
	end

	return A
end
