local function terr()
	return T.load("sc_territory")({ mapX = 8192, mapZ = 8192, cell = 256, reach = 700 })
end

-- a base around (2000, 2000): a few structures
local BASE = {
	{ x = 2000, z = 2000, value = 500 }, -- factory
	{ x = 2600, z = 2000, value = 60 }, -- extractor east
	{ x = 1400, z = 2000, value = 60 }, -- extractor west
	{ x = 2000, z = 1400, value = 45 }, -- wind north
}

return {
	ownership_and_frontier = function()
		local t = terr()
		local n = t.update(BASE)
		T.ok(t.isOurs(2000, 2000), "the factory's cell")
		T.ok(t.isOurs(2600, 2300), "near the east extractor")
		T.ok(not t.isOurs(5000, 5000), "far away")
		T.ok(n > 10, "a frontier ring: " .. n)
		for _, p in ipairs(t.frontier) do
			T.ok(t.isOurs(p.x, p.z), "frontier cells are ours")
		end
	end,
	pickets_face_the_enemy_and_spread = function()
		local t = terr()
		t.update(BASE)
		local ps = t.pickets(3, { 2000, 2000 }, { 7000, 2000 }, nil)
		T.eq(#ps, 3)
		T.ok(ps[1].x > 2000, "the best one faces the enemy (east): " .. ps[1].x)
		for i = 1, #ps do
			for j = i + 1, #ps do
				T.ok((ps[i].x - ps[j].x) ^ 2 + (ps[i].z - ps[j].z) ^ 2 >= 1200 * 1200, "spread out")
			end
		end
	end,
	intrusions_pull_a_picket_to_that_side = function()
		local t = terr()
		t.update(BASE)
		-- raids keep coming from the south (sector 7), the enemy is east
		local sectors = { 0, 0, 0, 0, 0, 0, 12, 0 }
		local ps = t.pickets(2, { 2000, 2000 }, { 7000, 2000 }, sectors)
		local south = false
		for _, p in ipairs(ps) do
			south = south or p.z > 2300
		end
		T.ok(south, "one picket holds the south, where the raids come from")
	end,
	map_edge_is_not_frontier = function()
		local t = terr()
		t.update({ { x = 100, z = 100, value = 100 } })
		for _, p in ipairs(t.frontier) do
			T.ok(p.x > 256 or p.z > 256, "not the corner against the map edge")
		end
	end,
	cliffs_and_water_are_not_frontier = function()
		local t = terr()
		-- deep water west of x = 1200, a cliff rising north of z = 1500
		local walls = t.terrain(function(x, z)
			if x < 1200 then
				return -60
			end
			if z < 1500 then
				return 40 + (1500 - z) * 2
			end
			return 40
		end)
		T.ok(walls > 0, "some cells are walls")
		local open = terr()
		open.update(BASE, { 7000, 2000 })
		t.update(BASE, { 7000, 2000 })
		T.ok(t.exposed < open.exposed, "fewer exposed cells with walls: " .. t.exposed .. " vs " .. open.exposed)
		for _, p in ipairs(t.frontier) do
			T.ok(p.x >= 1200 and p.z >= 1280, "no frontier against the water or the cliff: " .. p.x .. "," .. p.z)
		end
	end,
	only_what_the_enemy_can_reach = function()
		local t = terr()
		-- a cliff wall across the whole map at x 3400-3700, with one gap at z 1900-2400
		t.terrain(function(x, z)
			if x >= 3400 and x < 3700 and not (z >= 1900 and z < 2400) then
				return 400 + (x - 3400) * 3
			end
			return 40
		end)
		t.update(BASE, { 7000, 2000 })
		T.ok(t.exposed > 0, "the base is still reachable through the gap")
		local ps = t.pickets(1, { 2000, 2000 }, { 7000, 2000 }, nil)
		T.ok(ps[1] and ps[1].x > 2000, "the picket holds the side facing the gap")
	end,
	expansion_prefers_the_corner = function()
		local t = terr()
		local home, enemy = { 6500, 1500 }, { 1500, 6500 } -- we are top-right, they bottom-left
		local corner = t.spotCost(7800, 400, home, enemy) -- behind us, in the corner
		local side = t.spotCost(6500, 3000, home, enemy) -- toward the middle
		local forward = t.spotCost(5000, 3000, home, enemy) -- toward them
		T.ok(corner < side and side < forward, string.format("corner %.0f < side %.0f < forward %.0f", corner, side, forward))
		T.ok(forward > 1000, "a forward spot costs over 1000 elmos of walking")
	end,
}
