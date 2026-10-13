local F = dofile("widget/tests/fixtures.lua")

local function com()
	return T.load("sc_commander")({ doctrine = F.doctrine })
end

return {
	auto_modes = function()
		local C = com()
		local s = { phase = "expand", threatNear = 0, health = 1, full = true }
		T.eq(C.mode("auto", "careful", s), "builder")
		s.threatNear = 300
		T.eq(C.mode("auto", "careful", s), "defender", "enemies near")
		s.threatNear, s.phase = 0, "defend"
		T.eq(C.mode("auto", "careful", s), "defender", "the team defends")
		s.phase = "push"
		T.eq(C.mode("auto", "careful", s), "builder", "careful never goes to the front")
		T.eq(C.mode("auto", "bold", s), "frontline", "bold does, when pushing")
		s.health = 0.6
		T.eq(C.mode("auto", "bold", s), "builder", "not when hurt")
		T.eq(C.mode("defender", "careful", { phase = "expand", threatNear = 0, health = 1 }), "defender", "an explicit mode wins")
	end,
	dgun_targets = function()
		local C = com()
		local enemies = {
			{ id = 1, x = 100, z = 0, cost = 40, armed = true }, -- too cheap
			{ id = 2, x = 150, z = 0, cost = 300, armed = true },
			{ id = 3, x = 120, z = 0, cost = 900, armed = true },
			{ id = 4, x = 600, z = 0, cost = 2000, armed = true }, -- out of range
			{ id = 5, x = 50, z = 0, cost = 5000, armed = false }, -- a building
		}
		T.eq(C.dgunTarget(enemies, { 0, 0 }, 2000, "careful").id, 3, "the most expensive armed one in range")
		T.eq(C.dgunTarget(enemies, { 0, 0 }, 100, "careful"), nil, "not without energy")
		T.eq(C.dgunTarget({ enemies[1] }, { 0, 0 }, 2000, "careful"), nil, "careful doesn't waste it on 40 metal")
		T.eq(C.dgunTarget({ { id = 6, x = 10, z = 0, cost = 100, armed = true } }, { 0, 0 }, 2000, "bold").id, 6, "bold does on 100")
	end,
	home_range = function()
		local C = com()
		T.ok(C.inRange(1000, 0, { 0, 0 }, "careful"))
		T.ok(not C.inRange(2500, 0, { 0, 0 }, "careful"))
		T.ok(C.inRange(2500, 0, { 0, 0 }, "bold"))
	end,
}
