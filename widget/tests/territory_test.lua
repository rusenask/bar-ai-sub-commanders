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
}
