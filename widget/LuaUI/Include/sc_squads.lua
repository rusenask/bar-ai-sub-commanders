-- Sub-Commanders squads (design/engine.md): how an army fights as one. Pure decisions over the threat
-- map and doctrine; the widget turns them into orders.
--   summarize(members)          centre, power, how much of it is together
--   decide(squad, target, ...)  engage / regroup / hold / fall back, from local power vs threat
--   rally(home, enemy)          where to wait: on our side, out of reach of known enemy weapons
--   retreatAt(d)                health fraction at which a unit leaves the fight
--
-- usage: local Squads = VFS.Include("LuaUI/Include/sc_squads.lua", nil, VFS.RAW_FIRST)
--        local sq = Squads({ tm = threatMap, doctrine = D })
-- Pure Lua: unit-tested in widget/tests/squads_test.lua.

local max, sqrt = math.max, math.sqrt

return function(ctx)
	local tm, D = ctx.tm, ctx.doctrine
	local E = D.engage
	local S = {}

	-- members: list of { id, x, z, cost }. Returns { x, z, power, n, together }: the centre of the main
	-- body (the member with the most power within the cohesion radius, and those around it), the total
	-- power, and `together`, the power of the main body. Stragglers don't drag the centre away.
	function S.summarize(members)
		local power, r2 = 0, E.cohesion * E.cohesion
		local best, bestP
		for i = 1, #members do
			local m = members[i]
			power = power + m.cost
			local p = 0
			for j = 1, #members do
				local o = members[j]
				if (o.x - m.x) ^ 2 + (o.z - m.z) ^ 2 <= r2 then
					p = p + o.cost
				end
			end
			if not bestP or p > bestP then
				best, bestP = m, p
			end
		end
		if not best then
			return { x = nil, z = nil, power = 0, n = 0, together = 0 }
		end
		local sx, sz = 0, 0
		for i = 1, #members do
			local o = members[i]
			if (o.x - best.x) ^ 2 + (o.z - best.z) ^ 2 <= r2 then
				sx, sz = sx + o.x * o.cost, sz + o.z * o.cost
			end
		end
		return { x = sx / bestP, z = sz / bestP, power = power, n = #members, together = bestP }
	end

	-- our power against theirs around a target. support: our turrets' value around the target
	function S.ratio(squad, tx, tz, frame, support)
		local theirs = tm.enemyPower(tx, tz, E.radius, frame)
		-- their mobile forces just beyond the fight join it within seconds (doctrine.engage.reinforce):
		-- counted at a weight. Against hard a quarter of our engagements saw the odds fall under 0.7x within
		-- a minute: we judged the target alone and met their army
		local R = E.reinforce
		if R then
			local near = tm.enemyPower(tx, tz, E.radius, frame, { mobileOnly = true })
			local wide = tm.enemyPower(tx, tz, R.radius, frame, { mobileOnly = true })
			theirs = theirs + R.weight * max(wide - near, 0)
		end
		local ours = squad.together + (support or 0)
		return ours / max(theirs, 1), ours, theirs
	end

	-- what the squad should do about a target.
	-- opts.home: the target is in our base (we defend with turret support, down to doctrine.engage.defend)
	-- opts.vital: and at a factory or the commander (down to doctrine.engage.defendVital)
	-- opts.engaged: the squad is already fighting it (it holds down to doctrine.engage.hold)
	-- opts.support: our turrets' value near the target
	-- returns action ("engage", "regroup", "hold", "fallback"), ratio
	function S.decide(squad, tx, tz, frame, opts)
		opts = opts or {}
		if squad.power <= 0 then
			return "hold", 0
		end
		local ratio = S.ratio(squad, tx, tz, frame, opts.support)
		local need = opts.home and E.defend or (opts.engaged and E.hold or E.attack)
		if opts.home and opts.vital and E.defendVital then
			need = E.defendVital
		end
		if ratio >= need then
			-- spread out and not yet fighting: gather first, then go in together
			if not opts.engaged and not opts.home and squad.together < squad.power * 0.7 then
				return "regroup", ratio
			end
			return "engage", ratio
		end
		-- we were fighting and it turned against us: pull back before it becomes a rout
		if opts.engaged or opts.home then
			return "fallback", ratio
		end
		return "hold", ratio
	end

	-- the best target the squad beats: candidates are { x, z, value, kind, id }; a candidate counts only
	-- where the squad's power is at least `need` (default doctrine.engage.attack) times the threat around it.
	-- score = value x prefer[kind] / (1 + distance / 1500): worth more, closer, preferred kinds first.
	-- returns the candidate and its ratio, or nil
	function S.pickTarget(squad, candidates, frame, opts)
		opts = opts or {}
		local need, prefer = opts.need or E.attack, opts.prefer or {}
		local best, bestScore, bestRatio
		for _, c in ipairs(candidates) do
			local ratio = S.ratio(squad, c.x, c.z, frame)
			if ratio >= need then
				local d = sqrt((c.x - squad.x) ^ 2 + (c.z - squad.z) ^ 2)
				local score = c.value * (prefer[c.kind] or 1) / (1 + d / 1500)
				if not bestScore or score > bestScore then
					best, bestScore, bestRatio = c, score, ratio
				end
			end
		end
		return best, bestRatio
	end

	-- may this squad attack on its own (no threat in our areas, autonomy allows)?
	function S.canAttack(squad)
		return squad.together >= E.minAttack
	end

	-- where to wait: the safe edge of our side toward the enemy, pulled back a little; home if the
	-- whole way is under threat
	function S.rally(homeX, homeZ, enemyX, enemyZ)
		local sx, sz, tx = tm.front(homeX, homeZ, enemyX, enemyZ)
		if not tx then
			-- nothing known on the way: a third of the way out, not in their face
			return homeX + (enemyX - homeX) * 0.33, homeZ + (enemyZ - homeZ) * 0.33
		end
		local dx, dz = sx - homeX, sz - homeZ
		local len = sqrt(dx * dx + dz * dz)
		if len < 400 then
			return homeX, homeZ
		end
		local back = 350 / len
		return sx - dx * back, sz - dz * back
	end

	-- health fraction below which a unit of this kind leaves the fight (nil: it doesn't)
	function S.retreatAt(d)
		local R = D.retreat
		if d.commander then
			return R.commander
		elseif d.builder then
			return R.builder
		elseif d.cost >= R.minCost and not d.air then
			return R.fighter
		end
		return nil
	end

	-- an arc facing the enemy: where each engaging unit goes so the squad meets them as a concave, not a
	-- column converging on one point. members { id, x, z, range }, the enemy's centre (ex, ez). Each unit
	-- stands at its own firing distance from the enemy (range x E.arc.hold, at least E.arc.minDist),
	-- spaced E.arc.spacing apart across the line, in the order they already stand (no crossing paths),
	-- the arc no wider than E.arc.maxAngle radians. Returns { [id] = { x, z } }.
	function S.arc(members, ex, ez)
		local A = E.arc
		local n = #members
		if n == 0 then
			return {}
		end
		local cx, cz = 0, 0
		for _, m in ipairs(members) do
			cx, cz = cx + m.x, cz + m.z
		end
		cx, cz = cx / n, cz / n
		-- the direction from the enemy toward us, and across it
		local dx, dz = cx - ex, cz - ez
		local len = math.max(math.sqrt(dx * dx + dz * dz), 1)
		local fx, fz = dx / len, dz / len
		local px, pz = -fz, fx
		local order = {}
		for i, m in ipairs(members) do
			order[i] = { m = m, side = (m.x - cx) * px + (m.z - cz) * pz }
		end
		table.sort(order, function(a, b)
			return a.side < b.side
		end)
		local out = {}
		for i, o in ipairs(order) do
			local m = o.m
			local r = math.max((m.range or 0) * A.hold, A.minDist)
			-- this unit's angle on the arc around the enemy: spacing along the arc at radius r
			local step = math.min(A.spacing / r, A.maxAngle / math.max(n - 1, 1))
			local ang = (i - (n + 1) / 2) * step
			local c, s = math.cos(ang), math.sin(ang)
			-- rotate the toward-us direction by ang
			local ux, uz = fx * c + px * s, fz * c + pz * s
			out[m.id] = { x = ex + ux * r, z = ez + uz * r }
		end
		return out
	end

	return S
end
