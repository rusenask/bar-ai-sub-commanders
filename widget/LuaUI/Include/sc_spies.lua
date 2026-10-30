-- Sub-Commanders spy-chief (design/engine.md, doctrine.intel): the decisions behind Intelligence's
-- spotters, marks and sabotage; the widget gathers what we know and gives the orders.
--   hazards(known, decloak)        what a spotter keeps away from: { x, z, r } per enemy we know of
--   danger(x, z, hazards)          how far inside the nearest hazard (> 0: inside), and that hazard
--   post(tx, tz, sight, from, hazards, ok)   where to watch (tx, tz) from: in sight, outside every hazard
--   flee(x, z, hazards, home, dist)          where to slip away to
--   markTarget(cands, aaAt, taken)           the structure worth a deep strike
--   sabotageSite(tx, tz, aa, radius)         the centre of their anti-air around a strike target
--
-- usage: local Spies = VFS.Include("LuaUI/Include/sc_spies.lua", nil, VFS.RAW_FIRST)
--        local S = Spies({ doctrine = D })
-- Pure Lua: unit-tested in widget/tests/spies_test.lua.

local sqrt, max, cos, sin, pi = math.sqrt, math.max, math.cos, math.sin, math.pi

return function(ctx)
	local D = ctx.doctrine
	local S = {}

	local function d2(ax, az, bx, bz)
		return (ax - bx) ^ 2 + (az - bz) ^ 2
	end

	-- known: { x, z, mobile, armed, range, age (s since seen) }; decloak: the spotter's decloak distance
	-- (nil: it doesn't cloak). A cloaker is found when anything of theirs comes within its decloak
	-- distance (their units walk: more room from units than from structures, and only units seen lately
	-- count); a visible spotter by being shot (armed ones' range)
	function S.hazards(known, decloak)
		local P = D.intel.spy
		local out = {}
		for _, k in ipairs(known) do
			local r
			if decloak then
				if not k.mobile then
					r = decloak + P.static
				elseif (k.age or 0) <= P.mobileSecs then
					r = decloak + P.mobile
				end
			elseif k.armed and (not k.mobile or (k.age or 0) <= P.mobileSecs) then
				r = (k.range or 0) + P.armed
			end
			if r then
				out[#out + 1] = { x = k.x, z = k.z, r = r }
			end
		end
		return out
	end

	-- how far (x, z) is inside the nearest hazard's radius (negative: outside, by that much), and it
	function S.danger(x, z, hazards)
		local worst, which
		for _, h in ipairs(hazards) do
			local inside = h.r - sqrt(d2(x, z, h.x, h.z))
			if not worst or inside > worst then
				worst, which = inside, h
			end
		end
		return worst or -math.huge, which
	end

	-- a post to watch (tx, tz) from: on rings at doctrine.intel.spy.rings x sight around it, 16 places a
	-- ring, outside every hazard and where ok(x, z) (the ground it can stand on). The nearest to `from`
	-- (our side) of those with room to spare; nil when none
	function S.post(tx, tz, sight, from, hazards, ok)
		local P = D.intel.spy
		local near = {}
		local reach = sight + 1200
		for _, h in ipairs(hazards) do
			if d2(tx, tz, h.x, h.z) <= (reach + h.r) ^ 2 then
				near[#near + 1] = h
			end
		end
		local best, bestScore
		for _, ring in ipairs(P.rings) do
			local r = sight * ring
			for a = 0, 15 do
				local x, z = tx + cos(a * pi / 8) * r, tz + sin(a * pi / 8) * r
				if not ok or ok(x, z) then
					local inside = S.danger(x, z, near)
					if inside < 0 then
						-- room: up to 300 elmos counts, then the way home
						local score = sqrt(d2(x, z, from.x, from.z)) - 2 * math.min(-inside, 300)
						if not bestScore or score < bestScore then
							best, bestScore = { x = x, z = z }, score
						end
					end
				end
			end
			if best then
				return best.x, best.z
			end
		end
		return nil
	end

	-- away from every hazard it's in or near (each pushes by how deep it reaches in), a little toward
	-- home; `dist` elmos from (x, z). Home alone when nothing is near
	function S.flee(x, z, hazards, home, dist)
		local fx, fz = 0, 0
		for _, h in ipairs(hazards) do
			local dd = sqrt(d2(x, z, h.x, h.z))
			local push = h.r + 200 - dd
			if push > 0 then
				local l = max(dd, 1)
				fx, fz = fx + (x - h.x) / l * push, fz + (z - h.z) / l * push
			end
		end
		local hx, hz = home.x - x, home.z - z
		local hl = max(sqrt(hx * hx + hz * hz), 1)
		local fl = sqrt(fx * fx + fz * fz)
		if fl > 0 then
			fx, fz = fx / fl + 0.3 * hx / hl, fz / fl + 0.3 * hz / hl
		else
			fx, fz = hx / hl, hz / hl
		end
		local l = max(sqrt(fx * fx + fz * fz), 1e-6)
		return x + fx / l * dist, z + fz / l * dist
	end

	-- cands: { id, x, z, cost, role, age (s since seen) }; aaAt(x, z): their anti-air metal there; taken:
	-- id -> true for marks already up. The highest cost x role weight seen within doctrine.intel.marks
	-- .fresh s, less where their anti-air is; nil when none is worth minValue
	function S.markTarget(cands, aaAt, taken)
		local M = D.intel.marks
		local best, bestScore
		for _, c in ipairs(cands) do
			local value = (c.cost or 0) * (M.weights[c.role] or M.weights.other or 0.5)
			if not (taken and taken[c.id]) and (c.age or 0) <= M.fresh and value >= M.minValue then
				local score = value / (1 + aaAt(c.x, c.z) / 500)
				if not bestScore or score > bestScore then
					best, bestScore = c, score
				end
			end
		end
		if best then
			best.value = (best.cost or 0) * (M.weights[best.role] or M.weights.other or 0.5)
		end
		return best
	end

	-- aa: their anti-air { x, z, cost }. The cost-weighted centre of what's within radius of the target
	-- (where one EMP catches the most), and its metal; nil when there's none
	function S.sabotageSite(tx, tz, aa, radius)
		local sx, sz, w = 0, 0, 0
		for _, a in ipairs(aa) do
			if d2(tx, tz, a.x, a.z) <= radius * radius then
				sx, sz, w = sx + a.x * a.cost, sz + a.z * a.cost, w + a.cost
			end
		end
		if w <= 0 then
			return nil
		end
		return sx / w, sz / w, w
	end

	return S
end
