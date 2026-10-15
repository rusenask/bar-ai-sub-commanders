-- Sub-Commanders forward firebases (design/engine.md "Firebases"): layered turret groups that creep into
-- territory. A firebase starts just past our frontier toward the enemy, grows in layers (light turrets,
-- a radar, a heavy, anti-air once they fly, a long-range turret later); once complete the next one goes
-- further out from the new frontier (territory follows our structures), so the line creeps forward and
-- the army has a strong point to fall back on and push from. BARbarian hard grows every radar into one.
--   site(pickets, home, enemy, bases, threatAt, metalAt)  where the next firebase goes ({ x, z } or nil)
--   nextLayer(have, airShare, minute, income)    the role a firebase builds next, or nil (complete)
--   established(have, airShare, minute, income)  its core (the first `core` layers) stands: the next may go
--   offset(role)                                  where in the base a role stands (forward, back)
--
-- usage: local F = VFS.Include("LuaUI/Include/sc_firebase.lua", nil, VFS.RAW_FIRST)({ doctrine = D })
-- Pure Lua: unit-tested in widget/tests/firebase_test.lua.

local sqrt, max = math.sqrt, math.max

return function(ctx)
	local D = ctx.doctrine
	local F = {}

	local function d2(ax, az, bx, bz)
		return (ax - bx) ^ 2 + (az - bz) ^ 2
	end

	-- pickets: the territory's frontier points { x, z, score } (sc_territory.pickets). From each, a point
	-- `step` further toward the enemy (or half that, or the picket itself) that no known enemy weapon
	-- covers, no nearer than `spacing` to another firebase, and no further from home than `reach` of the
	-- way to their base. The best by the picket's score times how far forward it is, times
	-- (1 + metalWeight x free metal spots near it: metalAt(x, z) -> count; creeping is for territory's metal)
	function F.site(pickets, home, enemy, bases, threatAt, metalAt)
		local C = D.firebase
		local full = max(sqrt(d2(home.x, home.z, enemy.x, enemy.z)), 1)
		local ax, az = (enemy.x - home.x) / full, (enemy.z - home.z) / full
		local best, bestScore
		for _, p in ipairs(pickets) do
			local dx, dz = enemy.x - p.x, enemy.z - p.z
			local len = max(sqrt(dx * dx + dz * dz), 1)
			for _, step in ipairs({ C.step, C.step * 0.5, 0 }) do
				local x, z = p.x + dx / len * step, p.z + dz / len * step
				local forward = (x - home.x) * ax + (z - home.z) * az
				local ok = forward <= C.reach * full and threatAt(x, z) <= 0
				for _, b in ipairs(bases) do
					if ok and d2(x, z, b.x, b.z) < C.spacing * C.spacing then
						ok = false
					end
				end
				if ok then
					local score = (p.score or 1) * (1 + max(forward, 0) / full) * (1 + (C.metalWeight or 0) * (metalAt and metalAt(x, z) or 0))
					if not bestScore or score > bestScore then
						best, bestScore = { x = x, z = z }, score
					end
					break
				end
			end
		end
		return best
	end

	-- have: counts of what stands (or is planned) in the firebase by role: light, heavy, long, aa, radar.
	-- The doctrine's layers in order ({ role, count, air = share, minute =, income = }): the first not yet
	-- met whose condition holds
	function F.nextLayer(have, airShare, minute, income)
		for _, L in ipairs(D.firebase.layers) do
			local role, count = L[1], L[2]
			local due = (not L.air or (airShare or 0) >= L.air) and (not L.minute or minute >= L.minute) and (not L.income or income >= L.income)
			if due and (have[role] or 0) < count then
				return role
			end
		end
		return nil
	end

	-- the first doctrine.firebase.core layers met (those whose conditions hold): established, the next one
	-- may be founded while the rest is built (v1-v5 waited for every layer: one site short of its long-range
	-- turret froze the line)
	function F.established(have, airShare, minute, income)
		local core = D.firebase.core
		if not core then
			return F.nextLayer(have, airShare, minute, income) == nil
		end
		for i, L in ipairs(D.firebase.layers) do
			if i > core then
				break
			end
			local due = (not L.air or (airShare or 0) >= L.air) and (not L.minute or minute >= L.minute) and (not L.income or income >= L.income)
			if due and (have[L[1]] or 0) < L[2] then
				return false
			end
		end
		return true
	end

	-- how far toward the enemy (+) or back (-) a role stands from the firebase's centre
	function F.offset(role)
		return D.firebase.offsets[role] or 0
	end

	return F
end
