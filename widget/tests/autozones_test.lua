local function zones()
	return T.load("sc_autozones")({ mapX = 8192, mapZ = 8192 })
end

return {
	economy_around_home = function()
		local z = zones().forRole("economy", { home = { 1000, 1000 }, enemy = { 7000, 7000 } })
		T.eq(#z, 1)
		T.eq(z[1].x, 1000)
		T.ok(z[1].auto, "marked auto")
	end,
	defense_front_and_exposed_extractors = function()
		local z = zones().forRole("defense", {
			home = { 1000, 1000 }, enemy = { 7000, 1000 },
			extractors = { { x = 1100, z = 1000 }, { x = 3000, z = 1200 }, { x = 3100, z = 1300 }, { x = 2600, z = 3000 }, { x = -500, z = 1000 } },
		})
		T.ok(z[1].x > 1000, "front toward the enemy")
		T.eq(#z, 3, "front + two exposed clusters (the near one and the one behind home don't count)")
		T.eq(z[2].x, 3100, "most exposed first")
	end,
	army_at_rally = function()
		local z = zones().forRole("army", { home = { 1000, 1000 }, enemy = { 7000, 7000 }, rally = { 2500, 2600 } })
		T.eq(z[1].x, 2500)
		T.eq(z[1].z, 2600)
	end,
	clamped_to_map = function()
		local z = zones().forRole("intelligence", { home = { 8100, 8100 }, enemy = { 9000, 9000 } })
		T.ok(z[1].x <= 8192 - 64 and z[1].z <= 8192 - 64)
	end,
	clusters_find_wind_farms = function()
		local pts = {}
		for i = 1, 6 do
			pts[#pts + 1] = { x = 1000 + i * 60, z = 1000 }
		end
		pts[#pts + 1] = { x = 3000, z = 3000 }
		pts[#pts + 1] = { x = 3050, z = 3000 }
		local c = zones().clusters(pts, 500, 3)
		T.eq(#c, 1, "only the farm has 3+")
		T.eq(c[1].count, 6)
		T.near(c[1].x, 1210, 1e-6)
	end,
}
