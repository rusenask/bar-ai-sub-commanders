local F = dofile("widget/tests/fixtures.lua")

local defs = {
	[1] = { mobile = true, builder = true, cost = 110, kind = "constructor" },
	[2] = { mobile = true, combat = true, armed = true, cost = 45, speed = 120, kind = "raider" },
	[3] = { mobile = true, combat = true, armed = true, cost = 60, speed = 90, kind = "raider" },
	[4] = { mobile = true, combat = true, armed = true, cost = 150, speed = 50, kind = "assault" },
	[5] = { mobile = true, combat = true, armed = true, cost = 220, speed = 45, kind = "skirmisher" },
	[6] = { mobile = true, combat = true, armed = true, cost = 400, speed = 40, kind = "heavy" },
	[7] = { mobile = true, armed = true, aaOnly = true, cost = 120, kind = "mobile anti-air" },
	[8] = { mobile = true, combat = true, armed = true, cost = 30, speed = 150, kind = "scout" },
	[9] = { mobile = true, combat = true, armed = true, cost = 70, speed = 110, kind = "hover raider" },
}
local LAB = { 1, 2, 3, 4, 5, 6, 7, 8 }

local function prod()
	return T.load("sc_production")({ defs = defs, doctrine = F.doctrine })
end

return {
	signature_unit_wins_its_category = function()
		local P = prod()
		local old = F.doctrine.production.prefer
		F.doctrine.production.prefer = { tzar = 3 }
		local d = { [1] = defs[6], [2] = { name = "tzar", mobile = true, combat = true, armed = true, cost = 350, speed = 39, kind = "heavy" } }
		local P2 = T.load("sc_production")({ defs = { [6] = defs[6], [10] = d[2] }, doctrine = F.doctrine })
		local id = P2.pick({ 6, 10 }, {}, 100, {}, { category = "heavy" })
		T.eq(id, 10, "the preferred heavy, though cheaper")
		F.doctrine.production.prefer = old
		local id2 = P.pick({ 6 }, {}, 100, {}, { category = "heavy" })
		T.eq(id2, 6)
	end,
	categories = function()
		local P = prod()
		T.eq(P.category(defs[1]), "constructor")
		T.eq(P.category(defs[9]), "raider", "hover raiders are raiders")
		T.eq(P.category(defs[7]), "mobile anti-air")
		T.eq(P.category(defs[8]), "scout")
		T.eq(P.category({ mobile = false, armed = true }), nil, "turrets aren't produced")
	end,
	tier_mix_drives_an_empty_army = function()
		local P = prod()
		local id, cat = P.pick(LAB, {}, 5, {})
		T.eq(cat, "raider", "low income: raiders first (largest share)")
		T.eq(id, 2, "the fastest raider")
	end,
	fills_the_biggest_gap = function()
		local P = prod()
		local _, cat = P.pick(LAB, { raider = 5, assault = 0, constructor = 2 }, 5, {})
		T.eq(cat, "assault")
	end,
	counters_heavy_with_heavy_and_skirmishers = function()
		local P = prod()
		local want = P.desired(30, { heavy = 10 })
		T.ok(want.heavy > P.desired(30, {}).heavy, "more heavy against heavies")
		T.ok(want.raider < P.desired(30, {}).raider, "fewer raiders")
		T.ok(P.desired(70, {})["mobile anti-air"] > 0.05, "a big army brings its own anti-air")
		T.ok(P.desired(70, {}).artillery > P.desired(45, {}).artillery, "and more artillery for turret lines")
		local sum = 0
		for _, v in pairs(P.desired(70, {})) do
			sum = sum + v
		end
		T.near(sum, 1, 1e-6, "shares add up")
	end,
	anti_air_only_against_air = function()
		local P = prod()
		T.eq(P.desired(30, {})["mobile anti-air"], 0)
		T.ok(P.desired(30, { gunship = 5, raider = 5 })["mobile anti-air"] > 0)
	end,
	cap_and_combat_only = function()
		local P = prod()
		local id, cat = P.pick(LAB, { raider = 10, assault = 10, skirmisher = 0, heavy = 0 }, 30, {}, { cap = 250, combatOnly = true })
		T.ok(cat ~= "constructor")
		T.ok(defs[id].cost <= 250, "within the cap")
	end,
	strongest_and_fastest_in_turn = function()
		local d = {
			[4] = defs[4],
			[10] = { mobile = true, combat = true, armed = true, cost = 220, speed = 40, kind = "assault" },
			[11] = { mobile = true, combat = true, armed = true, cost = 220, speed = 58, kind = "assault" },
			[12] = { mobile = true, combat = true, armed = true, cost = 120, speed = 85, kind = "assault" },
		}
		local P = T.load("sc_production")({ defs = d, doctrine = F.doctrine })
		local got = {}
		for _ = 1, 4 do
			got[P.pick({ 4, 10, 11, 12 }, {}, 30, {}, { category = "assault" })] = true
		end
		T.ok(got[12], "the fastest (the Incisor), though cheapest")
		T.ok(got[10] or got[11], "and the strongest")
		T.ok(not got[4], "nothing in between")
	end,
	forced_category = function()
		local P = prod()
		local id, cat = P.pick(LAB, {}, 5, {}, { category = "constructor" })
		T.eq(cat, "constructor")
		T.eq(id, 1)
	end,
	opening_order = function()
		local P = prod()
		T.eq(P.opening(1), "constructor")
		T.eq(P.opening(3), "raider")
		T.eq(P.opening(99), nil)
	end,
	turret_roles = function()
		local P = prod()
		T.eq(P.turretRole({ staticDef = true, cost = 80, range = 400 }), "light")
		T.eq(P.turretRole({ staticDef = true, cost = 320, range = 450 }), "heavy")
		T.eq(P.turretRole({ staticDef = true, cost = 900, range = 1100 }), "long")
		T.eq(P.turretRole({ staticDef = true, aaOnly = true, cost = 150, range = 800 }), nil, "anti-air is its own")
		T.eq(P.turretRole({ mobile = true, cost = 100 }), nil)
	end,
	turret_mix_per_area = function()
		local P = prod()
		local late = 30 * 60 * 10
		T.eq(P.turretNeed({}, 1, 0), "light", "an empty area starts with light turrets")
		T.eq(P.turretNeed({ light = 3 }, 1, 0), "heavy")
		T.eq(P.turretNeed({ light = 3, heavy = 2 }, 1, 0), nil, "no long-range turrets early")
		T.eq(P.turretNeed({ light = 3, heavy = 2 }, 1, late), "long", "then artillery")
		T.eq(P.turretNeed({ light = 3, heavy = 2, long = 1 }, 1, late), nil, "full mix")
		T.eq(P.turretNeed({ light = 3, heavy = 2, long = 1 }, 2, late), "light", "a higher density wants more of each")
		T.eq(P.turretNeed({ light = 1 }, 1, 0, { light = true }), "light", "only what it can build")
		T.eq(P.turretNeed({}, 1, late, { long = true }), "long")
		-- a big economy: more heavy and long-range turrets per area, not more light ones
		T.eq(P.turretNeed({ light = 3, heavy = 2, long = 1 }, 1, late, nil, 40), nil, "not below 50 metal/s: production first")
		T.eq(P.turretNeed({ light = 3, heavy = 2, long = 1 }, 1, late, nil, 100), "heavy", "rich: the mix grows")
		T.eq(P.turretNeed({ light = 3, heavy = 4, long = 2 }, 1, late, nil, 100), nil, "2x heavy and long at 100 metal/s")
		T.eq(P.mixScale("light", 500), 1)
		T.eq(P.mixScale("heavy", 1000), 4, "capped")
	end,
}
