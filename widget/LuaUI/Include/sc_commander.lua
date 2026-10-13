-- Sub-Commanders commander (design/engine.md): modes and personality for the one unit whose death loses
-- the game. Modes, after how strong players use it:
--   builder    the opening (first extractors, energy, the first lab) and expansion near home
--   defender   stays in turret cover at home and D-guns raiders that come in
--   frontline  follows the army at a safe distance and D-guns high-value targets (bold personality, the
--              team pushing, full health)
--   auto       builder in the opening and while expanding, defender when enemies are near or the team
--              defends, frontline only when the plan is to push and the personality allows it
-- Personality (doctrine.commander.careful / bold): retreat health, the cheapest unit worth a D-gun shot,
-- how far from home it may go.
--
-- usage: local Commander = VFS.Include("LuaUI/Include/sc_commander.lua", nil, VFS.RAW_FIRST)
--        local com = Commander({ doctrine = D })
--        com.mode("auto", "careful", { phase = "expand", threatNear = 0, health = 1, full = true })
--        com.dgunTarget(enemies, { x, z }, energy, "careful")
-- Pure Lua: unit-tested in widget/tests/commander_test.lua.

local sqrt = math.sqrt

return function(ctx)
	local D = ctx.doctrine
	local C = { MODES = { "auto", "builder", "defender", "frontline" }, PERSONALITIES = { "careful", "bold" } }

	function C.personality(name)
		return D.commander[name or "careful"] or D.commander.careful
	end

	-- s = { phase (team plan), threatNear (enemy metal near the commander), health (fraction), full (full
	-- autonomy) }
	function C.mode(setting, personality, s)
		local p = C.personality(personality)
		if setting and setting ~= "auto" then
			return setting
		end
		if s.threatNear > 0 or s.phase == "defend" then
			return "defender"
		end
		if s.phase == "push" and p.frontline and s.full and s.health >= 0.8 then
			return "frontline"
		end
		return "builder"
	end

	-- the best D-gun target: an armed enemy in range worth at least the personality's minimum, the most
	-- expensive first (the shot costs ~500 energy and kills almost anything). enemies: { id, x, z, cost,
	-- armed }; com: { x, z }; returns the enemy or nil
	function C.dgunTarget(enemies, com, energy, personality)
		local p = C.personality(personality)
		if energy < D.commander.dgunEnergy then
			return nil
		end
		local r2 = D.commander.dgunRange ^ 2
		local best
		for _, e in ipairs(enemies) do
			if e.armed and e.cost >= p.dgunMin and (e.x - com[1]) ^ 2 + (e.z - com[2]) ^ 2 <= r2 then
				if not best or e.cost > best.cost then
					best = e
				end
			end
		end
		return best
	end

	-- may the commander be at (x, z), this far from home?
	function C.inRange(x, z, home, personality)
		local p = C.personality(personality)
		local dx, dz = x - home[1], z - home[2]
		return sqrt(dx * dx + dz * dz) <= p.homeRange
	end

	return C
end
