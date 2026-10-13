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
		return list[1], cat
	end

	-- the factory's next opening step (1-based), or nil once the opening is done
	function P.opening(step)
		return D.production.opening[step]
	end

	return P
end
