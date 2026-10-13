local F = dofile("widget/tests/fixtures.lua")

return {
	straight_when_clear = function()
		local tm = F.map()
		tm.update(0, {}, true)
		local path = T.load("sc_pathing")(tm)
		local wp, danger = path.route(200, 200, 3800, 200)
		T.ok(wp, "a route")
		T.eq(danger, 0, "no danger")
		T.ok(#wp <= 2, "one straight leg")
		T.eq(wp[#wp].x, 3800, "ends at the destination")
	end,
	goes_around_a_turret_line = function()
		local tm = F.map()
		for i = 0, 5 do
			tm.see(100 + i, 2, 2000, 1000 + i * 300, 0) -- a wall of turrets across the middle
		end
		tm.update(0, {}, true)
		local path = T.load("sc_pathing")(tm)
		T.ok(path.lineDanger(1000, 2000, 3000, 2000) > 0, "the straight line is covered")
		local wp, danger = path.route(1000, 2000, 3000, 2000, { avoid = 20 })
		T.ok(wp and #wp > 1, "a detour")
		T.eq(danger, 0, "around the wall, not through it")
	end,
}
