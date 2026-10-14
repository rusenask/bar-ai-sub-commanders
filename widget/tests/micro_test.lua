local F = dofile("widget/tests/fixtures.lua")

local function micro()
	return T.load("sc_micro")({ doctrine = F.doctrine })
end

return {
	rules_by_kind_and_style = function()
		local M = micro()
		T.eq(M.rule("heavy").kite, false, "heavies hold the front")
		T.near(M.rule("skirmisher").kite, 0.6, 1e-9)
		T.near(M.rule("skirmisher", "skirmish").kite, 0.8, 1e-9, "skirmish kites earlier")
		T.ok(M.rule("skirmisher", "siege").siege, "siege: skirmishers shell structures")
		T.ok(not M.rule("skirmisher").siege)
		T.near(M.rule("hover skirmisher").hold, 0.72, 1e-9, "hovers are their kind")
		T.eq(M.rule("whatever").kite, false, "default")
	end,
	kiting = function()
		local M = micro()
		local r = M.rule("skirmisher")
		T.near(M.kite(r, 600, 300, 200), 432, 1e-9, "a short-range enemy at half range: back to where pros fight from")
		T.eq(M.kite(r, 600, 500, 200), nil, "far enough")
		T.eq(M.kite(r, 400, 150, 100), nil, "short-range skirmishers don't kite (pros' rarely did)")
		T.eq(M.kite(r, 600, 300, 650), nil, "they outrange us: don't run, fight")
		T.eq(M.kite(M.rule("heavy"), 300, 50, 100), nil)
	end,
	raids = function()
		local M = micro()
		T.ok(M.raids("raider", "balanced"))
		T.ok(not M.raids("skirmisher", "balanced"))
		T.ok(M.raids("skirmisher", "harass"), "harass: rockets and railguns raid")
	end,
	auto_style = function()
		local M = micro()
		local s = { phase = "expand", enemyStatic = 0.1, enemyFront = 0.2, ourRanged = 0.1 }
		T.eq(M.auto(s), "balanced")
		s.ourRanged = 0.3
		T.eq(M.auto(s), "harass")
		s.enemyFront = 0.6
		s.ourRanged = 0.4
		T.eq(M.auto(s), "skirmish")
		s.enemyStatic = 0.5
		T.eq(M.auto(s), "siege")
		s.phase = "defend"
		T.eq(M.auto(s), "hold")
	end,
	focus_fire = function()
		local M = micro()
		local t = M.focusTarget({
			{ id = 1, hp = 900, cost = 300, armed = true }, -- healthy
			{ id = 2, hp = 50, cost = 300, armed = true }, -- nearly dead: finish it
			{ id = 3, hp = 20, cost = 60, armed = false }, -- a nearly dead extractor
		})
		T.eq(t.id, 2)
		T.eq(M.focusTarget({}), nil)
	end,
}
