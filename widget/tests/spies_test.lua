local F = dofile("widget/tests/fixtures.lua")

local function spies()
	return T.load("sc_spies")({ doctrine = F.doctrine })
end

return {
	cloakers_fear_decloak_distance_visible_spotters_weapons = function()
		local S = spies()
		local known = {
			{ x = 0, z = 0, mobile = false, armed = true, range = 600 },
			{ x = 1000, z = 0, mobile = true, armed = true, range = 300, age = 5 },
			{ x = 2000, z = 0, mobile = true, armed = true, range = 300, age = 60 }, -- long gone
			{ x = 3000, z = 0, mobile = false, armed = false }, -- an extractor
		}
		local P = F.doctrine.intel.spy
		local hc = S.hazards(known, 75)
		T.eq(#hc, 3, "a cloaker: structures (armed or not) and units seen lately")
		T.eq(hc[1].r, 75 + P.static)
		T.eq(hc[2].r, 75 + P.mobile, "units walk: more room")
		local hv = S.hazards(known, nil)
		T.eq(#hv, 2, "a visible spotter: what shoots")
		T.eq(hv[1].r, 600 + P.armed)
	end,
	post_is_in_sight_and_outside_every_hazard = function()
		local S = spies()
		-- their factory at 4000,4000 with a guard of units around it; we come from 0,0
		local haz = { { x = 4000, z = 4000, r = 225 }, { x = 3700, z = 3700, r = 425 } }
		local x, z = S.post(4000, 4000, 550, { x = 0, z = 0 }, haz)
		T.ok(x, "a post exists")
		local inside = S.danger(x, z, haz)
		T.ok(inside < 0, "outside every hazard: " .. inside)
		local dd = math.sqrt((x - 4000) ^ 2 + (z - 4000) ^ 2)
		T.ok(dd <= 550, "within sight of the target: " .. dd)
		-- the old post: 420 straight back toward home, inside their guard's reach
		local ox, oz = 4000 - 420 / math.sqrt(2), 4000 - 420 / math.sqrt(2)
		T.ok(S.danger(ox, oz, haz) > 0, "the old post was in danger")
	end,
	no_post_when_surrounded = function()
		local S = spies()
		local haz = { { x = 0, z = 0, r = 2000 } }
		T.eq(S.post(0, 0, 550, { x = 5000, z = 0 }, haz), nil)
	end,
	post_respects_the_ground = function()
		local S = spies()
		local x = S.post(0, 0, 500, { x = -5000, z = 0 }, {}, function(px)
			return px > 0 -- only the east side is land
		end)
		T.ok(x and x > 0, "on ground it can stand on: " .. tostring(x))
	end,
	flee_goes_away_from_the_threat = function()
		local S = spies()
		local x, z = S.flee(100, 0, { { x = 0, z = 0, r = 300 } }, { x = 0, z = 5000 }, 500)
		T.ok(x > 100, "away from it: " .. x)
		T.ok(math.abs(math.sqrt((x - 100) ^ 2 + z ^ 2) - 500) < 1, "flee distance")
		local hx, hz = S.flee(100, 0, {}, { x = 100, z = 5000 }, 500)
		T.near(hx, 100, 1e-6)
		T.near(hz, 500, 1e-6, "home when nothing's near")
	end,
	mark_the_richest_fresh_target_weighing_anti_air = function()
		local S = spies()
		local cands = {
			{ id = 1, x = 0, z = 0, cost = 4000, role = "energy", age = 10 }, -- fusion, heavy anti-air
			{ id = 2, x = 5000, z = 0, cost = 2000, role = "factory", age = 10 },
			{ id = 3, x = 9000, z = 0, cost = 9000, role = "energy", age = 900 }, -- not seen in ages
			{ id = 4, x = 7000, z = 0, cost = 50, role = "extractor", age = 1 }, -- not worth it
		}
		local function aaAt(x)
			return x == 0 and 6000 or 0
		end
		T.eq(S.markTarget(cands, aaAt).id, 2, "the factory: no anti-air there")
		T.eq(S.markTarget(cands, function()
			return 0
		end).id, 1, "without anti-air the fusion")
		T.eq(S.markTarget(cands, aaAt, { [2] = true }).id, 1, "taken ones skipped")
		T.eq(S.markTarget({ cands[4] }, aaAt), nil)
	end,
	sabotage_site_is_the_anti_air_centre = function()
		local S = spies()
		local aa = { { x = 100, z = 0, cost = 300 }, { x = -100, z = 0, cost = 300 }, { x = 5000, z = 0, cost = 999 } }
		local x, z, w = S.sabotageSite(0, 0, aa, 900)
		T.near(x, 0, 1e-6)
		T.near(z, 0, 1e-6)
		T.eq(w, 600)
		T.eq(S.sabotageSite(0, 0, {}, 900), nil)
	end,
	antinuke_op_picks_the_one_anti_nuke_in_the_way = function()
		local S = spies()
		local nt = T.load("sc_strategic")({ doctrine = F.doctrine }).nukeTarget
		-- their base at 5000,5000 (8000 metal) under a Citadel; an outpost at 0,0 (1000) in the open
		local cands = { { x = 5000, z = 5000, cost = 5000 }, { x = 5100, z = 5000, cost = 3000 }, { x = 0, z = 0, cost = 1000 } }
		local anti = { id = 7, x = 5200, z = 5000, r = 2000, static = true }
		local op = S.antinukeOp(cands, 640, { anti }, 500, nt, 1.5)
		T.ok(op and op.anti.id == 7, "stun the Citadel")
		T.eq(op.v, 8000)
		T.near(op.x, 5000, 1e-6)
		-- a second anti-nuke over the base too: one spy isn't enough
		local two = { anti, { id = 8, x = 4800, z = 5000, r = 2000, static = true } }
		T.eq(S.antinukeOp(cands, 640, two, 500, nt, 1.5), nil)
		-- a mobile one moves: no
		T.eq(S.antinukeOp(cands, 640, { { id = 9, x = 5200, z = 5000, r = 1600 } }, 500, nt, 1.5), nil)
		-- the open target nearly as good: not worth a spy
		cands[3].cost = 6000
		T.eq(S.antinukeOp(cands, 640, { anti }, 500, nt, 1.5), nil)
	end,
}
