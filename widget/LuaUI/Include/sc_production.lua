-- Sub-Commanders production (design/engine.md): what a factory builds next, from doctrine data.
-- The tier mix (by metal income, like BARbarian's factory.json) is blended with the counter matrix
-- (what answers what the enemy fields, like its response.json); the factory builds the category whose
-- share is furthest below what's wanted, and in it the best unit it can afford.
--
-- usage: local Production = VFS.Include("LuaUI/Include/sc_production.lua", nil, VFS.RAW_FIRST)
--        local prod = Production({ defs = defs, doctrine = D })
--        local defID, category = prod.pick(options, have, income, enemyKinds, { cap = 400 })
-- Pure Lua: unit-tested in widget/tests/production_test.lua.

local max = math.max

local COMBAT = { "raider", "assault", "skirmisher", "heavy", "artillery", "mobile anti-air" }

return function(ctx)
	local defs, D = ctx.defs, ctx.doctrine
	local P = { COMBAT = COMBAT }

	-- the production category of a unit: constructor, one of COMBAT, scout, or nil (not ours to pick)
	function P.category(d)
		if not d or not d.mobile then
			return nil
		end
		if d.builder and not d.commander then
			return "constructor"
		end
		if not d.combat and d.kind ~= "mobile anti-air" then
			return nil
		end
		local kind = (d.kind or ""):gsub("^hover ", "")
		if kind == "scout" then
			return "scout"
		end
		for _, c in ipairs(COMBAT) do
			if kind == c then
				return c
			end
		end
		-- aircraft and anything else armed: count as assault for mix purposes
		return d.aaOnly and "mobile anti-air" or "assault"
	end

	function P.tier(income)
		local tiers = D.production.tiers
		local t = tiers[1]
		for i = 1, #tiers do
			if income >= tiers[i].income then
				t = tiers[i]
			end
		end
		return t
	end

	-- how much each combat category answers what the enemy fields (enemyKinds: kind -> count)
	function P.response(enemyKinds)
		local total = 0
		for _, n in pairs(enemyKinds or {}) do
			total = total + n
		end
		local score = {}
		if total <= 0 then
			return score
		end
		local sum = 0
		for cat, r in pairs(D.response) do
			local s = 0
			for kind, w in pairs(r.vs) do
				s = s + w * (enemyKinds[kind] or 0) / total
			end
			score[cat] = s
			sum = sum + s
		end
		if sum > 0 then
			for cat, s in pairs(score) do
				score[cat] = math.min(s / sum, D.response[cat].max)
			end
		end
		return score
	end

	-- wanted shares per category (constructor included) at this income against this enemy
	function P.desired(income, enemyKinds)
		local t = P.tier(income)
		local want = {}
		local combatShare = 1 - (t.constructor or 0)
		local resp = P.response(enemyKinds)
		local hasResp = next(resp) ~= nil
		local w = hasResp and D.responseWeight or 0
		local respSum = 0
		for _, s in pairs(resp) do
			respSum = respSum + s
		end
		want.constructor = t.constructor or 0
		for _, c in ipairs(COMBAT) do
			local tierPart = (t[c] or 0) / max(combatShare, 1e-9)
			local respPart = respSum > 0 and (resp[c] or 0) / respSum or 0
			want[c] = combatShare * ((1 - w) * tierPart + w * respPart)
		end
		return want
	end

	-- options: list of defIDs the factory can build; have: category -> count we have (from this factory's
	-- owner); opts.cap: most metal per unit; opts.combatOnly: no constructors; opts.category: force one
	-- returns defID, category (nil if nothing fits)
	function P.pick(options, have, income, enemyKinds, opts)
		opts = opts or {}
		local byCat = {}
		for _, o in ipairs(options) do
			local d = defs[o]
			local c = P.category(d)
			if c and c ~= "scout" and (not opts.cap or d.cost <= opts.cap) and not (opts.combatOnly and c == "constructor") then
				byCat[c] = byCat[c] or {}
				byCat[c][#byCat[c] + 1] = o
			end
		end
		local cat = opts.category
		if not (cat and byCat[cat]) then
			cat = nil
			local want = P.desired(income, enemyKinds)
			local total = 0
			for c in pairs(byCat) do
				total = total + (have[c] or 0)
			end
			local bestGap
			for c in pairs(byCat) do
				local w = want[c] or 0
				if w > 0 then
					local gap = w - (have[c] or 0) / max(total, 1)
					if not bestGap or gap > bestGap or (gap == bestGap and c < cat) then
						cat, bestGap = c, gap
					end
				end
			end
		end
		if not cat then
			return nil
		end
		local list = byCat[cat]
		table.sort(list, function(a, b)
			local da, db = defs[a], defs[b]
			if cat == "raider" or cat == "constructor" then
				-- raiders: the fastest; constructors: the cheapest
				if cat == "raider" and da.speed ~= db.speed then
					return (da.speed or 0) > (db.speed or 0)
				end
				return da.cost < db.cost
			end
			-- the strongest that fits the budget
			return da.cost > db.cost
		end)
		-- variety among the strongest two of a fighting category (BARb mixes, e.g. Ballista and Centaur)
		if cat ~= "raider" and cat ~= "constructor" and #list > 1 then
			P.turn = (P.turn or 0) + 1
			return list[(P.turn % 2) + 1], cat
		end
		return list[1], cat
	end

	-- a turret's role in an area's mix (doctrine.turrets): "light", "heavy" or "long" (nil: not a ground
	-- defence turret)
	function P.turretRole(d)
		local Tt = D.turrets
		if not d or not d.staticDef or d.aaOnly then
			return nil
		end
		if (d.range or 0) >= Tt.longRange then
			return "long"
		end
		return d.cost < Tt.lightCost and "light" or "heavy"
	end

	-- which turret role an area needs next: the one furthest below its share of the mix.
	-- have: role -> count in the area; density: the posture's multiplier; frame: game frame (long-range
	-- turrets come later); available: role -> true for roles the constructor can build. Returns the role,
	-- or nil when the area has its full mix.
	function P.turretNeed(have, density, frame, available)
		local Tt = D.turrets
		local best, bestGap
		for _, role in ipairs({ "light", "heavy", "long" }) do
			local want = Tt.mix[role] * (density or 1)
			if role == "long" and frame < Tt.longFrom then
				want = 0
			end
			local gap = want - (have[role] or 0)
			if gap > 0 and (not available or available[role]) and (not bestGap or gap / want > bestGap) then
				best, bestGap = role, gap / want
			end
		end
		return best
	end

	-- the factory's next opening step (1-based), or nil once the opening is done
	function P.opening(step)
		return D.production.opening[step]
	end

	return P
end
