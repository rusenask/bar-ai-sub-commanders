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
}
