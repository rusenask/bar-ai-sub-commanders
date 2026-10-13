local F = dofile("widget/tests/fixtures.lua")

return {
	threat_covers_weapon_range = function()
		local tm = F.map()
		tm.see(10, 1, 1000, 1000, 0)
		tm.update(0, {}, true)
		T.eq(tm.threat(1000, 1000), 100, "at the raider")
		T.eq(tm.threat(1250, 1000), 100, "within range + margin")
		T.eq(tm.threat(2000, 1000), 0, "far away")
		T.near(tm.threat(1000, 1000, "air"), 10, 1e-9, "ground units barely threaten aircraft")
	end,
	aa_only_threatens_air = function()
		local tm = F.map()
		tm.see(11, 3, 2000, 2000, 0)
		tm.update(0, {}, true)
		T.eq(tm.threat(2000, 2000), 0, "ground")
		T.eq(tm.threat(2000, 2000, "air"), 200, "air")
	end,
	unarmed_units_are_no_threat = function()
		local tm = F.map()
		tm.see(12, 5, 500, 500, 0)
		tm.update(0, {}, true)
		T.eq(tm.threat(500, 500), 0)
	end,
	mobile_memory_fades_statics_stay = function()
		local tm = F.map()
		tm.see(10, 1, 1000, 1000, 0)
		tm.see(20, 2, 3000, 3000, 0)
		local D = F.doctrine.threat
		tm.update(D.fresh, {}, true)
		T.eq(tm.threat(1000, 1000), 100, "fresh")
		local mid = math.floor((D.fresh + D.mobileMemory) / 2)
		tm.update(mid, {}, true)
		T.ok(tm.threat(1000, 1000) > 0 and tm.threat(1000, 1000) < 100, "fading")
		tm.update(D.mobileMemory + 1, {}, true)
		T.eq(tm.threat(1000, 1000), 0, "forgotten")
		T.eq(tm.enemies[10], nil, "dropped from memory")
		T.eq(tm.threat(3000, 3000), 300, "turret still remembered")
	end,
	forget_and_count = function()
		local tm = F.map()
		tm.see(10, 1, 1000, 1000, 0)
		tm.see(10, 1, 1100, 1000, 5)
		T.eq(tm.count, 1)
		tm.forget(10)
		T.eq(tm.count, 0)
	end,
	influence_from_our_units = function()
		local tm = F.map()
		tm.update(0, { { defID = 2, x = 800, z = 800 } }, true)
		T.eq(tm.influence(800, 800), 300)
		T.eq(tm.influence(3000, 3000), 0)
	end,
	enemy_power_counts_nearby_armed = function()
		local tm = F.map()
		tm.see(1, 1, 1000, 1000, 0)
		tm.see(2, 4, 1200, 1000, 0)
		tm.see(3, 2, 3000, 3000, 0)
		tm.see(4, 3, 1000, 1100, 0)
		T.eq(tm.enemyPower(1000, 1000, 500, 0), 350, "raider + artillery, not the AA turret")
		T.eq(tm.enemyPower(1000, 1000, 500, 0, { air = true }), 550, "with anti-air")
		T.eq(tm.enemyPower(3000, 3000, 500, 0, { mobileOnly = true }), 0, "mobile only")
	end,
	safe_point_falls_back_toward_home = function()
		local tm = F.map()
		tm.see(1, 4, 2000, 2000, 0) -- artillery, reach 1120
		tm.update(0, {}, true)
		T.ok(tm.threat(2000, 2000) > 0)
		local x, z = tm.safePoint(2000, 2000, 0, 0)
		T.ok(x and tm.threat(x, z) == 0, "safe")
		T.ok(x < 2000 and z < 2000, "toward home")
	end,
	front_is_where_threat_starts = function()
		local tm = F.map()
		tm.see(1, 2, 3000, 3000, 0) -- turret, reach 570
		tm.update(0, {}, true)
		local sx, sz, tx, tz = tm.front(500, 500, 3500, 3500)
		T.ok(tm.threat(sx, sz) == 0 and tm.threat(tx, tz) > 0, "edge")
		T.ok(sx > 2000 and sx < 3000, "between")
	end,
	groups_cluster_enemies = function()
		local tm = F.map()
		tm.see(1, 2, 1000, 1000, 0)
		tm.see(2, 2, 1100, 1000, 0)
		tm.see(3, 1, 3500, 3500, 0)
		tm.see(4, 3, 1050, 1050, 0) -- anti-air: its own layer
		local gs = tm.groups(0, 5)
		T.eq(#gs, 2, "two ground groups")
		T.eq(gs[1].power, 600, "the turrets first")
		T.eq(gs[1].x, 1050, "centre")
		T.eq(gs[1].static, 600, "static share")
		tm.see(9, 4, 3600, 3500, 0) -- artillery joins the raider's group
		local g2 = tm.groups(0, 5)
		T.eq(g2[2].ranged, 250, "long-range share")
		T.eq(tm.groups(0, 5, 900, "air")[1].power, 200, "air layer")
	end,
	radar_blips_count_until_identified = function()
		local tm = F.map()
		tm.seeBlip(50, 1000, 1000, 0)
		tm.update(0, {}, true)
		T.eq(tm.threat(1000, 1000), 120, "assumed value")
		T.eq(tm.enemyPower(1000, 1000, 300, 0), 120)
		tm.see(50, 2, 1000, 1000, 5) -- identified: a turret
		tm.update(5, {}, true)
		T.eq(tm.threat(1000, 1000), 300, "now the real thing")
		tm.seeBlip(50, 1000, 1000, 9) -- radar again: keeps the identity
		T.eq(tm.enemies[50].blip, nil)
	end,
	fresh_power_ignores_memories = function()
		local tm = F.map()
		tm.see(1, 1, 1000, 1000, 0)
		local D = F.doctrine.threat
		T.eq(tm.enemyPower(1000, 1000, 300, D.fresh, { fresh = true }), 100, "just seen")
		T.eq(tm.enemyPower(1000, 1000, 300, D.fresh + 30, { fresh = true }), 0, "a memory")
		T.ok(tm.enemyPower(1000, 1000, 300, D.fresh + 30) > 0, "still remembered otherwise")
	end,
	hordes_are_remembered = function()
		local tm = F.map()
		local D = F.doctrine.threat
		-- a horde: 16 artillery (250 each = 4000 metal) seen together, and a lone raider elsewhere
		for i = 1, 16 do
			tm.see(100 + i, 4, 2000 + i * 20, 2000, 0)
		end
		tm.see(1, 1, 500, 3500, 0)
		tm.groups(0, 5) -- marks the horde
		local later = D.mobileMemory + 30 * 60 -- well past normal memory
		tm.update(later, {}, true)
		T.eq(tm.threat(500, 3500), 0, "the lone raider is forgotten")
		T.ok(tm.threat(2150, 2000) >= 4000 * D.hordeFloor - 1, "the horde isn't: " .. tm.threat(2150, 2000))
		T.ok(tm.enemyPower(2150, 2000, 700, later) >= 4000 * D.hordeFloor - 1, "and counts in fights")
		tm.update(D.hordeMemory + 30, {}, true)
		T.eq(tm.threat(2150, 2000), 0, "until hordeMemory has passed")
	end,
}
