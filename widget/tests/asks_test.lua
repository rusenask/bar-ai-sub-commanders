local F = dofile("widget/tests/fixtures.lua")

local function asks()
	return T.load("sc_asks")({ doctrine = F.doctrine })
end

local defs = {
	[1] = { name = "con1", mobile = true, builder = true, cost = 60, tech = 1, options = { 1, 2 } },
	[2] = { name = "con2", mobile = true, builder = true, cost = 200, tech = 2, options = { 1, 2, 3, 4, 5 } },
	[3] = { name = "infestor", mobile = true, builder = true, cost = 150, tech = 2, options = { 3 } },
	[4] = { name = "tank", mobile = true, combat = true, cost = 300, kind = "heavy" },
	[5] = { name = "flea", mobile = true, combat = true, cost = 20, kind = "raider" },
	[6] = { name = "peep", mobile = true, air = true, cost = 50, kind = "scout plane" },
	[7] = { name = "oracle", mobile = true, air = true, cost = 175, kind = "scout plane", mobileSonar = true },
	[8] = { name = "flak", mobile = true, combat = true, aaOnly = true, cost = 180, kind = "mobile anti-air" },
	[9] = { name = "goliath", mobile = true, combat = true, cost = 1500, kind = "heavy" },
}

return {
	matches_by_kind_or_name = function()
		local A = asks()
		T.ok(A.matches("constructor", defs[1]))
		T.ok(not A.matches("constructor2", defs[1]), "tier 1")
		T.ok(A.matches("combat", defs[4]))
		T.ok(not A.matches("combat", defs[8]), "anti-air isn't 'combat'")
		T.ok(A.matches("antiair", defs[8]))
		T.ok(A.matches("radarplane", defs[6]))
		T.ok(A.matches("tank", defs[4]), "by the unit's name")
		T.ok(not A.matches("tank", defs[5]))
	end,
	pick_cheap_best_or_most_options = function()
		local A = asks()
		local all = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
		T.eq(A.pick("constructor", all, defs, 1000), 1, "the cheapest")
		T.eq(A.pick("constructor2", all, defs, 1000), 2, "the real T2 one, not the Infestor")
		T.eq(A.pick("combat", all, defs, 1000), 4, "the dearest it can afford")
		T.eq(A.pick("combat", all, defs, 2000), 9)
		T.eq(A.pick("radarplane", all, defs, 1000), 6)
		T.eq(A.pick("radarplane", all, defs, 1000, { sonar = true }), 7, "sonar first on water")
		T.eq(A.pick("sub", all, defs, 1000), nil, "this factory can't")
	end,
	due_counts_what_is_on_the_way = function()
		local A = asks()
		local K = F.doctrine.asks
		local r = { count = 2 }
		T.ok(A.due(r, 0))
		A.sent(r, 0)
		T.ok(not A.due(r, 1), "spaced out")
		T.ok(A.due(r, K.every))
		A.sent(r, K.every)
		T.ok(not A.due(r, 2 * K.every), "two on the way: enough")
		A.arrived(r)
		T.ok(A.due(r, 2 * K.every), "one arrived")
		T.eq(r.delivered, 1)
		-- a unit that never came (cancelled, its factory died): forgotten after onWay
		local q = { count = 1 }
		A.sent(q, 0)
		T.ok(not A.due(q, K.every))
		T.ok(A.due(q, K.onWay + 1))
	end,
	one_shot_asks_close_when_all_came = function()
		local A = asks()
		local t = T.load("sc_team")({ doctrine = F.doctrine })
		local r = t.post({ kind = "units", from = 3, what = "sub", count = 2, oneShot = true, life = F.doctrine.asks.life }, 0)
		T.eq(t.post({ kind = "units", from = 3, what = "radar", count = 1 }, 0) == r, false, "another kind is another ask")
		t.expire(F.doctrine.team.requestLife + 1)
		T.eq(#t.open("units"), 1, "the one-shot one outlives the usual life; the other expired")
		A.sent(r, 0)
		A.arrived(r)
		A.arrived(r)
		T.eq(r.count, 0)
		t.expire(F.doctrine.team.requestLife + 2)
		T.eq(#t.open("units"), 0, "all came: closed")
	end,
}
