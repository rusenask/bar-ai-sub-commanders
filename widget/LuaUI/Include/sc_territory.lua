-- Sub-Commanders territory (design/engine.md): what's ours on the map and where its edge needs holding.
-- Cells within `reach` of our structures are ours; the frontier is our cells next to cells that aren't.
-- Pickets are frontier points worth guarding, scored by where intruders came from (approach sectors),
-- whether they face the enemy, and how much of ours is behind them. Without pickets on the sides, raids
-- simply walk around the army (seen in test games: attacks from every side).
--
-- usage: local Territory = VFS.Include("LuaUI/Include/sc_territory.lua", nil, VFS.RAW_FIRST)
--        local terr = Territory({ mapX = Game.mapSizeX, mapZ = Game.mapSizeZ, cell = 256 })
--        terr.update(structures)              -- list of { x, z, value }
--        terr.pickets(n, home, enemy, sectors) -- best n frontier points
-- Pure Lua: unit-tested in widget/tests/territory_test.lua.

local max, min, floor, sqrt, atan2, pi = math.max, math.min, math.floor, math.sqrt, math.atan2 or math.atan, math.pi

return function(ctx)
	local CELL = ctx.cell or 256
	local W = max(1, math.ceil(ctx.mapX / CELL))
	local H = max(1, math.ceil(ctx.mapZ / CELL))
	local reach = ctx.reach or 700
	local T = { W = W, H = H, cell = CELL, owned = {}, value = {}, frontier = {} }

	local function idx(ix, iz)
		return iz * W + ix + 1
	end

	function T.cellOf(x, z)
		return max(0, min(W - 1, floor(x / CELL))), max(0, min(H - 1, floor(z / CELL)))
	end

	function T.isOurs(x, z)
		local ix, iz = T.cellOf(x, z)
		return T.owned[idx(ix, iz)] == true
	end

	-- structures: list of { x, z, value }. Rebuilds ownership, the value each cell protects, the frontier.
	function T.update(structures)
		local owned, value = {}, {}
		local r = reach + CELL * 0.5
		for _, s in ipairs(structures) do
			local x1, z1 = T.cellOf(s.x - reach, s.z - reach)
			local x2, z2 = T.cellOf(s.x + reach, s.z + reach)
			for iz = z1, z2 do
				for ix = x1, x2 do
					local cx, cz = (ix + 0.5) * CELL - s.x, (iz + 0.5) * CELL - s.z
					if cx * cx + cz * cz <= r * r then
						local i = idx(ix, iz)
						owned[i] = true
						value[i] = (value[i] or 0) + (s.value or 1)
					end
				end
			end
		end
		local frontier = {}
		for i in pairs(owned) do
			local ix, iz = (i - 1) % W, floor((i - 1) / W)
			local edge = false
			for dz = -1, 1 do
				for dx = -1, 1 do
					local nx, nz = ix + dx, iz + dz
					if (dx ~= 0 or dz ~= 0) and (nx < 0 or nz < 0 or nx >= W or nz >= H or not owned[idx(nx, nz)]) then
						-- the map edge isn't a frontier: nothing comes from there
						if nx >= 0 and nz >= 0 and nx < W and nz < H then
							edge = true
						end
					end
				end
			end
			if edge then
				frontier[#frontier + 1] = { ix = ix, iz = iz, x = (ix + 0.5) * CELL, z = (iz + 0.5) * CELL }
			end
		end
		T.owned, T.value, T.frontier = owned, value, frontier
		return #frontier
	end

	-- how much of ours a frontier point protects: the value of our cells within `r` behind it
	local function protects(p, r)
		local v = 0
		local x1, z1 = T.cellOf(p.x - r, p.z - r)
		local x2, z2 = T.cellOf(p.x + r, p.z + r)
		for iz = z1, z2 do
			for ix = x1, x2 do
				v = v + (T.value[idx(ix, iz)] or 0)
			end
		end
		return v
	end

	-- the n best frontier points to hold, at least `spacing` apart. home, enemy: { x, z }; sectors: 8
	-- intrusion counts around home (sector 1 = west, then clockwise: north-west, north, ...), may be nil.
	-- score = (1 + facing the enemy) x (1 + intrusions from that side) x what it protects
	function T.pickets(n, home, enemy, sectors, spacing)
		spacing = spacing or 1200
		local hx, hz = home[1], home[2]
		local ex, ez = enemy[1] - hx, enemy[2] - hz
		local elen = max(sqrt(ex * ex + ez * ez), 1)
		local scored = {}
		for _, p in ipairs(T.frontier) do
			local dx, dz = p.x - hx, p.z - hz
			local len = max(sqrt(dx * dx + dz * dz), 1)
			local facing = max(0, (dx * ex + dz * ez) / (len * elen))
			local s = floor((atan2(dz, dx) + pi) / (2 * pi) * 8 + 0.5) % 8 + 1
			local intrusions = sectors and sectors[s] or 0
			scored[#scored + 1] = { x = p.x, z = p.z, score = (1 + facing) * (1 + intrusions) * (1 + protects(p, 600)), sector = s }
		end
		table.sort(scored, function(a, b)
			return a.score > b.score
		end)
		local out = {}
		for _, p in ipairs(scored) do
			local far = true
			for _, o in ipairs(out) do
				if (o.x - p.x) ^ 2 + (o.z - p.z) ^ 2 < spacing * spacing then
					far = false
					break
				end
			end
			if far then
				out[#out + 1] = p
				if #out >= n then
					break
				end
			end
		end
		return out
	end

	return T
end
