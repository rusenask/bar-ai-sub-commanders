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
	fire_control = function()
		local M = micro()
		local focus = F.doctrine.micro.focus
		local saved = { overkill = focus.overkill, killTime = focus.killTime }
		focus.overkill, focus.killTime = 1.2, 2
		-- three shooters with 100 dps each, two targets in reach of all: the best one needs two of them
		-- (hp 300 x 1.2 = 360 <= 2 x 100 x 2 s), the third spills over
		local shooters = {
			{ id = 1, x = 0, z = 0, range = 500, dps = 100 },
			{ id = 2, x = 10, z = 0, range = 500, dps = 100 },
			{ id = 3, x = 20, z = 0, range = 500, dps = 100 },
		}
		local targets = {
			{ id = 10, x = 300, z = 0, hp = 300, cost = 300, armed = true },
			{ id = 11, x = 300, z = 50, hp = 900, cost = 300, armed = true },
		}
		local a = M.allocate(shooters, targets)
		local on10, on11 = 0, 0
		for _, t in pairs(a) do
			on10 = on10 + (t == 10 and 1 or 0)
			on11 = on11 + (t == 11 and 1 or 0)
		end
		T.eq(on10, 2)
		T.eq(on11, 1)
		-- one shooter reaches only the second target: it takes it, the others keep the first
		shooters[3].x = 800
		targets[2].x = 1200
		shooters[3].range = 500
		a = M.allocate(shooters, targets)
		T.eq(a[3], 11)
		T.eq(a[1], 10)
		-- planes only for anti-air, ground for the rest
		a = M.allocate({ { id = 1, x = 0, z = 0, range = 500, dps = 100 } }, { { id = 20, x = 10, z = 0, hp = 100, cost = 50, air = true } })
		T.eq(a[1], nil)
		-- no overkill limit: everyone on the best
		focus.overkill = false
		shooters[3].x, targets[2].x = 20, 300
		a = M.allocate(shooters, targets)
		T.eq(a[1], 10)
		T.eq(a[2], 10)
		T.eq(a[3], 10)
		focus.overkill, focus.killTime = saved.overkill, saved.killTime
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
