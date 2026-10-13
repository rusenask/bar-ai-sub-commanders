-- Sub-Commanders air force (design/engine.md): what an Air Force sub-commander builds and where its wings
-- go (doctrine.air).
--   fighters  hold the sky over our base and army, intercept enemy aircraft (scouts too), escort strikes
--   gunships  hunt raiding parties in and near our base where their anti-air is weak
--   bombers   (and gunships with nothing to hunt) strike what the enemy left without anti-air, on routes
--             around it; anti-air the wing can destroy outright is worth more (it opens the way)
--   scouts    keep looking at the enemy's side, so strikes have fresh targets
--
-- usage: local Air = VFS.Include("LuaUI/Include/sc_air.lua", nil, VFS.RAW_FIRST)
--        local air = Air({ doctrine = D })
--        air.class(def)                    -- "fighter" / "gunship" / "bomber" / "scout" / nil
--        air.want(have, enemyAirShare)     -- the class to build next
--        air.strike(candidates, aaAt, wing) -- the strike target
--        air.hunt(groups, aaAt, power)      -- the raiding party for the gunships
-- Pure Lua: unit-tested in widget/tests/air_test.lua.

local max, min, sqrt = math.max, math.min, math.sqrt

return function(ctx)
	local D = ctx.doctrine
	local A = {}

	-- the air force's classes; nil for anything that isn't a plane it uses (constructors, transports)
	function A.class(d)
		if not d or not d.air or not d.mobile or d.builder or d.kind == "air transport" then
			return nil
		end
		if not d.armed then
			return "scout"
		end
		if d.aaOnly then
			return "fighter"
		end
		return d.kind == "bomber" and "bomber" or "gunship"
	end

	-- what to build next. have: class -> count; enemyAir: the share of their units that fly. A scout
	-- first, then fighters up to their share (more when the enemy flies), then bombers and gunships.
	function A.want(have, enemyAir)
		local P = D.air
		if (have.scout or 0) < P.scouts then
			return "scout"
		end
		local fighters, gunships, bombers = have.fighter or 0, have.gunship or 0, have.bomber or 0
		local share = min(P.maxFighters, max(P.fighters, (enemyAir or 0) * 1.5))
		if fighters < share * (fighters + gunships + bombers + 1) then
			return "fighter"
		end
		if bombers < P.bombers * (gunships + bombers + 1) then
			return "bomber"
		end
		return "gunship"
	end

	local function dist(x1, z1, x2, z2)
		local dx, dz = x1 - x2, z1 - z2
		return sqrt(dx * dx + dz * dz)
	end

	-- the strike target. candidates: { id, x, z, value, kind, name, aa (true for their anti-air) };
	-- aaAt(x, z): enemy anti-air metal around a point; wing: { x, z, power }. Only targets where the wing
	-- is doctrine.air.need times their anti-air; their anti-air counts aaBonus times its value. Returns
	-- the target and the anti-air there.
	function A.strike(candidates, aaAt, wing)
		local P = D.air
		local best, bestScore, bestAA
		for _, t in ipairs(candidates) do
			local aa = aaAt(t.x, t.z)
			if wing.power >= P.need * aa then
				local value = t.value * (t.aa and P.aaBonus or 1)
				local score = value / (1 + aa / 100) / (1 + dist(wing.x, wing.z, t.x, t.z) / 3000)
				if not bestScore or score > bestScore then
					best, bestScore, bestAA = t, score, aa
				end
			end
		end
		return best, bestAA
	end

	-- the raiding party for the gunships. groups: { x, z, power } (their mobile ground groups near our
	-- base); power: the gunships' metal. The biggest party they beat (doctrine.air.huntNeed times its
	-- power) where its anti-air is weak; nil when none.
	function A.hunt(groups, aaAt, power)
		local P = D.air
		local best
		for _, g in ipairs(groups) do
			if power >= P.huntNeed * g.power and power >= P.need * aaAt(g.x, g.z) and (not best or g.power > best.power) then
				best = g
			end
		end
		return best
	end

	return A
end
