-- Sub-Commanders territory (design/engine.md): what's ours on the map and where its edge needs holding.
-- Cells within `reach` of our structures are ours. Terrain (terrain(heightAt)) marks cells ground units
-- can't use (steep slopes, deep water); the frontier is then only our cells that enemies can actually
-- reach: next to a passable cell connected to their side. Cliffs, water and the map edge defend
-- themselves (strong players build against them), so pickets gather at the real approaches.
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
	local T = { W = W, H = H, cell = CELL, owned = {}, value = {}, frontier = {}, blocked = {}, exposed = 0 }

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

	-- terrain: heightAt(x, z) -> height. A cell is blocked for ground units when it's steep (the steepest
	-- step between samples a quarter cell apart above 1.6 x maxSlope: one cliff edge in a corner doesn't
	-- wall it off) or deeper than maxDepth under water.
	function T.terrain(heightAt, opts)
		opts = opts or {}
		local maxSlope, maxDepth = opts.maxSlope or 0.45, opts.maxDepth or 22
		local step = CELL / 4
		local blocked, n = {}, 0
		for iz = 0, H - 1 do
			for ix = 0, W - 1 do
				local x0, z0 = ix * CELL, iz * CELL
				local h = {}
				for sz = 0, 4 do
					h[sz] = {}
					for sx = 0, 4 do
						h[sz][sx] = heightAt(x0 + sx * step, z0 + sz * step)
					end
				end
				local steep, low = 0, math.huge
				for sz = 0, 4 do
					for sx = 0, 4 do
						low = min(low, h[sz][sx])
						if sx < 4 then
							steep = max(steep, math.abs(h[sz][sx + 1] - h[sz][sx]) / step)
						end
						if sz < 4 then
							steep = max(steep, math.abs(h[sz + 1][sx] - h[sz][sx]) / step)
						end
					end
				end
				if steep > maxSlope * 1.6 or low < -maxDepth then
					blocked[idx(ix, iz)] = true
					n = n + 1
				end
			end
		end
		T.blocked = blocked
		return n
	end

	-- structures: list of { x, z, value }; enemy: { x, z } (their start; nil = every passable cell counts).
	-- Rebuilds ownership, the value each cell protects, and the exposed frontier.
	function T.update(structures, enemy)
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
		-- where enemies can walk: passable cells that aren't ours, connected to their start
		local blocked = T.blocked
		local walk = {}
		if enemy then
			local sx, sz = T.cellOf(enemy[1], enemy[2])
			local queue, head = { idx(sx, sz) }, 1
			walk[queue[1]] = true
			while queue[head] do
				local i = queue[head]
				head = head + 1
				local ix, iz = (i - 1) % W, floor((i - 1) / W)
				for dz = -1, 1 do
					for dx = -1, 1 do
						local nx, nz = ix + dx, iz + dz
						if (dx ~= 0 or dz ~= 0) and nx >= 0 and nz >= 0 and nx < W and nz < H then
							local ni = idx(nx, nz)
							if not walk[ni] and not blocked[ni] and not owned[ni] then
								walk[ni] = true
								queue[#queue + 1] = ni
							end
						end
					end
				end
			end
		end
		local frontier = {}
		for i in pairs(owned) do
			local ix, iz = (i - 1) % W, floor((i - 1) / W)
			local edge = false
			if not blocked[i] then
				for dz = -1, 1 do
					for dx = -1, 1 do
						local nx, nz = ix + dx, iz + dz
						-- the map edge, cliffs and deep water aren't a frontier: nothing comes from there
						if (dx ~= 0 or dz ~= 0) and nx >= 0 and nz >= 0 and nx < W and nz < H then
							local ni = idx(nx, nz)
							if not owned[ni] and not blocked[ni] and (not enemy or walk[ni]) then
								edge = true
							end
						end
					end
				end
			end
			if edge then
				frontier[#frontier + 1] = { ix = ix, iz = iz, x = (ix + 0.5) * CELL, z = (iz + 0.5) * CELL }
			end
		end
		T.owned, T.value, T.frontier, T.exposed = owned, value, frontier, #frontier
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
