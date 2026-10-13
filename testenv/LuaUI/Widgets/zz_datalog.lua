-- Data logger for training decision models (test-only, see design/decision-models.md).
-- Watches a game (best as a spectator with full view: BARbarian vs BARbarian) and writes one JSON line per
-- sample to datalog.jsonl in the write dir:
--   fight:  a team's armed group in contact with the enemy; both sides' features now, and the value each
--           side lost among those units 25 game seconds later
--   unit:   a combat unit when finished; its team's situation; damage it dealt over its life (valued at
--           the victims' metal cost per hit point), until it died, 8 minutes passed or the game ended
--   turret: the same for static defences, plus where it stands
--   micro:  how a combat unit near an enemy moves and shoots (sampled): distance to the nearest armed enemy
--           against both ranges, moving toward or away from it, firing, what it targets, how far ahead of
--           or behind its group it stands: the per-kind doctrine of sc_micro.lua comes from these
-- Enabled when datalog.txt exists in the write dir (testenv/collect.sh writes it).
function widget:GetInfo()
	return { name = "ZZ Decision Data Logger", layer = 101, enabled = true }
end

local enabled = VFS.LoadFile("datalog.txt", VFS.RAW) ~= nil
local defs
local out
local gameKey
local teams = {} -- teamID -> allyTeam (non-gaia)
local starts = {} -- teamID -> { x, z }
local tracked = {} -- unitID -> sample being followed (unit / turret)
local pendingFights = {} -- fights waiting for their outcome
local destroyed = {} -- unitID -> true for units that died (for fight outcomes)
local cellCooldown = {} -- team..cell -> frame
local spGetUnitPosition = Spring.GetUnitPosition
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

local FIGHT_EVERY = 150 -- frames between fight scans
local FIGHT_WINDOW = 30 * 25 -- outcome window
local CONTACT = 700 -- an armed unit with an enemy this close is in contact
local GROUP = 900 -- our units this close to the contact centre belong to the group
local ENEMY_RADIUS = 1100 -- enemies this close to the centre are the opposition
local UNIT_HORIZON = 30 * 60 * 8
local MICRO_EVERY = 90 -- frames between micro scans
local MICRO_PER_TEAM = 25 -- units sampled per team and scan (in contact only)

local function write(t)
	if out then
		out:write(Json.encode(t) .. "\n")
		out:flush()
	end
end

local function cost(d)
	return floor(d.cost + 0.5)
end

local function isArmedMobile(d)
	return d and d.mobile and d.armed and not d.builder and not d.commander
end

local function isDefence(d)
	return d and d.staticDef
end

local function enemyOf(team, other)
	return teams[team] and teams[other] and teams[team] ~= teams[other]
end

-- counts and value by kind of a list of { defID, hp, maxHp }
local function summarize(list)
	local kinds, value, hp, n, air = {}, 0, 0, 0, 0
	local dps, hpSum, rangeW = 0, 0, 0
	for _, u in ipairs(list) do
		local d = defs[u.defID]
		kinds[d.kind] = (kinds[d.kind] or 0) + 1
		value = value + d.cost
		hp = hp + u.hp / max(u.maxHp, 1)
		n = n + 1
		if d.air then
			air = air + 1
		end
		-- what decides fights: firepower, hit points, reach (range weighted by value)
		dps = dps + d.dps
		hpSum = hpSum + u.hp
		rangeW = rangeW + d.range * d.cost
	end
	return {
		kinds = kinds, value = floor(value + 0.5), health = n > 0 and floor(hp / n * 100 + 0.5) or 0, count = n, air = air,
		dps = floor(dps + 0.5), hp = floor(hpSum + 0.5), range = value > 0 and floor(rangeW / value + 0.5) or 0,
	}
end

local function unitInfo(u)
	local defID = Spring.GetUnitDefID(u)
	local d = defID and defs[defID]
	if not d then
		return nil
	end
	local hp, maxHp = Spring.GetUnitHealth(u)
	return { id = u, defID = defID, hp = hp or 0, maxHp = maxHp or 1 }
end

-- what a team fields and faces right now (armed mobile units and turrets, by kind)
local function teamSituation(team)
	local own, enemy = {}, {}
	local income = select(4, Spring.GetTeamResources(team, "metal")) or 0
	for t in pairs(teams) do
		for _, u in ipairs(Spring.GetTeamUnits(t) or {}) do
			local info = unitInfo(u)
			local d = info and defs[info.defID]
			if d and (isArmedMobile(d) or isDefence(d)) and not Spring.GetUnitIsBeingBuilt(u) then
				if t == team then
					own[#own + 1] = info
				elseif enemyOf(team, t) then
					enemy[#enemy + 1] = info
				end
			end
		end
	end
	return { own = summarize(own), enemy = summarize(enemy), metalIncome = floor(income * 10 + 0.5) / 10 }
end

local function unitTraits(d)
	return { name = d.name, human = d.human, kind = d.kind, cost = cost(d), range = floor(d.range), speed = floor(d.speed), health = floor(d.health), dps = floor(d.dps), air = d.air, aaOnly = d.aaOnly, tech = d.tech }
end

local function nearestEnemyStart(team, x, z)
	local best
	for t, s in pairs(starts) do
		if enemyOf(team, t) then
			local dd = sqrt((s.x - x) ^ 2 + (s.z - z) ^ 2)
			best = best and min(best, dd) or dd
		end
	end
	return best and floor(best) or -1
end

local function ownStartDist(team, x, z)
	local s = starts[team]
	return s and floor(sqrt((s.x - x) ^ 2 + (s.z - z) ^ 2)) or -1
end

----------------------------------------------------------------------------------------------------
-- units and turrets: follow each one's damage dealt
----------------------------------------------------------------------------------------------------

-- choices: what a factory starts building (combat units) and what a constructor starts (turrets), with the
-- options it had: imitation data from strong players' replays
local function optionTraits(builderDef, filter)
	local list = {}
	for _, o in ipairs(builderDef.options or {}) do
		local od = defs[o]
		if od and filter(od) then
			list[#list + 1] = unitTraits(od)
		end
	end
	return list
end

local function turretPlace(unitID, unitTeam, x, z)
	local near = 0
	for _, u in ipairs(Spring.GetUnitsInCylinder(x, z, 600, unitTeam)) do
		local od = defs[Spring.GetUnitDefID(u) or -1]
		if u ~= unitID and isDefence(od) then
			near = near + 1
		end
	end
	local nearestEnemy
	for _, u in ipairs(Spring.GetUnitsInCylinder(x, z, 3000)) do
		if enemyOf(unitTeam, Spring.GetUnitTeam(u)) then
			local ex, _, ez = spGetUnitPosition(u)
			local dd = sqrt((ex - x) ^ 2 + (ez - z) ^ 2)
			nearestEnemy = nearestEnemy and min(nearestEnemy, dd) or dd
		end
	end
	return { turretsNear = near, ownStart = ownStartDist(unitTeam, x, z), enemyStart = nearestEnemyStart(unitTeam, x, z), nearestEnemy = nearestEnemy and floor(nearestEnemy) or -1 }
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	if not enabled or not teams[unitTeam] or not builderID then
		return
	end
	local d, bd = defs[unitDefID], defs[Spring.GetUnitDefID(builderID) or -1]
	if not d or not bd then
		return
	end
	if bd.factory and isArmedMobile(d) then
		write({ type = "build", game = gameKey, frame = Spring.GetGameFrame(), team = unitTeam, factory = bd.name, chosen = d.name,
			options = optionTraits(bd, isArmedMobile), situation = teamSituation(unitTeam) })
	elseif (bd.builder or bd.commander) and isDefence(d) then
		local x, _, z = spGetUnitPosition(unitID)
		write({ type = "turretbuild", game = gameKey, frame = Spring.GetGameFrame(), team = unitTeam, chosen = d.name,
			options = optionTraits(bd, isDefence), situation = teamSituation(unitTeam), place = turretPlace(unitID, unitTeam, x, z) })
	end
end

-- each team's economy once a minute: benchmarks for ours
local function logEconomy(frame)
	for team in pairs(teams) do
		local m = { mex = 0, gen = 0, factories = 0, builders = 0, army = 0, turrets = 0 }
		for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
			local d = defs[Spring.GetUnitDefID(u) or -1]
			if d and not Spring.GetUnitIsBeingBuilt(u) then
				if d.mex > 0 then
					m.mex = m.mex + 1
				elseif d.energy > 0 then
					m.gen = m.gen + 1
				elseif d.factory then
					m.factories = m.factories + 1
				elseif d.builder then
					m.builders = m.builders + 1
				end
				if isArmedMobile(d) then
					m.army = m.army + d.cost
				elseif isDefence(d) then
					m.turrets = m.turrets + d.cost
				end
			end
		end
		local _, _, _, mInc = Spring.GetTeamResources(team, "metal")
		local _, _, _, eInc = Spring.GetTeamResources(team, "energy")
		write({ type = "eco", game = gameKey, frame = frame, team = team, minute = floor(frame / 1800), metalIncome = floor((mInc or 0) * 10) / 10,
			energyIncome = floor(eInc or 0), mex = m.mex, generators = m.gen, factories = m.factories, builders = m.builders,
			army = floor(m.army), turrets = floor(m.turrets) })
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if not enabled or not teams[unitTeam] then
		return
	end
	local d = defs[unitDefID]
	if not (isArmedMobile(d) or isDefence(d)) then
		return
	end
	local x, _, z = spGetUnitPosition(unitID)
	local sample = {
		type = isDefence(d) and "turret" or "unit",
		game = gameKey,
		frame = Spring.GetGameFrame(),
		team = unitTeam,
		unit = unitTraits(d),
		situation = teamSituation(unitTeam),
		kills = 0,
	}
	if isDefence(d) then
		-- where it stands: turrets around it, distance to both starts, nearest enemy now
		local near = 0
		for _, u in ipairs(Spring.GetUnitsInCylinder(x, z, 600, unitTeam)) do
			local od = defs[Spring.GetUnitDefID(u) or -1]
			if u ~= unitID and isDefence(od) then
				near = near + 1
			end
		end
		local nearestEnemy
		for _, u in ipairs(Spring.GetUnitsInCylinder(x, z, 3000)) do
			if enemyOf(unitTeam, Spring.GetUnitTeam(u)) then
				local ex, _, ez = spGetUnitPosition(u)
				local dd = sqrt((ex - x) ^ 2 + (ez - z) ^ 2)
				nearestEnemy = nearestEnemy and min(nearestEnemy, dd) or dd
			end
		end
		sample.place = { turretsNear = near, ownStart = ownStartDist(unitTeam, x, z), enemyStart = nearestEnemyStart(unitTeam, x, z), nearestEnemy = nearestEnemy and floor(nearestEnemy) or -1 }
	end
	tracked[unitID] = sample
end

local function finishTracked(unitID, died)
	local s = tracked[unitID]
	if not s then
		return
	end
	tracked[unitID] = nil
	s.lived = floor((Spring.GetGameFrame() - s.frame) / 30)
	s.died = died
	-- the engine's experience grows by 0.1 x experienceMult (0.3 in BAR) x (victim power / own power) x
	-- (damage / victim max health) per hit, plus the same with the whole victim per kill; power ~ cost.
	-- So experience / 0.03 x own cost = value of the damage dealt + value of the kills.
	local xp = Spring.GetUnitExperience(unitID) or 0
	local mult = 0.1 * ((Game.experienceMult or 0.3) > 0 and (Game.experienceMult or 0.3) or 0.3)
	s.xp = floor(xp * 10000 + 0.5) / 10000
	s.kills = floor(s.kills + 0.5)
	s.dealt = max(0, floor(xp / mult * s.unit.cost - s.kills + 0.5))
	write(s)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	if not enabled then
		return
	end
	destroyed[unitID] = Spring.GetGameFrame()
	-- the killing blow: credit the victim's value
	local killer = attackerID and tracked[attackerID]
	local vd = defs[unitDefID]
	if killer and vd and enemyOf(killer.team, unitTeam) then
		killer.kills = killer.kills + vd.cost
	end
	finishTracked(unitID, true)
end

----------------------------------------------------------------------------------------------------
-- fights: contacts every 5 s, outcome after 25 s
----------------------------------------------------------------------------------------------------

local function scanFights(frame)
	for team in pairs(teams) do
		local units = Spring.GetTeamUnits(team) or {}
		local seeds = {}
		for _, u in ipairs(units) do
			local d = defs[Spring.GetUnitDefID(u) or -1]
			if isArmedMobile(d) then
				local x, _, z = spGetUnitPosition(u)
				for _, e in ipairs(Spring.GetUnitsInCylinder(x, z, CONTACT)) do
					local et = Spring.GetUnitTeam(e)
					local ed = defs[Spring.GetUnitDefID(e) or -1]
					if enemyOf(team, et) and ed and ed.armed then
						seeds[#seeds + 1] = { x = x, z = z }
						break
					end
				end
			end
		end
		-- one fight per 800-elmo cell per team at a time
		for _, seed in ipairs(seeds) do
			local cell = team .. ":" .. floor(seed.x / 800) .. ":" .. floor(seed.z / 800)
			if (cellCooldown[cell] or -1e9) + FIGHT_WINDOW <= frame then
				cellCooldown[cell] = frame
				local own, enemy, ownTurrets = {}, {}, {}
				local cx, cz, n = 0, 0, 0
				for _, u in ipairs(Spring.GetUnitsInCylinder(seed.x, seed.z, GROUP, team)) do
					local info = unitInfo(u)
					local d = info and defs[info.defID]
					if d and isArmedMobile(d) then
						own[#own + 1] = info
						local x, _, z = spGetUnitPosition(u)
						cx, cz, n = cx + x, cz + z, n + 1
					elseif d and isDefence(d) then
						ownTurrets[#ownTurrets + 1] = info
					end
				end
				if n > 0 then
					cx, cz = cx / n, cz / n
					local ehx, ehn = 0, 0
					for _, u in ipairs(Spring.GetUnitsInCylinder(cx, cz, ENEMY_RADIUS)) do
						if enemyOf(team, Spring.GetUnitTeam(u)) then
							local info = unitInfo(u)
							local d = info and defs[info.defID]
							if d and d.armed and not Spring.GetUnitIsBeingBuilt(u) then
								enemy[#enemy + 1] = info
								local ex, ey, ez = spGetUnitPosition(u)
								ehx, ehn = ehx + ey, ehn + 1
							end
						end
					end
					if #enemy > 0 then
						local oh = 0
						for _, u in ipairs(own) do
							local _, y = spGetUnitPosition(u.id)
							oh = oh + y
						end
						local enemyTurrets = {}
						local enemyMobile = {}
						for _, e in ipairs(enemy) do
							if isDefence(defs[e.defID]) then
								enemyTurrets[#enemyTurrets + 1] = e
							else
								enemyMobile[#enemyMobile + 1] = e
							end
						end
						local ids = {}
						for _, u in ipairs(own) do
							ids[#ids + 1] = { u.id, cost(defs[u.defID]), 1 }
						end
						for _, u in ipairs(ownTurrets) do
							ids[#ids + 1] = { u.id, cost(defs[u.defID]), 1 }
						end
						for _, u in ipairs(enemy) do
							ids[#ids + 1] = { u.id, cost(defs[u.defID]), 0 }
						end
						pendingFights[#pendingFights + 1] = {
							due = frame + FIGHT_WINDOW,
							ids = ids,
							sample = {
								type = "fight",
								game = gameKey,
								frame = frame,
								team = team,
								own = summarize(own),
								ownTurrets = summarize(ownTurrets),
								enemy = summarize(enemyMobile),
								enemyTurrets = summarize(enemyTurrets),
								heightDiff = floor(oh / #own - ehx / max(ehn, 1)),
								ownStart = ownStartDist(team, cx, cz),
								enemyStart = nearestEnemyStart(team, cx, cz),
							},
						}
					end
				end
			end
		end
	end
end

-- micro: up to MICRO_PER_TEAM combat units per team within 1.5x their range of an armed enemy
local function round2(v)
	return floor(v * 100 + 0.5) / 100
end

local function scanMicro(frame)
	for team in pairs(teams) do
		local list = Spring.GetTeamUnits(team) or {}
		local n, picked = #list, 0
		local first = n > 0 and math.random(n) or 1
		for k = 0, n - 1 do
			if picked >= MICRO_PER_TEAM then
				break
			end
			local u = list[(first + k - 1) % n + 1]
			local d = defs[Spring.GetUnitDefID(u) or -1]
			if isArmedMobile(d) and d.range > 0 and not Spring.GetUnitIsBeingBuilt(u) then
				local e = Spring.GetUnitNearestEnemy(u, d.range * 1.5, false)
				local ed = e and defs[Spring.GetUnitDefID(e) or -1]
				if ed and ed.armed then
					local x, _, z = spGetUnitPosition(u)
					local ex, _, ez = spGetUnitPosition(e)
					local dx, dz = ex - x, ez - z
					local dist = max(sqrt(dx * dx + dz * dz), 1)
					-- moving toward (+1) or away from (-1) the enemy, as a share of top speed
					local vx, _, vz = Spring.GetUnitVelocity(u)
					local radial = ((vx or 0) * dx + (vz or 0) * dz) / dist * 30 / max(d.speed, 1)
					-- reloading = fired within its reload time
					local reload = Spring.GetUnitWeaponState(u, 1, "reloadState")
					local firing = reload and reload > frame or false
					local tType, _, target = Spring.GetUnitWeaponTarget(u, 1)
					local tStatic
					if tType == 1 and target then
						local td = defs[Spring.GetUnitDefID(target) or -1]
						tStatic = td and not td.mobile or false
					end
					-- ahead (+) of or behind (-) the armed units of its own team within 600, toward the enemy
					local sx, sz, m = 0, 0, 0
					for _, a in ipairs(Spring.GetUnitsInCylinder(x, z, 600, team)) do
						local ad = defs[Spring.GetUnitDefID(a) or -1]
						if isArmedMobile(ad) then
							local ax, _, az = spGetUnitPosition(a)
							sx, sz, m = sx + ax, sz + az, m + 1
						end
					end
					local ahead = m > 1 and ((x - sx / m) * dx + (z - sz / m) * dz) / dist or 0
					local hp, maxHp = Spring.GetUnitHealth(u)
					write({ type = "micro", game = gameKey, frame = frame, team = team, name = d.name, kind = d.kind, tech = d.tech,
						cost = cost(d), range = floor(d.range), speed = floor(d.speed), dist = floor(dist), eRange = floor(ed.range),
						eKind = ed.kind, eStatic = not ed.mobile, approach = round2(max(-1.5, min(1.5, radial))),
						hp = round2((hp or 0) / max(maxHp or 1, 1)), firing = firing, tStatic = tStatic, ahead = floor(ahead), group = m })
					picked = picked + 1
				end
			end
		end
	end
end

local function settleFights(frame)
	for i = #pendingFights, 1, -1 do
		local f = pendingFights[i]
		if frame >= f.due then
			local ownLost, enemyLost = 0, 0
			for _, e in ipairs(f.ids) do
				local died = destroyed[e[1]]
				if died and died >= f.sample.frame and died <= f.due then
					if e[3] == 1 then
						ownLost = ownLost + e[2]
					else
						enemyLost = enemyLost + e[2]
					end
				end
			end
			f.sample.ownLost, f.sample.enemyLost = ownLost, enemyLost
			write(f.sample)
			table.remove(pendingFights, i)
		end
	end
end

----------------------------------------------------------------------------------------------------

function widget:GameFrame(n)
	if not enabled then
		return
	end
	if n == 30 then
		-- start positions aren't always known at load: use each team's commander
		for t in pairs(teams) do
			if not starts[t] then
				for _, u in ipairs(Spring.GetTeamUnits(t) or {}) do
					local d = defs[Spring.GetUnitDefID(u) or -1]
					if d and d.commander then
						local x, _, z = spGetUnitPosition(u)
						starts[t] = { x = x, z = z }
					end
				end
			end
		end
	end
	if n % FIGHT_EVERY == 0 then
		scanFights(n)
	end
	if n % MICRO_EVERY == 45 then
		scanMicro(n)
	end
	if n % 1800 == 0 and n > 0 then
		logEconomy(n)
	end
	if n % 30 == 0 then
		settleFights(n)
		for u, s in pairs(tracked) do
			if n - s.frame >= UNIT_HORIZON then
				finishTracked(u, false)
			end
		end
	end
end

local function flushAll()
	for u in pairs(tracked) do
		finishTracked(u, false)
	end
	if out then
		write({ type = "end", game = gameKey, frame = Spring.GetGameFrame() })
		out:close()
		out = nil
	end
end

function widget:GameOver()
	flushAll()
end

function widget:Shutdown()
	flushAll()
end

function widget:Initialize()
	if not enabled then
		return
	end
	defs = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)
	local gaia = Spring.GetGaiaTeamID()
	for _, t in ipairs(Spring.GetTeamList() or {}) do
		if t ~= gaia then
			local _, _, _, _, side, ally = Spring.GetTeamInfo(t, false)
			teams[t] = ally
			local x, _, z = Spring.GetTeamStartPosition(t)
			if x and x > 0 then
				starts[t] = { x = x, z = z }
			end
		end
	end
	math.randomseed(os.time())
	gameKey = os.date("%Y%m%d-%H%M%S") .. "-" .. math.random(1000, 9999)
	out = io.open("datalog.jsonl", "w")
	write({ type = "start", game = gameKey, map = Game.mapName, mapX = Game.mapSizeX, mapZ = Game.mapSizeZ, version = 4 })
end
