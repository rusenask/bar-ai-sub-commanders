local F = dofile("widget/tests/fixtures.lua")

local function squad(tm, members)
	return T.load("sc_squads")({ tm = tm, doctrine = F.doctrine }), members
end

return {
	summarize_weights_by_cost = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		local s = S.summarize({ { x = 0, z = 0, cost = 100 }, { x = 300, z = 0, cost = 300 }, { x = 3000, z = 3000, cost = 100 } })
		T.eq(s.power, 500)
		T.eq(s.n, 3)
		T.eq(s.together, 400, "the straggler isn't together")
		T.eq(S.summarize({}).power, 0)
	end,
	engage_only_when_stronger = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		for i = 1, 4 do
			tm.see(i, 1, 2000 + i * 10, 2000, 0) -- 400 metal of raiders
		end
		local strong = S.summarize({ { x = 1500, z = 2000, cost = 600 } })
		local weak = S.summarize({ { x = 1500, z = 2000, cost = 300 } })
		T.eq((S.decide(strong, 2000, 2000, 0)), "engage", "1.5x")
		T.eq((S.decide(weak, 2000, 2000, 0)), "hold", "0.75x away from home")
		T.eq((S.decide(weak, 2000, 2000, 0, { home = true })), "engage", "0.75x defending the base")
		T.eq((S.decide(weak, 2000, 2000, 0, { engaged = true, support = 0 })), "fallback", "0.75x in a fight away from home")
		T.eq((S.decide(weak, 2000, 2000, 0, { engaged = true, support = 100 })), "engage", "turret support holds it")
	end,
	reinforcements_nearby_count = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		for i = 1, 4 do
			tm.see(i, 1, 2000 + i * 10, 2000, 0) -- 400 metal at the target
		end
		local sq = S.summarize({ { x = 1500, z = 2000, cost = 600 } })
		T.eq((S.decide(sq, 2000, 2000, 0)), "engage", "1.5x against the target alone")
		for i = 5, 8 do
			tm.see(i, 1, 3200 + i * 10, 2000, 0) -- 400 more, 1200 away: they join the fight
		end
		local _, ratio = S.decide(sq, 2000, 2000, 0)
		T.ok(ratio < 1.2, "their army nearby counts: " .. ratio)
	end,
	regroup_when_spread = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		tm.see(1, 1, 2000, 2000, 0)
		local spread = S.summarize({ { x = 0, z = 0, cost = 300 }, { x = 1500, z = 1500, cost = 300 } })
		T.eq((S.decide(spread, 2000, 2000, 0)), "regroup")
	end,
	rally_stays_out_of_reach = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		tm.see(1, 4, 3000, 3000, 0) -- artillery: reach 1120
		tm.update(0, {}, true)
		local x, z = S.rally(500, 500, 3500, 3500)
		T.eq(tm.threat(x, z), 0, "out of reach")
		T.ok(x > 1000 and x < 2200, "but forward of home: " .. x)
		local nx = S.rally(500, 500, 3500, 3500)
		T.ok(nx, "deterministic")
	end,
	arc_faces_the_enemy = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		-- five units in a column south of an enemy at the origin, range 400
		local ms = {}
		for i = 1, 5 do
			ms[i] = { id = i, x = (i - 3) * 10, z = 1000 + i * 50, range = 400 }
		end
		local slots = S.arc(ms, 0, 0)
		local r = 400 * F.doctrine.engage.arc.hold
		local minX, maxX = 1e9, -1e9
		for i = 1, 5 do
			local p = slots[i]
			T.near(math.sqrt(p.x * p.x + p.z * p.z), r, 1e-6, "each at its firing distance")
			T.ok(p.z > 0, "on our side")
			minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
		end
		T.ok(maxX - minX > 200, "spread across, not a column")
		T.ok(slots[1].x < slots[5].x, "in the order they stand: no crossing")
	end,
	rally_without_intel_is_a_third_out = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		tm.update(0, {}, true)
		local x, z = S.rally(0, 0, 3000, 3000)
		T.near(x, 990, 1e-6)
	end,
	retreat_thresholds = function()
		local S = T.load("sc_squads")({ tm = F.map(), doctrine = F.doctrine })
		T.eq(S.retreatAt({ builder = true, cost = 100 }), 0.85)
		T.eq(S.retreatAt({ cost = 300 }), 0.5)
		T.eq(S.retreatAt({ cost = 20 }), nil, "cheap units fight on")
		T.eq(S.retreatAt({ commander = true, builder = true, cost = 1000 }), 0.6)
	end,
	pick_target_skips_what_it_cant_beat = function()
		local tm = F.map()
		local S = T.load("sc_squads")({ tm = tm, doctrine = F.doctrine })
		tm.see(1, 2, 3000, 3000, 0) -- a turret guards the far extractor
		local raid = S.summarize({ { x = 1000, z = 1000, cost = 200 } })
		local cands = {
			{ id = "a", x = 3000, z = 3050, value = 60, kind = "extractor" }, -- guarded: 200 vs 300
			{ id = "b", x = 2000, z = 1000, value = 60, kind = "extractor" }, -- free
			{ id = "c", x = 1200, z = 1000, value = 30, kind = "generator" }, -- free, closer, worth less
		}
		local t, ratio = S.pickTarget(raid, cands, 0, { prefer = { extractor = 2 } })
		T.eq(t.id, "b", "the free extractor beats the nearer generator (preferred, worth more)")
		T.ok(ratio > 100, "nothing there")
		T.eq(S.pickTarget(raid, { cands[1] }, 0), nil, "the guarded one is out")
	end,
}
