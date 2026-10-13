-- Sub-Commanders threat-aware pathing (design/engine.md): A* over the threat map's grid, where a cell
-- costs more the more enemy firepower reaches it. Returns a few waypoints; the engine's own pathfinder
-- handles terrain between them. Used to send constructors to expansions and units home around danger.
--
-- usage: local Pathing = VFS.Include("LuaUI/Include/sc_pathing.lua", nil, VFS.RAW_FIRST)
--        local path = Pathing(tm)   -- tm: a threat map (sc_threatmap.lua)
--        local waypoints, danger = path.route(x1, z1, x2, z2, { layer = "ground", avoid = 4 })
-- Pure Lua: unit-tested in widget/tests/pathing_test.lua.

local max, min, floor, sqrt, abs = math.max, math.min, math.floor, math.sqrt, math.abs

return function(tm)
	local P = {}
	local W, H = tm.W, tm.H
	local SQRT2 = sqrt(2)

	-- binary heap of { f, i }
	local function push(heap, f, i)
		local n = #heap + 1
		heap[n] = { f, i }
		while n > 1 do
			local p = floor(n / 2)
			if heap[p][1] <= heap[n][1] then
				break
			end
			heap[p], heap[n] = heap[n], heap[p]
			n = p
		end
	end

	local function pop(heap)
		local top = heap[1]
		local last = heap[#heap]
		heap[#heap] = nil
		if #heap > 0 then
			heap[1] = last
			local n = 1
			while true do
				local l, r, s = 2 * n, 2 * n + 1, n
				if heap[l] and heap[l][1] < heap[s][1] then
					s = l
				end
				if heap[r] and heap[r][1] < heap[s][1] then
					s = r
				end
				if s == n then
					break
				end
				heap[s], heap[n] = heap[n], heap[s]
				n = s
			end
		end
		return top
	end

	-- opts.layer: "ground" (default) or "air"; opts.avoid: how many cells of detour one unit of
	-- normalised threat is worth (default 4); opts.norm: threat that counts as 1 (default 500 metal)
	function P.route(x1, z1, x2, z2, opts)
		opts = opts or {}
		local layer, avoid, norm = opts.layer or "ground", opts.avoid or 4, opts.norm or 500
		local sx, sz = tm.cellOf(x1, z1)
		local gx, gz = tm.cellOf(x2, z2)
		local start, goal = sz * W + sx, gz * W + gx
		local g, came, closed = { [start] = 0 }, {}, {}
		local heap = {}
		local function h(i)
			local ix, iz = i % W, floor(i / W)
			local dx, dz = abs(ix - gx), abs(iz - gz)
			return (dx + dz) + (SQRT2 - 2) * min(dx, dz)
		end
		push(heap, h(start), start)
		local expanded, limit = 0, opts.limit or W * H
		while #heap > 0 do
			local cur = pop(heap)[2]
			if cur == goal then
				break
			end
			if not closed[cur] then
				closed[cur] = true
				expanded = expanded + 1
				if expanded > limit then
					break
				end
				local ix, iz = cur % W, floor(cur / W)
				for dz = -1, 1 do
					for dx = -1, 1 do
						local nx, nz = ix + dx, iz + dz
						if (dx ~= 0 or dz ~= 0) and nx >= 0 and nz >= 0 and nx < W and nz < H then
							local ni = nz * W + nx
							if not closed[ni] then
								local step = (dx ~= 0 and dz ~= 0) and SQRT2 or 1
								local cost = g[cur] + step * (1 + avoid * tm.cellThreat(nx, nz, layer) / norm)
								if not g[ni] or cost < g[ni] then
									g[ni], came[ni] = cost, cur
									push(heap, cost + h(ni), ni)
								end
							end
						end
					end
				end
			end
		end
		if not g[goal] then
			return nil
		end
		-- walk back, keeping only the cells where the direction changes
		local cells = {}
		local i = goal
		while i do
			table.insert(cells, 1, i)
			i = came[i]
		end
		local points, danger = {}, 0
		for k = 1, #cells do
			local c = cells[k]
			local ix, iz = c % W, floor(c / W)
			danger = max(danger, tm.cellThreat(ix, iz, layer))
			local keep = k == #cells
			if not keep and k > 1 then
				local p, n = cells[k - 1], cells[k + 1]
				keep = (c - p) ~= (n - c)
			end
			if keep then
				local px, pz = tm.cellCenter(ix, iz)
				points[#points + 1] = { x = px, z = pz }
			end
		end
		-- the real destination, not the centre of its cell
		points[#points] = { x = x2, z = z2 }
		return points, danger
	end

	-- the most threat any cell on the straight line from a to b carries
	function P.lineDanger(x1, z1, x2, z2, layer)
		local dx, dz = x2 - x1, z2 - z1
		local steps = max(1, floor(sqrt(dx * dx + dz * dz) / (tm.cell * 0.5)))
		local worst = 0
		for s = 0, steps do
			worst = max(worst, tm.threat(x1 + dx * s / steps, z1 + dz * s / steps, layer))
		end
		return worst
	end

	return P
end
