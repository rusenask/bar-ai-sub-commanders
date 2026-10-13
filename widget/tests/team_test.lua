local F = dofile("widget/tests/fixtures.lua")

local function team()
	return T.load("sc_team")({ doctrine = F.doctrine })
end

return {
	post_merges_and_expires = function()
		local t = team()
		local a = t.post({ kind = "defend", from = 2, x = 1000, z = 1000, need = 300 }, 0)
		local b = t.post({ kind = "defend", from = 2, x = 1200, z = 1000, need = 800 }, 30)
		T.eq(a, b, "the same request, refreshed")
		T.eq(#t.requests, 1)
		T.eq(a.need, 800, "the bigger need")
		t.post({ kind = "defend", from = 2, x = 5000, z = 5000, need = 100 }, 30)
		t.post({ kind = "constructor", from = 3 }, 30)
		T.eq(#t.requests, 3, "elsewhere and another kind are separate")
		t.expire(30 + F.doctrine.team.requestLife + 1)
		T.eq(#t.requests, 0, "nobody refreshed them")
	end,
	open_and_nearest = function()
		local t = team()
		t.post({ kind = "defend", from = 1, x = 1000, z = 1000, need = 300 }, 0)
		t.post({ kind = "defend", from = 2, x = 4000, z = 4000, need = 900 }, 0)
		T.eq(t.open("defend")[1].need, 900, "neediest first")
		local r, d = t.nearest("defend", 1100, 1000)
		T.eq(r.from, 1)
		T.near(d, 100, 1e-6)
		T.eq(#t.open("constructor"), 0)
	end,
	phases = function()
		local t = team()
		local base = { minute = 3, income = 10, armyPower = 500, enemyArmy = 0, baseUnderAttack = 0, techLab = false, techReady = false }
		T.eq(t.phase(base).phase, "opening")
		base.minute = 10
		T.eq(t.phase(base).phase, "expand")
		base.techReady = true
		T.eq(t.phase(base).phase, "tech")
		base.armyPower, base.enemyArmy = 6000, 3000
		T.eq(t.phase(base).phase, "push", "2x their known army")
		base.enemyArmy = 8000
		T.eq(t.phase(base).phase, "defend", "they outweigh us")
		T.ok(not t.plan.base, "raids go on: the base itself isn't attacked")
		base.enemyArmy, base.baseUnderAttack = 0, 1000
		T.eq(t.phase(base).phase, "defend", "the base is under attack")
		T.ok(t.plan.why:find("attack"), "with a reason")
		T.ok(t.plan.base, "raids pause")
	end,
}
