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

	-- what to build next. have: class -> count; enemyAir: the share of their units that fly; available:
	-- class -> true for what the plant can build (nil = everything). A scout first, then fighters up to
	-- their share (more when the enemy flies), then bombers and gunships. Classes the plant can't build
	-- are skipped (v21: a plant without scout planes built nothing but gunships, the scout never came).
	function A.want(have, enemyAir, available)
		local P = D.air
		local function ok(c)
			return not available or available[c]
		end
		if ok("scout") and (have.scout or 0) < P.scouts then
			return "scout"
		end
		local fighters, gunships, bombers = have.fighter or 0, have.gunship or 0, have.bomber or 0
		-- their air: fighters up to 1.5x its share; hardly any: a few for their scouts (a fixed 25% lost
		-- ~74 fighters a game to ground anti-air against an opponent that barely flew)
		local floorShare = (enemyAir or 0) < (P.noAirBelow or 0) and (P.fightersNoAir or P.fighters) or P.fighters
		local share = min(P.maxFighters, max(floorShare, (enemyAir or 0) * 1.5))
		if ok("fighter") and fighters < share * (fighters + gunships + bombers + 1) then
			return "fighter"
		end
		if ok("bomber") and (bombers < P.bombers * (gunships + bombers + 1) or not ok("gunship")) then
			return "bomber"
		end
		if ok("gunship") then
			return "gunship"
		end
		return ok("fighter") and "fighter" or nil
	end

	-- the classes a factory's options cover (class -> true) and how many: picks the plant that makes the
	-- whole air force, not a drone plant. options: list of defs
	function A.classes(options)
		local out, n = {}, 0
		for _, d in ipairs(options) do
			local c = A.class(d)
			if c and not out[c] then
				out[c], n = true, n + 1
			end
		end
		return out, n
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
