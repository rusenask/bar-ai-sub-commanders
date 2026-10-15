-- Sub-Commanders auto zones (design/engine.md): the areas a sub-commander works in when the player drew
-- none. Common sense by role, recomputed as the game moves:
--   economy       around the base (it also expands to safe metal spots on our side)
--   defense       the base's front toward the enemy, and the exposed extractor clusters
--   army          around its rally point (the safe edge of our side, from the threat map)
--   air           over the base (the Air Force; its fighters also cover the army and areas it's asked to)
--   intelligence  the approaches: a third of the way toward the enemy
--
-- usage: local AutoZones = VFS.Include("LuaUI/Include/sc_autozones.lua", nil, VFS.RAW_FIRST)
--        local zones = AutoZones({ mapX = Game.mapSizeX, mapZ = Game.mapSizeZ })
--        local list = zones.forRole("defense", { home = {x, z}, enemy = {x, z}, extractors = {...}, rally = {x, z} })
-- Pure Lua: unit-tested in widget/tests/autozones_test.lua.

local max, min, sqrt = math.max, math.min, math.sqrt

return function(ctx)
	local Z = {}

	local function clamp(x, z)
		return max(64, min(ctx.mapX - 64, x)), max(64, min(ctx.mapZ - 64, z))
	end

	local function circle(x, z, r)
		x, z = clamp(x, z)
		return { kind = "circle", x = math.floor(x), z = math.floor(z), r = r, auto = true }
	end

	-- exposed extractor clusters: ours, away from home, on the enemy's side of it (up to n, most exposed
	-- first). extractors: list of { x, z }
	function Z.exposed(home, enemy, extractors, n)
		local hx, hz, ex, ez = home[1], home[2], enemy[1], enemy[2]
		local dx, dz = ex - hx, ez - hz
		local len = max(sqrt(dx * dx + dz * dz), 1)
		local list = {}
		for _, m in ipairs(extractors or {}) do
			local ox, oz = m.x - hx, m.z - hz
			local along = (ox * dx + oz * dz) / len -- how far toward the enemy
			if ox * ox + oz * oz > 900 * 900 and along > 0 then
				list[#list + 1] = { x = m.x, z = m.z, along = along }
			end
		end
		table.sort(list, function(a, b)
			return a.along > b.along
		end)
		local out = {}
		for _, m in ipairs(list) do
			local near = false
			for _, o in ipairs(out) do
				if (o.x - m.x) ^ 2 + (o.z - m.z) ^ 2 < 700 * 700 then
					near = true
				end
			end
			if not near then
				out[#out + 1] = m
				if #out >= (n or 2) then
					break
				end
			end
		end
		return out
	end

	-- groups of at least minCount points within radius of each other's centre (greedy), biggest first:
	-- { x, z, count }. Used to find our wind farms and other clusters worth a turret.
	function Z.clusters(points, radius, minCount)
		local r2 = radius * radius
		local groups = {}
		for _, p in ipairs(points or {}) do
			local g
			for _, o in ipairs(groups) do
				if (o.x - p.x) ^ 2 + (o.z - p.z) ^ 2 <= r2 then
					g = o
					break
				end
			end
			if not g then
				g = { x = p.x, z = p.z, count = 0, sx = 0, sz = 0 }
				groups[#groups + 1] = g
			end
			g.count, g.sx, g.sz = g.count + 1, g.sx + p.x, g.sz + p.z
			g.x, g.z = g.sx / g.count, g.sz / g.count
		end
		local out = {}
		for _, g in ipairs(groups) do
			if g.count >= (minCount or 1) then
				out[#out + 1] = { x = g.x, z = g.z, count = g.count }
			end
		end
		table.sort(out, function(a, b)
			return a.count > b.count
		end)
		return out
	end

	-- info: { home = {x, z}, enemy = {x, z}, extractors = {{x, z}...}, rally = {x, z} (army) }
	function Z.forRole(role, info)
		local hx, hz = info.home[1], info.home[2]
		local ex, ez = (info.enemy or info.home)[1], (info.enemy or info.home)[2]
		local dx, dz = ex - hx, ez - hz
		local len = max(sqrt(dx * dx + dz * dz), 1)
		local ux, uz = dx / len, dz / len
		if role == "economy" then
			return { circle(hx, hz, 1300) }
		elseif role == "defense" then
			local out = { circle(hx + ux * 800, hz + uz * 800, 850) }
			for _, m in ipairs(Z.exposed(info.home, { ex, ez }, info.extractors, 2)) do
				out[#out + 1] = circle(m.x, m.z, 500)
			end
			return out
		elseif role == "army" then
			local r = info.rally or { hx + ux * len * 0.3, hz + uz * len * 0.3 }
			return { circle(r[1], r[2], 1000) }
		elseif role == "air" or role == "airdefense" then
			return { circle(hx, hz, 1200) }
		elseif role == "intelligence" then
			local d = min(len * 0.33, 2500)
			return { circle(hx + ux * d, hz + uz * d, 1500) }
		end
		return { circle(hx, hz, 1000) }
	end

	return Z
end
