-- Sub-Commanders threat map: the world model (design/engine.md).
-- Remembers enemies after they leave sight (mobile ones fade, defences stay), and keeps two grids:
--   threat[layer]  how much enemy firepower (metal value) reaches each cell; layers "ground" and "air"
--   influence      how much of ours does
-- Rebuilt a few times a second; everything else asks it: is it safe to build here, where to fall back,
-- how strong is the enemy around a target, where is the front.
--
-- usage: local ThreatMap = VFS.Include("LuaUI/Include/sc_threatmap.lua", nil, VFS.RAW_FIRST)
--        local tm = ThreatMap({ defs = defs, mapX = Game.mapSizeX, mapZ = Game.mapSizeZ, doctrine = D })
--        tm.see(unitID, defID, x, z, frame); tm.forget(unitID); tm.update(frame, ownUnits)
-- Pure Lua (no engine calls): unit-tested in widget/tests/threatmap_test.lua.

local max, min, floor, sqrt = math.max, math.min, math.floor, math.sqrt

return function(ctx)
	local defs = ctx.defs
	local T = ctx.doctrine.threat
	local CELL = T.cell
	local W = max(1, math.ceil(ctx.mapX / CELL))
	local H = max(1, math.ceil(ctx.mapZ / CELL))

	local tm = { W = W, H = H, cell = CELL, enemies = {}, count = 0, builtFrame = -1 }
	-- a radar contact we haven't identified: assume a typical armed unit (doctrine.threat.blip)
	local BLIP = { mobile = true, armed = true, cost = T.blip and T.blip.cost or 120, range = T.blip and T.blip.range or 350, kind = "unknown" }
	local function defOf(e)
		return e.blip and BLIP or defs[e.defID]
	end
	tm.defOf = defOf
	local ground, air, infl = {}, {}, {}

	local function clear(g)
		for i = 1, W * H do
			g[i] = 0
		end
	end
	clear(ground)
	clear(air)
	clear(infl)

	local function index(ix, iz)
		return iz * W + ix + 1
	end

	function tm.cellOf(x, z)
		return max(0, min(W - 1, floor(x / CELL))), max(0, min(H - 1, floor(z / CELL)))
	end

	function tm.cellCenter(ix, iz)
		return (ix + 0.5) * CELL, (iz + 0.5) * CELL
	end

	-- add value to every cell whose centre lies within r of (x, z)
	local function stamp(g, x, z, r, value)
		local r2 = (r + CELL * 0.5) ^ 2
		local x1, z1 = tm.cellOf(x - r, z - r)
		local x2, z2 = tm.cellOf(x + r, z + r)
		for iz = z1, z2 do
			local cz = (iz + 0.5) * CELL - z
			for ix = x1, x2 do
				local cx = (ix + 0.5) * CELL - x
				if cx * cx + cz * cz <= r2 then
					local i = iz * W + ix + 1
					g[i] = g[i] + value
				end
			end
		end
	end

	-- what an enemy unit threatens: layers, reach and how much it counts now
	local function reach(d)
		return max(d.range or 0, T.minRange) + T.margin
	end

	-- weight of a remembered enemy at `frame`: 1 while fresh, fading to 0 (mobile units only)
	function tm.weight(e, frame)
		local age = frame - e.last
		if e.static then
			return age < T.staticMemory and 1 or 0
		end
		if age <= T.fresh then
			return 1
		end
		local w = max(0, 1 - (age - T.fresh) / max(1, T.mobileMemory - T.fresh))
		-- part of a horde: remembered longer, never below the floor until hordeMemory has passed
		if e.horde and age < (T.hordeMemory or 0) then
			w = max(w, T.hordeFloor or 0)
		end
		return w
	end

	-- an enemy unit was seen (entered sight, or refreshed while visible)
	function tm.see(unitID, defID, x, z, frame)
		local d = defs[defID]
		if not d then
			return
		end
		local e = tm.enemies[unitID]
		if not e then
			e = { first = frame }
			tm.enemies[unitID] = e
			tm.count = tm.count + 1
		end
		e.defID, e.x, e.z, e.last = defID, x, z, frame
		e.static = not d.mobile
		e.blip = nil
	end

	-- a radar contact (type unknown) at (x, z); identified units (see) take precedence
	function tm.seeBlip(unitID, x, z, frame)
		local e = tm.enemies[unitID]
		if e and not e.blip then
			e.x, e.z, e.last = x, z, frame
			return
		end
		if not e then
			e = { first = frame, blip = true }
			tm.enemies[unitID] = e
			tm.count = tm.count + 1
		end
		e.x, e.z, e.last = x, z, frame
	end

	function tm.forget(unitID)
		if tm.enemies[unitID] then
			tm.enemies[unitID] = nil
			tm.count = tm.count - 1
		end
	end

	-- rebuild the grids. ownUnits: list of { defID, x, z } of our armed units and defences
	function tm.update(frame, ownUnits, force)
		if not force and frame - tm.builtFrame < T.every then
			return false
		end
		tm.builtFrame = frame
		clear(ground)
		clear(air)
		clear(infl)
		for id, e in pairs(tm.enemies) do
			local w = tm.weight(e, frame)
			if w <= 0 then
				tm.enemies[id] = nil
				tm.count = tm.count - 1
			else
				local d = defOf(e)
				if d.armed then
					local value = max(d.cost, 30) * w
					local r = reach(d)
					if d.aaOnly then
						stamp(air, e.x, e.z, r, value)
					else
						stamp(ground, e.x, e.z, r, value)
						if not d.air then
							-- most ground weapons can't hit aircraft; count a little in case
							stamp(air, e.x, e.z, r, value * 0.1)
						end
					end
				end
			end
		end
		for i = 1, #(ownUnits or {}) do
			local o = ownUnits[i]
			local d = defs[o.defID]
			if d and d.armed and not d.aaOnly then
				stamp(infl, o.x, o.z, reach(d), max(d.cost, 30))
			end
		end
		return true
	end

	function tm.threat(x, z, layer)
		local ix, iz = tm.cellOf(x, z)
		return (layer == "air" and air or ground)[index(ix, iz)]
	end

	function tm.cellThreat(ix, iz, layer)
		return (layer == "air" and air or ground)[index(ix, iz)]
	end

	function tm.influence(x, z)
		local ix, iz = tm.cellOf(x, z)
		return infl[index(ix, iz)]
	end

	-- metal value of armed enemies remembered within r of (x, z), weighted by how fresh they are.
	-- opts: mobileOnly, air (count anti-air too), fresh (only those seen in the last doctrine.threat.fresh)
	function tm.enemyPower(x, z, r, frame, opts)
		local r2, p = r * r, 0
		for _, e in pairs(tm.enemies) do
			local d = defOf(e)
			if d.armed and not (opts and opts.mobileOnly and e.static) and not (d.aaOnly and not (opts and opts.air))
				and not (opts and opts.fresh and frame - e.last > T.fresh) then
				local dx, dz = e.x - x, e.z - z
				if dx * dx + dz * dz <= r2 then
					p = p + d.cost * tm.weight(e, frame)
				end
			end
		end
		return p
	end

	-- nearest point (cell centre) with no ground threat, searching outward from (x, z); with a home
	-- point, cells closer to home win ties so units fall back rather than sideways
	function tm.safePoint(x, z, homeX, homeZ, layer, maxRing)
		local ix, iz = tm.cellOf(x, z)
		local g = layer == "air" and air or ground
		if g[index(ix, iz)] <= 0 then
			return x, z
		end
		for ring = 1, maxRing or 16 do
			local best, bestScore
			for dz = -ring, ring do
				for dx = -ring, ring do
					if max(dx < 0 and -dx or dx, dz < 0 and -dz or dz) == ring then
						local cx, cz = ix + dx, iz + dz
						if cx >= 0 and cz >= 0 and cx < W and cz < H and g[index(cx, cz)] <= 0 then
							local px, pz = tm.cellCenter(cx, cz)
							local score = homeX and ((px - homeX) ^ 2 + (pz - homeZ) ^ 2) or 0
							if not bestScore or score < bestScore then
								best, bestScore = { px, pz }, score
							end
						end
					end
				end
			end
			if best then
				return best[1], best[2]
			end
		end
		return nil
	end

	-- walking from home toward the enemy: the last point before ground threat starts (the safe edge of
	-- our side) and the first threatened point
	function tm.front(homeX, homeZ, enemyX, enemyZ)
		local dx, dz = enemyX - homeX, enemyZ - homeZ
		local len = sqrt(dx * dx + dz * dz)
		if len < 1 then
			return homeX, homeZ
		end
		local steps = max(1, floor(len / (CELL * 0.5)))
		local lastX, lastZ = homeX, homeZ
		for s = 1, steps do
			local px, pz = homeX + dx * s / steps, homeZ + dz * s / steps
			if tm.threat(px, pz) > 0 then
				return lastX, lastZ, px, pz
			end
			lastX, lastZ = px, pz
		end
		return lastX, lastZ
	end

	-- enemy groups: remembered armed enemies clustered within `radius` (default 900), strongest first;
	-- { x, z, power, count, static } with the power-weighted centre. For squads, the strategist, the panel.
	function tm.groups(frame, n, radius, layer)
		local r2 = (radius or 900) ^ 2
		local list = {}
		for _, e in pairs(tm.enemies) do
			local d = defOf(e)
			if d.armed and ((layer == "air") == (d.aaOnly or false)) then
				local w = tm.weight(e, frame)
				if w > 0 then
					list[#list + 1] = { e = e, p = d.cost * w }
				end
			end
		end
		table.sort(list, function(a, b)
			return a.p > b.p
		end)
		local groups = {}
		for i = 1, #list do
			local it = list[i]
			local g
			for j = 1, #groups do
				local o = groups[j]
				if (o.x - it.e.x) ^ 2 + (o.z - it.e.z) ^ 2 <= r2 then
					g = o
					break
				end
			end
			if not g then
				g = { x = it.e.x, z = it.e.z, power = 0, count = 0, static = 0, sx = 0, sz = 0 }
				groups[#groups + 1] = g
			end
			g.power, g.count = g.power + it.p, g.count + 1
			g.last = max(g.last or 0, it.e.last)
			-- long-range mobile units (artillery): they outrange turrets; the army dives them
			local dd = defOf(it.e)
			if dd.mobile and (dd.range or 0) >= 600 then
				g.ranged = (g.ranged or 0) + it.p
			end
			g.sx, g.sz = g.sx + it.e.x * it.p, g.sz + it.e.z * it.p
			g.x, g.z = g.sx / g.power, g.sz / g.power
			if it.e.static then
				g.static = g.static + it.p
			end
		end
		table.sort(groups, function(a, b)
			return a.power > b.power
		end)
		-- big groups seen right now become hordes: their members are remembered longer (weight)
		if T.hordePower then
			for _, g in ipairs(groups) do
				if g.power >= T.hordePower then
					for _, it in ipairs(list) do
						if frame - it.e.last <= T.fresh and (it.e.x - g.x) ^ 2 + (it.e.z - g.z) ^ 2 <= r2 then
							it.e.horde = true
						end
					end
				end
			end
		end
		local out = {}
		for i = 1, min(#groups, n or #groups) do
			local g = groups[i]
			out[i] = { x = floor(g.x), z = floor(g.z), power = floor(g.power), count = g.count, static = floor(g.static), ranged = floor(g.ranged or 0),
				lastSeenSec = floor((frame - (g.last or frame)) / 30) }
		end
		return out
	end

	return tm
end
