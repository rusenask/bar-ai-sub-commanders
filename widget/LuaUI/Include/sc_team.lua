-- Sub-Commanders team planning (design/engine.md, "swarm"): a blackboard every sub-commander reads and
-- writes.
--   plan     the team's phase: opening, expand, tech, defend, push (from the game's state)
--   requests what sub-commanders ask of each other: defend a place, a constructor, combat production
-- Others answer by role (the Army defends, Defense builds turrets, the Economy sends a constructor or
-- puts its factory on combat units). Requests expire; ones of the same kind for the same place merge.
--
-- usage: local Team = VFS.Include("LuaUI/Include/sc_team.lua", nil, VFS.RAW_FIRST)
--        local team = Team({ doctrine = D })
--        team.post({ kind = "defend", from = 2, x = 100, z = 200, need = 800 }, frame)
--        team.phase({ minute = 12, income = 30, armyPower = 5000, enemyArmy = 3000, ... })
-- Pure Lua: unit-tested in widget/tests/team_test.lua.

local max, sqrt = math.max, math.sqrt

return function(ctx)
	local D = ctx.doctrine
	local P = D.team
	local T = { requests = {}, nextID = 1, plan = { phase = "opening", why = "the first minutes" } }

	-- post (or refresh) a request. req: { kind, from, x, z, need, note }. Returns the request.
	function T.post(req, frame)
		for _, r in ipairs(T.requests) do
			local near = not req.x or not r.x or (r.x - req.x) ^ 2 + (r.z - req.z) ^ 2 < P.mergeRadius ^ 2
			if r.kind == req.kind and r.from == req.from and near then
				r.frame, r.need, r.note = frame, max(r.need or 0, req.need or 0), req.note or r.note
				if req.x then
					r.x, r.z = req.x, req.z
				end
				return r
			end
		end
		req.id, req.frame, req.created = T.nextID, frame, frame
		T.nextID = T.nextID + 1
		T.requests[#T.requests + 1] = req
		return req
	end

	-- drop requests nobody refreshed within doctrine.team.requestLife
	function T.expire(frame)
		for i = #T.requests, 1, -1 do
			if frame - T.requests[i].frame > P.requestLife then
				table.remove(T.requests, i)
			end
		end
	end

	-- open requests of a kind (all kinds when nil), the neediest first
	function T.open(kind)
		local out = {}
		for _, r in ipairs(T.requests) do
			if not kind or r.kind == kind then
				out[#out + 1] = r
			end
		end
		table.sort(out, function(a, b)
			return (a.need or 0) > (b.need or 0)
		end)
		return out
	end

	-- the open request of a kind nearest to (x, z)
	function T.nearest(kind, x, z)
		local best, bestD
		for _, r in ipairs(T.requests) do
			if r.kind == kind and r.x then
				local d = (r.x - x) ^ 2 + (r.z - z) ^ 2
				if not bestD or d < bestD then
					best, bestD = r, d
				end
			end
		end
		return best, bestD and sqrt(bestD)
	end

	-- the team's phase from the game's state:
	-- s = { minute, income, armyPower, enemyArmy (strongest known enemy group, metal), baseUnderAttack
	--       (enemy metal inside our base), techLab (we have one), techReady (conditions for tier 2) }
	function T.phase(s)
		local plan
		if s.baseUnderAttack >= P.defendBase or (s.enemyArmy > 0 and s.enemyArmy > s.armyPower * P.defendRatio) then
			local base = s.baseUnderAttack >= P.defendBase
			plan = { phase = "defend", base = base, why = base and "the base is under attack" or "a known enemy army outweighs ours" }
		elseif s.minute < P.openingMinutes then
			plan = { phase = "opening", why = "the first minutes: economy and raiders" }
		elseif s.armyPower >= P.pushMin and s.armyPower >= max(s.enemyArmy, 1) * P.pushRatio then
			plan = { phase = "push", why = "our army clearly outweighs everything we know of theirs" }
		elseif s.techReady and not s.techLab then
			plan = { phase = "tech", why = "the economy carries tier 2" }
		else
			plan = { phase = "expand", why = "take safe metal, grow production" }
		end
		T.plan = plan
		return plan
	end

	return T
end
