-- Sub-Commanders strategic structures (design/engine.md, docs/research/units.md): the decisions behind
-- long-range plasma cannons, Juno, anti-nukes, shields and resurrection; the widget builds and orders.
--   lrpcSite(home, enemy, range, threatAt)  where a long-range cannon reaches their base from safety
--   lrpcTarget(gun, targets, shields)       what a cannon shoots: their cannons and silos first, then
--                                           labs and big power, never what their shields cover
--   junoTarget(cands, aoe, minTargets)      where one Juno missile clears the most radar, jammers, mines
--   rezTarget(bot, wrecks)                  the wreck worth resurrecting
--
-- usage: local Strategic = VFS.Include("LuaUI/Include/sc_strategic.lua", nil, VFS.RAW_FIRST)
--        local S = Strategic({ doctrine = D })
-- Pure Lua: unit-tested in widget/tests/strategic_test.lua.

local sqrt, max = math.sqrt, math.max

return function(ctx)
	local D = ctx.doctrine
	local S = {}

	local function d2(ax, az, bx, bz)
		return (ax - bx) ^ 2 + (az - bz) ^ 2
	end

	-- walking from home toward their base, the first point that reaches it (within reach x range) and
	-- that no known enemy weapon covers. home, enemy: { x, z }. threatAt(x, z) -> number. Returns x, z or
	-- nil (no safe place reaches)
	function S.lrpcSite(home, enemy, range, threatAt)
		local L = D.strategic.lrpc
		local dx, dz = enemy.x - home.x, enemy.z - home.z
		local len = sqrt(dx * dx + dz * dz)
		if len < 1 then
			return nil
		end
		local reach = range * (L.reach or 0.9)
		for t = 0, len, 128 do
			local x, z = home.x + dx / len * t, home.z + dz / len * t
			if d2(x, z, enemy.x, enemy.z) <= reach * reach and threatAt(x, z) <= 0 then
				return x, z
			end
		end
		return nil
	end

	-- targets: { id, x, z, cost, role } with role one of "lrpc", "nuke", "antinuke", "factory", "energy",
	-- "extractor", "turret", "shield", "other". shields: their shield generators { x, z, r }. A target
	-- under a shield is skipped (the shot only drains it). Score: cost x the role's weight (doctrine
	-- .strategic.lrpc.weights), a little less the farther it is. Returns the target or nil
	function S.lrpcTarget(gun, targets, shields)
		local W = D.strategic.lrpc.weights
		local best, bestScore
		local r2 = gun.range * gun.range
		for _, t in ipairs(targets) do
			local dd = d2(gun.x, gun.z, t.x, t.z)
			if dd <= r2 then
				local covered = false
				for _, s in ipairs(shields or {}) do
					if d2(t.x, t.z, s.x, s.z) <= s.r * s.r then
						covered = true
						break
					end
				end
				if not covered then
					local score = (t.cost or 0) * (W[t.role] or W.other or 1) / (1 + sqrt(dd) / gun.range * 0.3)
					if score > 0 and (not bestScore or score > bestScore) then
						best, bestScore = t, score
					end
				end
			end
		end
		return best
	end

	-- cands: their radar, jammers, cameras and mines { x, z, cost, weight (default 1; a jammer counts 2:
	-- it hides an army) }. The centre (one of them) whose aoe holds the most weight (then value), if at
	-- least minTargets. Returns x, z, n or nil
	function S.junoTarget(cands, aoe, minTargets)
		local bestN, bestV, bx, bz = 0, 0, nil, nil
		local a2 = aoe * aoe
		for _, c in ipairs(cands) do
			local n, v = 0, 0
			for _, o in ipairs(cands) do
				if d2(c.x, c.z, o.x, o.z) <= a2 then
					n, v = n + (o.weight or 1), v + (o.cost or 0)
				end
			end
			if n > bestN or (n == bestN and v > bestV) then
				bestN, bestV, bx, bz = n, v, c.x, c.z
			end
		end
		if bx and bestN >= (minTargets or 1) then
			return bx, bz, bestN
		end
		return nil
	end

	-- wrecks: { id, x, z, value } that can be resurrected. The most metal for the walk: value / (1 +
	-- distance / 1000). Returns the wreck or nil
	function S.rezTarget(bot, wrecks)
		local best, bestScore
		for _, w in ipairs(wrecks) do
			local score = (w.value or 0) / (1 + sqrt(d2(bot.x, bot.z, w.x, w.z)) / 1000)
			if score > 0 and (not bestScore or score > bestScore) then
				best, bestScore = w, score
			end
		end
		return best
	end

	return S
end
