--------------------------------------------------------------------------------
-- Sub-Commanders
--
-- Delegate units, factories and map zones to autonomous sub-commanders.
-- Each sub-commander owns a set of your units (builders, factories, army),
-- one or more zones on the map, a role (economy / defense / air defense /
-- army) and a spending posture (conserve / balanced / use all). It only
-- builds and fights inside its zones, factories it owns keep producing for
-- it, and anything its builders or factories make joins it automatically.
--
-- You stay in charge: giving any order to an assigned unit pauses the
-- sub-commander for that unit until the unit is idle again.
--
-- Panel: top-right. Text commands: /luaui sc help
-- Other widgets (e.g. an LLM advisor) can drive it through WG.SubCommanders.
--------------------------------------------------------------------------------

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Sub-Commanders",
		desc = "Delegate units, factories and map zones to autonomous sub-commanders. /luaui sc help",
		author = "karolis",
		date = "2026-10-12",
		license = "GNU GPL, v2 or later",
		layer = 5,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Engine shortcuts
--------------------------------------------------------------------------------

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGetFactoryCommandCount = Spring.GetFactoryCommandCount
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetGroundHeight = Spring.GetGroundHeight
local spGetGameFrame = Spring.GetGameFrame
local spGetSelectedUnits = Spring.GetSelectedUnits
local spEcho = Spring.Echo

local glColor = gl.Color
local glRect = gl.Rect
local glLineWidth = gl.LineWidth
local glVertex = gl.Vertex
local glDrawGroundCircle = gl.DrawGroundCircle

local max, min, abs, floor, sqrt = math.max, math.min, math.abs, math.floor, math.sqrt
local cos, sin, atan2, pi, random = math.cos, math.sin, math.atan2, math.pi, math.random
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat
local sformat = string.format

local CMD_PRIORITY = GameCMD and GameCMD.PRIORITY

local MAP_X, MAP_Z = Game.mapSizeX, Game.mapSizeZ
local EXTRACTOR_RADIUS = Game.extractorRadius or 80
local AVG_WIND = ((Game.windMin or 0) + (Game.windMax or 0)) * 0.5
local TIDAL = Game.tidal or 0

local THINK_EVERY = 15 -- frames between scheduler passes (0.5 s)
local COMBAT_EVERY = 30 -- frames between combat / bookkeeping passes
local BUILDER_COOLDOWN = 45 -- min frames between decisions for one builder
local SOFT_TASK_FRAMES = 30 * 20 -- assist / reclaim / patrol tasks are re-evaluated after this
local MANUAL_HOLD_FRAMES = 30 * 10 -- after a player order, leave the unit alone at least this long
local MAX_THINKS_PER_PASS = 8

--------------------------------------------------------------------------------
-- Roles and postures
--------------------------------------------------------------------------------

local ROLES = { "economy", "defense", "airdefense", "army", "intelligence" }
local ROLE_INFO = {
	economy = { label = "Economy", short = "ECO" },
	defense = { label = "Defense", short = "DEF" },
	airdefense = { label = "Air Defense", short = "AA" },
	army = { label = "Army", short = "ARMY" },
	intelligence = { label = "Intelligence", short = "INTEL" },
}

-- minM/minE: don't start new spending below this fraction of storage
-- capBase/capInc: most expensive single thing allowed = capBase + capInc * metal income
local POSTURES = { "conserve", "balanced", "spend" }
local POSTURE_INFO = {
	conserve = { label = "Conserve", minM = 0.5, minE = 0.4, capBase = 90, capInc = 8, builders = 2, army = 6, density = 1, priority = 0 },
	balanced = { label = "Balanced", minM = 0.12, minE = 0.2, capBase = 220, capInc = 18, builders = 6, army = 16, density = 2, priority = 1 },
	spend = { label = "Use all", minM = 0.0, minE = 0.08, capBase = 450, capInc = 40, builders = 8, army = 40, density = 4, priority = 1 },
}

local PALETTE = {
	{ 1.00, 0.76, 0.20 },
	{ 0.30, 0.80, 1.00 },
	{ 0.55, 1.00, 0.40 },
	{ 1.00, 0.45, 0.80 },
	{ 0.75, 0.55, 1.00 },
	{ 1.00, 0.50, 0.30 },
	{ 0.40, 1.00, 0.85 },
	{ 1.00, 1.00, 0.50 },
}

-- player orders that mean "I'm taking this unit for now" (value: name for messages)
local MANUAL_CMDS = {}
for _, name in ipairs({ "STOP", "MOVE", "FIGHT", "PATROL", "ATTACK", "AREA_ATTACK", "GUARD", "REPAIR", "RECLAIM", "RESURRECT", "CAPTURE", "RESTORE", "LOAD_UNITS", "UNLOAD_UNITS", "UNLOAD_UNIT", "WAIT", "MANUALFIRE", "DGUN" }) do
	if CMD[name] then
		MANUAL_CMDS[CMD[name]] = name:lower():gsub("_", " ")
	end
end

--------------------------------------------------------------------------------
-- Unit classification (computed once)
--------------------------------------------------------------------------------

local EXCLUDED_DEFENSE_GROUPS = { nuke = true, antinuke = true, explo = true, emp = true }

local defs = {}
for defID, ud in pairs(UnitDefs) do
	local cp = ud.customParams or {}
	local mobile = (ud.speed or 0) > 0 and not ud.isFactory
	local buildOptions = ud.buildOptions or {}
	local weapons = ud.weapons or {}
	local aaOnly = #weapons > 0
	for i = 1, #weapons do
		local only = weapons[i].onlyTargets or {}
		if not only.vtol then
			aaOnly = false
		end
	end
	local energy = (ud.energyMake or 0) - (ud.energyUpkeep or 0)
	if (ud.windGenerator or 0) > 0 then
		energy = energy + min(ud.windGenerator, AVG_WIND)
	end
	if (ud.tidalGenerator or 0) > 0 then
		energy = energy + ud.tidalGenerator * TIDAL
	end
	local group = cp.unitgroup
	local d = {
		name = ud.name,
		human = ud.translatedHumanName or ud.humanName or ud.name,
		group = group,
		tech = floor(tonumber(cp.techlevel) or 1),
		cost = (ud.metalCost or 0) + (ud.energyCost or 0) / 60,
		metal = ud.metalCost or 0,
		energyCost = ud.energyCost or 0,
		hx = (ud.xsize or 2) * 4,
		hz = (ud.zsize or 2) * 4,
		mobile = mobile,
		air = ud.canFly and true or false,
		commander = cp.iscommander and true or false,
		factory = ud.isFactory and true or false,
		options = buildOptions,
		armed = #weapons > 0,
		range = ud.maxWeaponRange or 0,
	}
	d.aaOnly = d.armed and (aaOnly or group == "aa")
	d.builder = ud.isBuilder and mobile and #buildOptions > 0
	d.reclaimer = d.builder and ud.canReclaim and (ud.reclaimSpeed or 0) > 0
	d.nano = ud.isBuilder and not mobile and not ud.isFactory and (ud.buildSpeed or 0) > 0
	d.buildRange = ud.buildDistance or 0
	d.combat = mobile and d.armed and not d.builder and (ud.transportCapacity or 0) == 0
	d.staticDef = not mobile and not ud.isFactory and not ud.isBuilder and d.armed and not EXCLUDED_DEFENSE_GROUPS[group] and d.range > 0 and d.range <= 1200 and not cp.stockpilelimit
	d.mex = (ud.extractsMetal or 0) > 0 and not mobile and ud.extractsMetal or 0
	d.energy = (not mobile and group == "energy" and not cp.geothermal and energy > 0) and energy or 0
	d.conv = (not mobile and tonumber(cp.energyconv_capacity)) or 0
	d.mstore = (not mobile and d.mex == 0 and group == "metal" and (ud.metalStorage or 0) >= 500) and ud.metalStorage or 0
	d.estore = (not mobile and d.energy == 0 and group == "energy" and (ud.energyStorage or 0) >= 1000) and ud.energyStorage or 0
	d.radar = (not mobile and not d.armed and (ud.radarDistance or 0) >= 1200 and d.cost < 200) and ud.radarDistance or 0
	-- intelligence
	d.radarRange = ud.radarDistance or 0
	d.jammer = (ud.radarDistanceJam or 0) > 0 and ud.radarDistanceJam or 0
	d.sonar = (not mobile and (ud.sonarDistance or 0) > 0) and ud.sonarDistance or 0
	d.seismic = (ud.seismicDistance or 0) > 0 and ud.seismicDistance or 0
	d.sight = ud.sightDistance or ud.losRadius or 0
	d.camera = not mobile and not d.armed and (ud.cloakCost or 0) > 0 and d.cost < 100
	d.scout = mobile and not d.builder and not d.air and d.cost < 45 and (ud.speed or 0) >= 120 and d.sight >= 550
	d.spy = mobile and (ud.cloakCost or 0) > 0 and ud.stealth and d.builder and not d.commander
	d.intelStructure = not mobile and (d.radarRange >= 1000 or d.jammer > 0 or d.sonar > 0 or d.seismic > 0 or d.camera)
	-- what a weapon loadout says about a unit
	local bomb, arty = false, false
	d.dps = 0
	for i = 1, #weapons do
		local wd = WeaponDefs[weapons[i].weaponDef]
		if wd then
			bomb = bomb or wd.type == "AircraftBomb"
			arty = arty or (wd.highTrajectory == 1 and (wd.range or 0) >= 600)
			local dmg = wd.damages and wd.damages[0] or 0
			d.dps = d.dps + dmg * (wd.salvoSize or 1) * (wd.projectiles or 1) / max(wd.reload or 1, 0.1)
		end
	end
	local move = ud.moveDef and ud.moveDef.name or ""
	d.naval = mobile and not d.air and (move:find("boat") ~= nil or (ud.minWaterDepth or 0) > 0)
	d.hover = mobile and move:find("hover") ~= nil
	d.speed = ud.speed or 0
	d.health = ud.health or 0
	d.transport = (ud.transportCapacity or 0) > 0
	if d.commander then
		d.kind = "commander"
	elseif ud.isFactory then
		d.kind = "factory"
	elseif d.builder or d.nano then
		d.kind = "constructor"
	elseif not mobile then
		if d.staticDef then
			d.kind = d.aaOnly and "anti-air turret" or "turret"
		elseif d.armed and d.range > 1200 then
			d.kind = "long-range artillery"
		elseif d.intelStructure then
			d.kind = d.jammer > 0 and "jammer" or (d.camera and "camera" or "radar")
		else
			d.kind = "economy"
		end
	elseif d.air then
		d.kind = d.transport and "air transport" or (not d.armed and "scout plane") or (d.aaOnly and "fighter") or (bomb and "bomber") or "gunship"
	elseif d.naval then
		d.kind = "naval"
	elseif not d.armed then
		d.kind = d.jammer > 0 and "mobile jammer" or (d.radarRange > 0 and "mobile radar" or "utility")
	elseif d.aaOnly then
		d.kind = "mobile anti-air"
	elseif arty then
		d.kind = "artillery"
	elseif d.scout then
		d.kind = "scout"
	elseif d.range >= 500 then
		d.kind = "skirmisher"
	elseif d.speed >= 70 and d.cost <= 120 then
		d.kind = "raider"
	elseif d.cost >= 300 or d.health >= 2000 then
		d.kind = "heavy"
	else
		d.kind = "assault"
	end
	if d.hover and d.mobile and not d.air then
		d.kind = "hover " .. d.kind
	end
	defs[defID] = d
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local myTeam = Spring.GetMyTeamID()
local myAlly = Spring.GetMyAllyTeamID()
local myPlayer = Spring.GetMyPlayerID()
local frame = 0
local canControl = true

local subs = {} -- ordered list of sub-commanders
local nextSubID = 1
local owner = {} -- unitID -> sub
local ustate = {} -- unitID -> per-unit bookkeeping
local planned = {} -- builderID -> { sub, defID, x, z, frame }
local badSpots = {} -- { x, z, untilFrame }
local spotCooldown = {} -- metal spot index -> frame it may be retried
local enemySightings = {} -- ring buffer of { x, z, frame }
local baseThreats = {} -- enemies inside any sub-commander's zone (refreshed every combat pass)
-- enemy units we identified: units[unitID] = { defID, first, last, x, z }
local Enemy = { units = {}, known = 0, mixFrame = -1 }
local econ = { m = 0, mS = 1, mInc = 0, e = 0, eS = 1, eInc = 0, ePull = 0, mFrac = 0, eFrac = 0 }

local activeSub -- sub selected in the panel
local zoneTool -- { sub, keep } when drawing zones
local zoneDrag -- { x1, z1, x2, z2 } while dragging
local savedConfig -- from SetConfigData, used to restore after /luaui reload
local orderInput -- { sub, text } while typing standing orders
local startOrderInput, stopOrderInput -- defined with the panel

local panel = { x = nil, y = nil, collapsed = false, dragging = false }
local buttons = {}
local font

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function dist2(x1, z1, x2, z2)
	local dx, dz = x1 - x2, z1 - z2
	return dx * dx + dz * dz
end

local function unitDef(unitID)
	local defID = Spring.GetUnitDefID(unitID)
	return defID and defs[defID], defID
end

local function isAlive(unitID)
	return Spring.GetUnitIsDead(unitID) == false
end

local function isEnemyUnit(unitID)
	local ally = Spring.GetUnitAllyTeam(unitID)
	return ally ~= nil and ally ~= myAlly
end

local function log(sub, text)
	if sub.log[1] and sub.log[1].text == text then
		sub.log[1].frame = frame
		sub.log[1].count = (sub.log[1].count or 1) + 1
		return
	end
	tinsert(sub.log, 1, { frame = frame, text = text })
	if #sub.log > 40 then
		sub.log[#sub.log] = nil
	end
	sub.status = text
end

local function econUpdate()
	local m, mS, mPull, mInc = Spring.GetTeamResources(myTeam, "metal")
	local e, eS, ePull, eInc = Spring.GetTeamResources(myTeam, "energy")
	if not m then
		return
	end
	econ.m, econ.mS, econ.mPull, econ.mInc = m, max(mS, 1), mPull, mInc
	econ.e, econ.eS, econ.ePull, econ.eInc = e, max(eS, 1), ePull, eInc
	econ.mFrac = m / econ.mS
	econ.eFrac = e / econ.eS
	-- what our energy converters burn (they switch themselves off when energy runs low)
	if frame - (econ.convFrame or -999) >= 90 then
		econ.convFrame = frame
		local use = 0
		for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
			local ud = unitDef(u)
			if ud and ud.conv > 0 then
				local _, _, _, eUse = Spring.GetUnitResources(u)
				use = use + (eUse or 0)
			end
		end
		econ.convUse = use
	end
	-- energy demand without the converters: what "short of energy" should be judged on
	econ.eNeed = max(0, (econ.ePull or 0) - (econ.convUse or 0))
end

--------------------------------------------------------------------------------
-- Zones
-- rect:   { kind = "rect", x1, z1, x2, z2 }
-- circle: { kind = "circle", x, z, r }
--------------------------------------------------------------------------------

local Zone = {}

function Zone.contains(zone, x, z, margin)
	margin = margin or 0
	if zone.kind == "circle" then
		local r = zone.r + margin
		return dist2(x, z, zone.x, zone.z) <= r * r
	end
	return x >= zone.x1 - margin and x <= zone.x2 + margin and z >= zone.z1 - margin and z <= zone.z2 + margin
end

function Zone.center(zone)
	if zone.kind == "circle" then
		return zone.x, zone.z
	end
	return (zone.x1 + zone.x2) * 0.5, (zone.z1 + zone.z2) * 0.5
end

function Zone.area(zone)
	if zone.kind == "circle" then
		return pi * zone.r * zone.r
	end
	return (zone.x2 - zone.x1) * (zone.z2 - zone.z1)
end

function Zone.bounds(zone, margin)
	margin = margin or 0
	if zone.kind == "circle" then
		return zone.x - zone.r - margin, zone.z - zone.r - margin, zone.x + zone.r + margin, zone.z + zone.r + margin
	end
	return zone.x1 - margin, zone.z1 - margin, zone.x2 + margin, zone.z2 + margin
end

function Zone.randomPoint(zone, margin)
	margin = margin or 0
	if zone.kind == "circle" then
		local a, r = random() * 2 * pi, sqrt(random()) * max(zone.r - margin, 1)
		return zone.x + cos(a) * r, zone.z + sin(a) * r
	end
	local x1, z1, x2, z2 = zone.x1 + margin, zone.z1 + margin, zone.x2 - margin, zone.z2 - margin
	if x2 < x1 then
		x1, x2 = (zone.x1 + zone.x2) * 0.5, (zone.x1 + zone.x2) * 0.5
	end
	if z2 < z1 then
		z1, z2 = (zone.z1 + zone.z2) * 0.5, (zone.z1 + zone.z2) * 0.5
	end
	return x1 + random() * (x2 - x1), z1 + random() * (z2 - z1)
end

-- furthest point of the zone in the direction of (tx, tz), pulled in by margin
function Zone.edgeToward(zone, tx, tz, margin)
	local cx, cz = Zone.center(zone)
	local dx, dz = tx - cx, tz - cz
	local len = sqrt(dx * dx + dz * dz)
	if len < 1 then
		return cx, cz
	end
	dx, dz = dx / len, dz / len
	if zone.kind == "circle" then
		local r = max(zone.r - margin, 0)
		return cx + dx * r, cz + dz * r
	end
	local hx, hz = (zone.x2 - zone.x1) * 0.5 - margin, (zone.z2 - zone.z1) * 0.5 - margin
	local t = math.huge
	if abs(dx) > 1e-3 then
		t = min(t, max(hx, 0) / abs(dx))
	end
	if abs(dz) > 1e-3 then
		t = min(t, max(hz, 0) / abs(dz))
	end
	if t == math.huge then
		t = 0
	end
	return cx + dx * t, cz + dz * t
end

function Zone.units(zone, margin)
	if zone.kind == "circle" then
		return spGetUnitsInCylinder(zone.x, zone.z, zone.r + (margin or 0))
	end
	local x1, z1, x2, z2 = Zone.bounds(zone, margin)
	return Spring.GetUnitsInRectangle(x1, z1, x2, z2)
end

local function inSubZones(sub, x, z, margin)
	local zones = sub.zones
	if #zones == 0 then
		return true
	end
	for i = 1, #zones do
		if Zone.contains(zones[i], x, z, margin) then
			return true
		end
	end
	return false
end

local function nearestZone(sub, x, z)
	local best, bestD
	for i = 1, #sub.zones do
		local cx, cz = Zone.center(sub.zones[i])
		local d = dist2(x, z, cx, cz)
		if not bestD or d < bestD then
			best, bestD = sub.zones[i], d
		end
	end
	return best
end

local function largestZone(sub)
	local best, bestA
	for i = 1, #sub.zones do
		local a = Zone.area(sub.zones[i])
		if not bestA or a > bestA then
			best, bestA = sub.zones[i], a
		end
	end
	return best
end

local function clampToMap(x, z)
	return max(64, min(MAP_X - 64, x)), max(64, min(MAP_Z - 64, z))
end

--------------------------------------------------------------------------------
-- Enemy knowledge
--------------------------------------------------------------------------------

local enemyStarts

local function getEnemyStarts()
	if enemyStarts then
		return enemyStarts
	end
	enemyStarts = {}
	for _, teamID in ipairs(Spring.GetTeamList() or {}) do
		local _, _, _, _, _, allyTeam = Spring.GetTeamInfo(teamID, false)
		if allyTeam and allyTeam ~= myAlly then
			local x, _, z = Spring.GetTeamStartPosition(teamID)
			if x and x > 0 and z and z > 0 then
				enemyStarts[#enemyStarts + 1] = { x = x, z = z }
			end
		end
	end
	if #enemyStarts == 0 then
		-- not revealed: guess the point mirrored through the map centre (right for most 1v1 maps)
		local x, _, z = Spring.GetTeamStartPosition(myTeam)
		if not x or x <= 0 then
			local u = (Spring.GetTeamUnits(myTeam) or {})[1]
			if u then
				x, _, z = spGetUnitPosition(u)
			end
		end
		if x then
			enemyStarts[1] = { x = MAP_X - x, z = MAP_Z - z, guess = true }
		else
			enemyStarts = nil
			return {}
		end
	end
	return enemyStarts
end

-- What the enemy fields, from units seen in the last `window` frames: counts per
-- kind (mobile units and defences) plus the share of kinds that matter for counters.
local COMPOSITION_WINDOW = 30 * 60 * 5

function Enemy.mix()
	if Enemy.mixFrame == frame then
		return Enemy.mixCache
	end
	Enemy.mixFrame = frame
	local mix = { total = 0, air = 0, bombers = 0, ranged = 0, raiders = 0, heavy = 0, naval = 0, tech2 = 0, kinds = {}, recentKinds = {}, types = {} }
	for _, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if frame - e.last < COMPOSITION_WINDOW and (d.mobile or d.staticDef) and d.kind ~= "constructor" and d.kind ~= "commander" then
			mix.total = mix.total + 1
			mix.kinds[d.kind] = (mix.kinds[d.kind] or 0) + 1
			if frame - e.first < 30 * 180 then
				mix.recentKinds[d.kind] = (mix.recentKinds[d.kind] or 0) + 1
			end
			mix.types[d.human] = (mix.types[d.human] or 0) + 1
			if d.air and d.armed and not d.aaOnly then
				mix.air = mix.air + 1
				if d.kind == "bomber" then
					mix.bombers = mix.bombers + 1
				end
			end
			if d.kind == "artillery" or d.kind == "skirmisher" or d.kind == "long-range artillery" then
				mix.ranged = mix.ranged + 1
			elseif d.kind:find("raider") or d.kind:find("scout") then
				mix.raiders = mix.raiders + 1
			elseif d.kind:find("heavy") then
				mix.heavy = mix.heavy + 1
			end
			if d.naval then
				mix.naval = mix.naval + 1
			end
			if d.tech >= 2 then
				mix.tech2 = mix.tech2 + 1
			end
		end
	end
	Enemy.mixCache = mix
	return mix
end

-- metal value of armed enemy units seen near (x, z) in the last 20 s
function Enemy.powerNear(x, z, r)
	local power = 0
	for _, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if d.mobile and d.armed and frame - e.last < 30 * 20 and dist2(x, z, e.x, e.z) < r * r then
			power = power + d.cost
		end
	end
	return power
end

-- share of a counter-relevant group in what the enemy fields (0 when nothing seen)
function Enemy.share(field)
	local mix = Enemy.mix()
	return mix.total > 0 and mix[field] / mix.total or 0
end

-- where we expect the enemy to come from, as seen from (x, z)
local function enemyDirectionRef(x, z)
	local best, bestD
	for i = 1, #enemySightings do
		local s = enemySightings[i]
		if frame - s.frame < 30 * 180 then
			local d = dist2(x, z, s.x, s.z)
			if not bestD or d < bestD then
				best, bestD = s, d
			end
		end
	end
	if best then
		return best.x, best.z
	end
	for _, s in ipairs(getEnemyStarts()) do
		local d = dist2(x, z, s.x, s.z)
		if not bestD or d < bestD then
			best, bestD = s, d
		end
	end
	if best then
		return best.x, best.z
	end
	return MAP_X * 0.5, MAP_Z * 0.5
end

--------------------------------------------------------------------------------
-- Orders (every order we give is remembered so we can tell it apart from the
-- player's own orders in UnitCommand)
--------------------------------------------------------------------------------

local function getState(unitID)
	local st = ustate[unitID]
	if not st then
		st = { nextThink = 0, expect = {} }
		ustate[unitID] = st
	end
	return st
end

local function order(unitID, cmdID, params, opts)
	if not canControl then
		return false
	end
	local st = getState(unitID)
	st.expect[cmdID] = frame
	Spring.GiveOrderToUnit(unitID, cmdID, params or {}, opts or {})
	return true
end

local function setTask(unitID, kind, text, soft, x, z)
	local st = getState(unitID)
	st.task = { kind = kind, text = text, frame = frame, soft = soft, x = x, z = z }
	st.softUntil = soft and (frame + SOFT_TASK_FRAMES) or nil
end

--------------------------------------------------------------------------------
-- Build placement
--------------------------------------------------------------------------------

local function metalSpots()
	local finder = WG.resource_spot_finder
	if finder and not finder.isMetalMap and finder.metalSpotsList then
		return finder.metalSpotsList
	end
end

local function nearMetalSpot(x, z, d)
	local spots = metalSpots()
	if not spots then
		return false
	end
	local r = EXTRACTOR_RADIUS + max(d.hx, d.hz) + 16
	local r2 = r * r
	for i = 1, #spots do
		if dist2(x, z, spots[i].x, spots[i].z) < r2 then
			return true
		end
	end
	return false
end

local function isBadSpot(x, z)
	for i = #badSpots, 1, -1 do
		local b = badSpots[i]
		if b.untilFrame < frame then
			tremove(badSpots, i)
		elseif dist2(x, z, b.x, b.z) < 96 * 96 then
			return true
		end
	end
	return false
end

-- half extents of a footprint for a build facing (0 south, 1 east, 2 north, 3 west)
local function halfSize(d, facing)
	if facing == 1 or facing == 3 then
		return d.hz, d.hx
	end
	return d.hx, d.hz
end

-- The player's own constructors (not ours, or taken over): what they have queued, so we
-- never build on a spot the player picked. Refreshed every 2 s: list of { defID, x, z, facing, builder }.
local Player = { plans = {}, builders = {}, frame = -999 }

function Player.refresh()
	if frame - Player.frame < 60 then
		return
	end
	Player.frame = frame
	local plans, builders = {}, {}
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d = unitDef(u)
		if d and (d.builder or d.commander) then
			local st = ustate[u]
			if not owner[u] or (st and st.manual) then
				builders[#builders + 1] = u
				for _, c in ipairs(Spring.GetUnitCommands(u, 12) or {}) do
					if c.id < 0 and defs[-c.id] and c.params[3] then
						plans[#plans + 1] = { defID = -c.id, x = c.params[1], z = c.params[3], facing = c.params[4] or 0, builder = u }
					end
				end
			end
		end
	end
	Player.plans, Player.builders = plans, builders
	-- the player is building while metal is short: sub-commanders step back
	local building = false
	for _, u in ipairs(builders) do
		if Spring.GetUnitIsBuilding(u) then
			building = true
			break
		end
	end
	Player.yield = building and econ.mFrac < 0.3
end

local function plannedConflict(d, x, z, gap, facing)
	local hx, hz = halfSize(d, facing or 0)
	for _, p in pairs(planned) do
		local phx, phz = halfSize(defs[p.defID], p.facing or 0)
		if abs(p.x - x) < hx + phx + gap and abs(p.z - z) < hz + phz + gap then
			return true
		end
	end
	for _, p in ipairs(Player.plans) do
		local phx, phz = halfSize(defs[p.defID], p.facing or 0)
		if abs(p.x - x) < hx + phx + gap and abs(p.z - z) < hz + phz + gap then
			return true
		end
	end
	return false
end

-- Factories need clear ground in front of their exit and room around them.
local EXIT_LANE = 300
local EXIT_LANE_AIR = 140
local FACTORY_RING = 64

local function makesAircraft(fd)
	if fd.airPlant == nil then
		fd.airPlant = false
		for _, o in ipairs(fd.options) do
			if defs[o] and defs[o].air then
				fd.airPlant = true
				break
			end
		end
	end
	return fd.airPlant
end

-- keep-out rectangles { x1, z1, x2, z2 } for own and allied factories (frames included), cached per frame
local keepOut, keepOutFrame = {}, -1
local function factoryKeepOut()
	if keepOutFrame == frame then
		return keepOut
	end
	keepOutFrame = frame
	keepOut = {}
	for _, teamID in ipairs(Spring.GetTeamList(myAlly) or {}) do
		for _, u in ipairs(Spring.GetTeamUnits(teamID) or {}) do
			local fd = unitDef(u)
			if fd and fd.factory then
				local x, _, z = spGetUnitPosition(u)
				local facing = Spring.GetUnitBuildFacing(u) or 0
				local hx, hz = halfSize(fd, facing)
				local lane = makesAircraft(fd) and EXIT_LANE_AIR or EXIT_LANE
				local w = 24 -- lane is a bit wider than the factory
				keepOut[#keepOut + 1] = { x - hx - FACTORY_RING, z - hz - FACTORY_RING, x + hx + FACTORY_RING, z + hz + FACTORY_RING }
				if facing == 0 then
					keepOut[#keepOut + 1] = { x - hx - w, z + hz, x + hx + w, z + hz + lane }
				elseif facing == 1 then
					keepOut[#keepOut + 1] = { x + hx, z - hz - w, x + hx + lane, z + hz + w }
				elseif facing == 2 then
					keepOut[#keepOut + 1] = { x - hx - w, z - hz - lane, x + hx + w, z - hz }
				else
					keepOut[#keepOut + 1] = { x - hx - lane, z - hz - w, x - hx, z + hz + w }
				end
			end
		end
	end
	return keepOut
end

local function blocksFactory(x, z, hx, hz)
	for _, r in ipairs(factoryKeepOut()) do
		if x + hx > r[1] and x - hx < r[3] and z + hz > r[2] and z - hz < r[4] then
			return true
		end
	end
	return false
end

-- A grid of lanes across the whole map stays free of our structures, so units can always
-- get through; buildings pack into the blocks between lanes. Factories and extractors are
-- exempt (they go where they must), and so is anything too big for a block.
local Lanes = { spacing = 320, width = 56 }

function Lanes.blocks(d, x, z, hx, hz)
	if d.factory or d.mex > 0 or 2 * max(hx, hz) > Lanes.spacing - Lanes.width then
		return false
	end
	local S, half = Lanes.spacing, Lanes.width * 0.5
	local lx = floor(x / S + 0.5) * S
	local lz = floor(z / S + 0.5) * S
	return abs(x - lx) < hx + half or abs(z - lz) < hz + half
end

-- space to keep around a structure inside a block: tight packing, more for things that blow up big
function Lanes.gapFor(d)
	if d.estore > 0 or d.energy >= 250 or d.factory then
		return 64
	elseif d.staticDef then
		return 32
	end
	return 8
end

-- footprints (plus gap) must not overlap any structure, so units keep walking lanes
local MAX_HALF = 96
local function areaClear(d, x, z, gap, facing)
	local hx, hz = halfSize(d, facing or 0)
	if Lanes.blocks(d, x, z, hx, hz) then
		return false
	end
	local reach = max(gap, 64) + MAX_HALF
	local units = Spring.GetUnitsInRectangle(x - hx - reach, z - hz - reach, x + hx + reach, z + hz + reach)
	for i = 1, #units do
		local od = unitDef(units[i])
		if od and not od.mobile then
			local ox, _, oz = spGetUnitPosition(units[i])
			local ohx, ohz = halfSize(od, Spring.GetUnitBuildFacing(units[i]) or 0)
			local g = max(gap, Lanes.gapFor(od))
			if abs(ox - x) < hx + ohx + g and abs(oz - z) < hz + ohz + g then
				return false
			end
		end
	end
	return not blocksFactory(x, z, hx, hz) and not plannedConflict(d, x, z, gap, facing)
end

-- Search outward from (ax, az) for a buildable spot inside the sub's zones.
-- opts: gap, rings, facing, samples, score(x, z) -> number (higher is better)
local function findBuildSpot(sub, defID, ax, az, opts)
	opts = opts or {}
	local d = defs[defID]
	local gap = opts.gap or 24
	local facing = opts.facing or 0
	local step = max(48, max(d.hx, d.hz) + gap)
	local rings = opts.rings or 14
	local wanted = opts.score and (opts.samples or 6) or 1
	local best, bestX, bestZ
	local found = 0
	local offset = random() * 2 * pi
	for ring = 0, rings do
		local n = ring == 0 and 1 or ring * 6
		for k = 0, n - 1 do
			local a = offset + k / n * 2 * pi
			local x, z = ax + cos(a) * ring * step, az + sin(a) * ring * step
			if x > 64 and z > 64 and x < MAP_X - 64 and z < MAP_Z - 64 and inSubZones(sub, x, z) then
				local bx, by, bz = Spring.Pos2BuildPos(defID, x, spGetGroundHeight(x, z), z, facing)
				if Spring.TestBuildOrder(defID, bx, by, bz, facing) > 0 and not nearMetalSpot(bx, bz, d) and not isBadSpot(bx, bz) and areaClear(d, bx, bz, gap, facing) then
					local s = opts.score and opts.score(bx, bz) or 0
					if not best or s > best then
						best, bestX, bestZ = s, bx, bz
					end
					found = found + 1
					if found >= wanted then
						return bestX, bestZ
					end
				end
			end
		end
	end
	return bestX, bestZ
end

local function facingToward(x, z, tx, tz)
	local dx, dz = tx - x, tz - z
	if abs(dx) > abs(dz) then
		return dx > 0 and 1 or 3
	end
	return dz > 0 and 0 or 2
end

local function issueBuild(sub, unitID, defID, x, z, facing, why)
	local d = defs[defID]
	if not order(unitID, -defID, { x, spGetGroundHeight(x, z), z, facing or 0 }) then
		return false
	end
	planned[unitID] = { sub = sub, defID = defID, x = x, z = z, facing = facing or 0, frame = frame }
	setTask(unitID, "build", d.human, false, x, z)
	getState(unitID).task.started = false
	log(sub, sformat("%s (%s)", d.human, why))
	return true
end

--------------------------------------------------------------------------------
-- Budget
--------------------------------------------------------------------------------

local function costCap(sub, factor)
	local p = POSTURE_INFO[sub.posture]
	return (p.capBase + p.capInc * max(econ.mInc, 0)) * (factor or 1)
end

-- what: a defs[] entry or a plain metal amount
-- kind: nil | "essential" (mex / energy when short: always worth it) | "energy"
local function canSpend(sub, what, kind)
	local p = POSTURE_INFO[sub.posture]
	local cost, metal, energy
	if type(what) == "table" then
		cost, metal, energy = what.cost, what.metal, what.energyCost
	else
		cost, metal, energy = what, what, 0
	end
	if cost > costCap(sub, kind == "essential" and 1.5 or 1) then
		return false
	end
	if kind == "essential" then
		return true
	end
	if metal > 20 and econ.mFrac < (Player.yield and max(p.minM, 0.25) or p.minM) then
		return false
	end
	if kind ~= "energy" and energy > 50 and econ.eFrac < p.minE then
		return false
	end
	return true
end

local function buildableBy(builderDef, filter)
	local list = {}
	for _, o in ipairs(builderDef.options) do
		local od = defs[o]
		if od and filter(od, o) then
			list[#list + 1] = o
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Builder jobs. Each returns true if it gave the unit something to do.
--------------------------------------------------------------------------------

local Jobs = {}

local function extractorAt(spot)
	local units = spGetUnitsInCylinder(spot.x, spot.z, EXTRACTOR_RADIUS)
	for i = 1, #units do
		local d = unitDef(units[i])
		if d and d.mex > 0 then
			return units[i], d
		end
	end
end

local function enemiesNear(x, z, r)
	local units = spGetUnitsInCylinder(x, z, r)
	for i = 1, #units do
		if isEnemyUnit(units[i]) then
			return true
		end
	end
	return false
end

-- a metal spot outside the zones worth taking: closer to our zones than to the enemy,
-- not too far, and no enemy seen or known defence near it lately
function Jobs.safeExpansion(sub, spot)
	local zone = nearestZone(sub, spot.x, spot.z)
	if not zone then
		return false
	end
	local zx, zz = Zone.center(zone)
	local dHome = sqrt(dist2(spot.x, spot.z, zx, zz))
	if dHome > 3500 then
		return false
	end
	for _, st in ipairs(getEnemyStarts()) do
		if sqrt(dist2(spot.x, spot.z, st.x, st.z)) < dHome * 1.15 then
			return false
		end
	end
	for i = #enemySightings, 1, -1 do
		local e = enemySightings[i]
		if frame - e.frame > 30 * 90 then
			break
		end
		if dist2(spot.x, spot.z, e.x, e.z) < 900 * 900 then
			return false
		end
	end
	for _, e in pairs(Enemy.units) do
		if defs[e.defID].staticDef and dist2(spot.x, spot.z, e.x, e.z) < 800 * 800 then
			return false
		end
	end
	return true
end

function Jobs.mex(sub, unitID, d, ux, uz)
	local spots = metalSpots()
	local finder = WG.resource_spot_finder
	if not spots or not finder or not finder.GetBuildingPositions then
		return false
	end
	local bestMex, bestYield = nil, 0
	for _, o in ipairs(d.options) do
		if defs[o].mex > bestYield then
			bestMex, bestYield = o, defs[o].mex
		end
	end
	if not bestMex or not canSpend(sub, defs[bestMex], "essential") then
		return false
	end
	local candidates = {}
	for i = 1, #spots do
		local spot = spots[i]
		local inZone = inSubZones(sub, spot.x, spot.z)
		-- economy also expands to safe spots on our side of the map beyond its zones
		if (spotCooldown[i] or 0) <= frame and (inZone or (sub.role == "economy" and Jobs.safeExpansion(sub, spot))) and not plannedConflict(defs[bestMex], spot.x, spot.z, EXTRACTOR_RADIUS) then
			local exID, exDef = extractorAt(spot)
			local upgrade = exID and exDef.mex < bestYield and spGetUnitTeam(exID) == myTeam and not spGetUnitIsBeingBuilt(exID)
			if not exID or upgrade then
				candidates[#candidates + 1] = { i = i, spot = spot, d = dist2(ux, uz, spot.x, spot.z) + (upgrade and 400 * 400 or 0) + (inZone and 0 or 700 * 700) }
			end
		end
	end
	tsort(candidates, function(a, b)
		return a.d < b.d
	end)
	for c = 1, min(#candidates, 4) do
		local cand = candidates[c]
		if not enemiesNear(cand.spot.x, cand.spot.z, 450) then
			local positions = finder.GetBuildingPositions(cand.spot, bestMex, 0, true)
			if positions and #positions > 0 then
				local pos, pd
				for _, p in ipairs(positions) do
					local dd = dist2(p.x, p.z, cand.spot.x, cand.spot.z)
					if (not pd or dd < pd) and not isBadSpot(p.x, p.z) and not blocksFactory(p.x, p.z, defs[bestMex].hx, defs[bestMex].hz) then
						pos, pd = p, dd
					end
				end
				if pos then
					return issueBuild(sub, unitID, bestMex, pos.x, pos.z, 0, "new metal spot")
				end
			end
		end
		spotCooldown[cand.i] = frame + 30 * 60
	end
	return false
end

local function buildCheapestUseful(sub, unitID, d, ax, az, filter, value, why, kind, gap)
	local options = buildableBy(d, filter)
	tsort(options, function(a, b)
		return value(defs[a]) > value(defs[b])
	end)
	for i = 1, min(#options, 3) do
		local o = options[i]
		if canSpend(sub, defs[o], kind) then
			local x, z = findBuildSpot(sub, o, ax, az, { gap = gap or Lanes.gapFor(defs[o]), rings = 12 })
			if x then
				return issueBuild(sub, unitID, o, x, z, 0, why)
			end
		end
	end
	return false
end

local function anchorFor(sub, ux, uz)
	if inSubZones(sub, ux, uz) then
		-- a bit away from the builder so it doesn't wall itself in
		local a = random() * 2 * pi
		return clampToMap(ux + cos(a) * 160, uz + sin(a) * 160)
	end
	local zone = nearestZone(sub, ux, uz)
	if zone then
		return Zone.center(zone)
	end
	return ux, uz
end

function Jobs.energy(sub, unitID, d, ux, uz, urgent)
	local ax, az = anchorFor(sub, ux, uz)
	local cap = costCap(sub, urgent and 1.5 or 1)
	return buildCheapestUseful(sub, unitID, d, ax, az, function(od)
		return od.energy > 0 and od.cost <= cap
	end, function(od)
		return od.energy / max(od.cost, 1)
	end, urgent and "energy (short)" or "energy", urgent and "essential" or "energy")
end

function Jobs.storage(sub, unitID, d, ux, uz)
	local ax, az = anchorFor(sub, ux, uz)
	if econ.mFrac > 0.9 and econ.mS < 20000 then
		if buildCheapestUseful(sub, unitID, d, ax, az, function(od)
			return od.mstore > 0
		end, function(od)
			return od.mstore / max(od.cost, 1)
		end, "metal storage (full)") then
			return true
		end
	end
	if econ.eFrac > 0.95 and econ.eS < 40000 and econ.eInc > econ.ePull * 1.3 then
		return buildCheapestUseful(sub, unitID, d, ax, az, function(od)
			return od.estore > 0
		end, function(od)
			return od.estore / max(od.cost, 1)
		end, "energy storage (full)")
	end
	return false
end

function Jobs.converter(sub, unitID, d, ux, uz)
	if econ.eFrac < 0.85 or econ.mFrac > 0.8 then
		return false
	end
	local surplus = econ.eInc - econ.ePull
	local ax, az = anchorFor(sub, ux, uz)
	return buildCheapestUseful(sub, unitID, d, ax, az, function(od)
		return od.conv > 0 and od.conv <= surplus * 1.2
	end, function(od)
		return od.conv / max(od.cost, 1)
	end, "energy converter (surplus)")
end

-- metal piling up: construction turrets next to a busy factory turn it into units faster
function Jobs.buildPower(sub, unitID, d, ux, uz)
	if econ.mFrac < 0.6 or econ.eFrac < 0.4 then
		return false
	end
	local options = buildableBy(d, function(od)
		return od.nano and od.buildRange > 0
	end)
	if #options == 0 or not canSpend(sub, defs[options[1]]) then
		return false
	end
	local o = options[1]
	local reach = defs[o].buildRange
	local limit = 2 * POSTURE_INFO[sub.posture].density
	local best, bestN
	for _, teamID in ipairs({ myTeam }) do
		for _, u in ipairs(Spring.GetTeamUnits(teamID) or {}) do
			local fd = unitDef(u)
			if fd and fd.factory and not spGetUnitIsBeingBuilt(u) and (spGetFactoryCommandCount(u) or 0) > 0 then
				local fx, _, fz = spGetUnitPosition(u)
				if dist2(ux, uz, fx, fz) < 2500 * 2500 then
					local n = 0
					local near = spGetUnitsInCylinder(fx, fz, reach)
					for i = 1, #near do
						local nd = unitDef(near[i])
						if nd and nd.nano and spGetUnitTeam(near[i]) == myTeam then
							n = n + 1
						end
					end
					for _, p in pairs(planned) do
						if defs[p.defID].nano and dist2(p.x, p.z, fx, fz) < reach * reach then
							n = n + 1
						end
					end
					if n < limit and (not bestN or n < bestN) then
						best, bestN = u, n
					end
				end
			end
		end
	end
	if not best then
		return false
	end
	local fx, _, fz = spGetUnitPosition(best)
	-- close enough to reach the factory, but beside it (its exit and ring stay clear)
	local x, z = findBuildSpot(sub, o, fx, fz, {
		gap = 8,
		rings = 8,
		samples = 4,
		score = function(x, z)
			return -abs(sqrt(dist2(x, z, fx, fz)) - reach * 0.6)
		end,
	})
	if x and dist2(x, z, fx, fz) < (reach * 0.9) ^ 2 then
		return issueBuild(sub, unitID, o, x, z, 0, "construction turret (metal piling up)")
	end
	return false
end

-- help finish something one of our builders started, or an abandoned frame in our zone
function Jobs.helpBuild(sub, unitID, d, ux, uz)
	local best, bestD
	for otherID in pairs(sub.units) do
		if otherID ~= unitID then
			local building = Spring.GetUnitIsBuilding(otherID)
			if building then
				local x, _, z = spGetUnitPosition(building)
				if x then
					local dd = dist2(ux, uz, x, z)
					if dd < 1200 * 1200 and (not bestD or dd < bestD) then
						best, bestD = building, dd
					end
				end
			end
		end
	end
	if not best then
		for _, zone in ipairs(sub.zones) do
			local units = Zone.units(zone)
			for i = 1, #units do
				local u = units[i]
				if spGetUnitTeam(u) == myTeam and spGetUnitIsBeingBuilt(u) and not Spring.GetUnitIsBuilding(u) then
					local x, _, z = spGetUnitPosition(u)
					local dd = dist2(ux, uz, x, z)
					if not bestD or dd < bestD then
						best, bestD = u, dd
					end
				end
			end
		end
	end
	if not best or not canSpend(sub, 0) then
		return false
	end
	order(unitID, CMD.REPAIR, { best })
	local bd = unitDef(best)
	setTask(unitID, "help", "help build " .. (bd and bd.human or "?"), true)
	return true
end

function Jobs.repair(sub, unitID, d, ux, uz)
	local best, bestScore
	for _, zone in ipairs(sub.zones) do
		local units = Zone.units(zone, 100)
		for i = 1, #units do
			local u = units[i]
			if u ~= unitID and spGetUnitTeam(u) == myTeam and not spGetUnitIsBeingBuilt(u) then
				local hp, maxHp = Spring.GetUnitHealth(u)
				if hp and maxHp and hp < maxHp * 0.85 then
					local x, _, z = spGetUnitPosition(u)
					local ud = unitDef(u)
					local score = (1 - hp / maxHp) * 2 + ((ud and not ud.mobile) and 1 or 0) - sqrt(dist2(ux, uz, x, z)) / 2000
					if not bestScore or score > bestScore then
						best, bestScore = u, score
					end
				end
			end
		end
	end
	if not best then
		return false
	end
	order(unitID, CMD.REPAIR, { best })
	local bd = unitDef(best)
	setTask(unitID, "repair", "repair " .. (bd and bd.human or "?"), true)
	log(sub, "repairing " .. (bd and bd.human or "unit"))
	return true
end

function Jobs.assistFactory(sub, unitID, d, ux, uz)
	if econ.mFrac < 0.25 or not canSpend(sub, 0) then
		return false
	end
	local best, bestD
	for otherID in pairs(sub.units) do
		local od = unitDef(otherID)
		if od and od.factory and not spGetUnitIsBeingBuilt(otherID) and (spGetFactoryCommandCount(otherID) or 0) > 0 then
			local x, _, z = spGetUnitPosition(otherID)
			local dd = dist2(ux, uz, x, z)
			if dd < 2000 * 2000 and (not bestD or dd < bestD) then
				best, bestD = otherID, dd
			end
		end
	end
	if not best then
		return false
	end
	local st = getState(unitID)
	if st.task and st.task.kind == "assist" and st.task.target == best then
		st.softUntil = frame + SOFT_TASK_FRAMES
		return true
	end
	order(unitID, CMD.GUARD, { best })
	setTask(unitID, "assist", "assist factory", true)
	st.task.target = best
	return true
end

function Jobs.reclaim(sub, unitID, d, ux, uz)
	if econ.mFrac > 0.9 then
		return false
	end
	local best, bestD, bx, bz
	for _, zone in ipairs(sub.zones) do
		local x1, z1, x2, z2 = Zone.bounds(zone)
		local features = Spring.GetFeaturesInRectangle(x1, z1, x2, z2)
		for i = 1, min(#features, 300) do
			local f = features[i]
			local metal = Spring.GetFeatureResources(f)
			if metal and metal >= 15 then
				local x, _, z = Spring.GetFeaturePosition(f)
				if Zone.contains(zone, x, z) then
					local dd = dist2(ux, uz, x, z)
					if not bestD or dd < bestD then
						best, bestD, bx, bz = f, dd, x, z
					end
				end
			end
		end
	end
	if not best then
		return false
	end
	order(unitID, CMD.RECLAIM, { bx, spGetGroundHeight(bx, bz), bz, 250 })
	setTask(unitID, "reclaim", "reclaim wreckage", true, bx, bz)
	log(sub, "reclaiming wreckage")
	return true
end

-- reclaim own structures marked for removal (by the strategist), nearest first
function Jobs.removeMarked(sub, unitID, d, ux, uz)
	if not d.reclaimer or not next(sub.removals) then
		return false
	end
	local best, bestD
	for u in pairs(sub.removals) do
		local x, _, z = spGetUnitPosition(u)
		if not x or owner[u] ~= sub then
			sub.removals[u] = nil
		else
			local dd = dist2(ux, uz, x, z)
			if not bestD or dd < bestD then
				best, bestD = u, dd
			end
		end
	end
	if not best then
		return false
	end
	order(unitID, CMD.RECLAIM, { best })
	planned[unitID] = nil
	local bd = unitDef(best)
	setTask(unitID, "remove", "reclaim " .. (bd and bd.human or "structure"), false)
	return true
end

local function countStatics(sub, zone, filter)
	local n = 0
	local units = Zone.units(zone)
	for i = 1, #units do
		local u = units[i]
		if spGetUnitTeam(u) == myTeam then
			local ud = unitDef(u)
			if ud and filter(ud) then
				n = n + 1
			end
		end
	end
	for _, p in pairs(planned) do
		if Zone.contains(zone, p.x, p.z) and filter(defs[p.defID]) then
			n = n + 1
		end
	end
	return n
end

local function pickDefense(sub, d, aa)
	local cap = costCap(sub)
	-- turret types the strategist (or player) focused on, when we can build and afford them
	if sub.focus then
		local focused = buildableBy(d, function(od, o)
			return sub.focus[o] and od.staticDef and od.aaOnly == aa and od.cost <= cap * 1.5
		end)
		if #focused > 0 then
			return focused[random(#focused)]
		end
	end
	local options = buildableBy(d, function(od)
		return od.staticDef and (od.aaOnly == aa) and od.cost <= cap
	end)
	if #options == 0 then
		return nil
	end
	-- weigh by what the enemy fields: range against skirmishers/artillery, cheap fast-firing
	-- turrets against raiders, damage against heavies; otherwise the strongest affordable
	local ranged, raiders, heavy = Enemy.share("ranged"), Enemy.share("raiders"), Enemy.share("heavy")
	local function value(od)
		local v = od.cost
		v = v * (max(od.range, 100) / 450) ^ (2 * ranged)
		v = v * (150 / max(od.cost, 30)) ^ raiders
		v = v * (max(od.dps, 1) / max(od.cost, 1) * 4) ^ heavy
		return v
	end
	tsort(options, function(a, b)
		return value(defs[a]) > value(defs[b])
	end)
	if sub.posture == "conserve" then
		tsort(options, function(a, b)
			return defs[a].cost < defs[b].cost
		end)
		return options[1]
	end
	-- mostly the best fit, sometimes the next one for variety
	if #options > 1 and random() < 0.25 then
		return options[2]
	end
	return options[1]
end

local function zoneFor(sub, ux, uz)
	return (#sub.zones > 0) and (inSubZones(sub, ux, uz) and nearestZone(sub, ux, uz) or largestZone(sub)) or nil
end

function Jobs.radar(sub, unitID, d, ux, uz)
	local zone = zoneFor(sub, ux, uz)
	if not zone then
		return false
	end
	local options = buildableBy(d, function(od)
		return od.radar > 0
	end)
	if #options == 0 then
		return false
	end
	local o = options[1]
	local cx, cz = Zone.center(zone)
	local have = 0
	local units = spGetUnitsInCylinder(cx, cz, defs[o].radar * 0.6)
	for i = 1, #units do
		local ud = unitDef(units[i])
		if ud and ud.radar > 0 and spGetUnitTeam(units[i]) == myTeam then
			have = have + 1
		end
	end
	if have > 0 or plannedConflict(defs[o], cx, cz, defs[o].radar * 0.5) or not canSpend(sub, defs[o]) then
		return false
	end
	local x, z = findBuildSpot(sub, o, cx, cz, { gap = 24 })
	return x and issueBuild(sub, unitID, o, x, z, 0, "radar coverage") or false
end

function Jobs.defense(sub, unitID, d, ux, uz)
	local zone = zoneFor(sub, ux, uz)
	if not zone then
		return false
	end
	local o = pickDefense(sub, d, false)
	if not o or not canSpend(sub, defs[o]) then
		return false
	end
	local limit = max(2, floor(Zone.area(zone) / 250000)) * POSTURE_INFO[sub.posture].density
	if countStatics(sub, zone, function(od)
		return od.staticDef and not od.aaOnly
	end) >= limit then
		return false
	end
	local cx, cz = Zone.center(zone)
	local ex, ez = enemyDirectionRef(cx, cz)
	local fx, fz = Zone.edgeToward(zone, ex, ez, 160)
	-- spread along the front line
	local dx, dz = ex - cx, ez - cz
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local spread = (random() - 0.5) * 2 * min(500, sqrt(Zone.area(zone)) * 0.4)
	local ax, az = clampToMap(fx - dz / len * spread, fz + dx / len * spread)
	local x, z = findBuildSpot(sub, o, ax, az, {
		gap = 40,
		rings = 10,
		samples = 5,
		score = function(x, z)
			return -sqrt(dist2(x, z, ex, ez))
		end,
	})
	return x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, ex, ez), "defense toward enemy") or false
end

function Jobs.airDefense(sub, unitID, d, ux, uz)
	local zone = zoneFor(sub, ux, uz)
	if not zone then
		return false
	end
	local o = pickDefense(sub, d, true)
	if not o or not canSpend(sub, defs[o]) then
		return false
	end
	local limit = max(2, floor(Zone.area(zone) / 250000)) * POSTURE_INFO[sub.posture].density
	if countStatics(sub, zone, function(od)
		return od.staticDef and od.aaOnly
	end) >= limit then
		return false
	end
	-- protect the most valuable structure that has the least AA around it
	local units = Zone.units(zone)
	local bestX, bestZ, bestScore
	for i = 1, #units do
		local u = units[i]
		local ud = unitDef(u)
		if ud and not ud.mobile and not ud.staticDef and spGetUnitTeam(u) == myTeam then
			local x, _, z = spGetUnitPosition(u)
			local covered = 0
			local near = spGetUnitsInCylinder(x, z, 450)
			for j = 1, #near do
				local nd = unitDef(near[j])
				if nd and nd.aaOnly and spGetUnitTeam(near[j]) == myTeam then
					covered = covered + 1
				end
			end
			for _, p in pairs(planned) do
				if defs[p.defID].aaOnly and dist2(p.x, p.z, x, z) < 450 * 450 then
					covered = covered + 1
				end
			end
			local score = ud.cost / (1 + covered * 3)
			if not bestScore or score > bestScore then
				bestX, bestZ, bestScore = x, z, score
			end
		end
	end
	if not bestX then
		bestX, bestZ = Zone.center(zone)
	end
	local x, z = findBuildSpot(sub, o, bestX, bestZ, { gap = 32, rings = 8 })
	return x and issueBuild(sub, unitID, o, x, z, 0, "air defense") or false
end

--------------------------------------------------------------------------------
-- Intelligence: radar network on high ground, cameras at the front, a jammer over
-- what matters most, sonar on water; scouts look around, raiders hunt enemy intel.
--------------------------------------------------------------------------------

local Intel = {}

-- the highest buildable spot near (ax, az), among a few candidates
function Intel.highSpot(sub, defID, ax, az, rings)
	return findBuildSpot(sub, defID, ax, az, {
		gap = 24,
		rings = rings or 8,
		samples = 8,
		score = function(x, z)
			return spGetGroundHeight(x, z)
		end,
	})
end

-- is (x, z) inside the range of one of our radars (built or planned)?
function Intel.radarCovered(x, z, share)
	local units = spGetUnitsInCylinder(x, z, 3600)
	for i = 1, #units do
		local ud = unitDef(units[i])
		if ud and ud.radarRange >= 1000 and not ud.mobile and spGetUnitTeam(units[i]) == myTeam then
			local ux, _, uz = spGetUnitPosition(units[i])
			if dist2(x, z, ux, uz) < (ud.radarRange * share) ^ 2 then
				return true
			end
		end
	end
	for _, p in pairs(planned) do
		local pd = defs[p.defID]
		if pd.radarRange >= 1000 and not pd.mobile and dist2(x, z, p.x, p.z) < (pd.radarRange * share) ^ 2 then
			return true
		end
	end
	return false
end

-- points the radar net must cover: every zone's centre and its edge toward the enemy
function Intel.watchPoints(sub)
	local points = {}
	for _, zone in ipairs(sub.zones) do
		local cx, cz = Zone.center(zone)
		local ex, ez = enemyDirectionRef(cx, cz)
		local fx, fz = Zone.edgeToward(zone, ex, ez, 0)
		points[#points + 1] = { fx, fz }
		points[#points + 1] = { cx, cz }
	end
	return points
end

function Jobs.radarNet(sub, unitID, d, ux, uz)
	local options = buildableBy(d, function(od)
		return od.radarRange >= 1000 and not od.mobile and not od.armed
	end)
	if #options == 0 then
		return false
	end
	-- the longest range we can afford
	tsort(options, function(a, b)
		return defs[a].radarRange > defs[b].radarRange
	end)
	local o
	for _, opt in ipairs(options) do
		if canSpend(sub, defs[opt]) then
			o = opt
			break
		end
	end
	if not o then
		return false
	end
	for _, p in ipairs(Intel.watchPoints(sub)) do
		if not Intel.radarCovered(p[1], p[2], 0.7) then
			local x, z = Intel.highSpot(sub, o, p[1], p[2])
			if x then
				return issueBuild(sub, unitID, o, x, z, 0, "radar on high ground")
			end
		end
	end
	return false
end

function Jobs.cameras(sub, unitID, d, ux, uz)
	local options = buildableBy(d, function(od)
		return od.camera
	end)
	local zone = zoneFor(sub, ux, uz)
	if #options == 0 or not zone or not canSpend(sub, defs[options[1]]) then
		return false
	end
	local o = options[1]
	local limit = 1 + POSTURE_INFO[sub.posture].density
	if countStatics(sub, zone, function(od)
		return od.camera
	end) >= limit then
		return false
	end
	local cx, cz = Zone.center(zone)
	local ex, ez = enemyDirectionRef(cx, cz)
	local fx, fz = Zone.edgeToward(zone, ex, ez, 60)
	local dx, dz = ex - cx, ez - cz
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local spread = (random() - 0.5) * 2 * min(700, sqrt(Zone.area(zone)) * 0.5)
	local x, z = findBuildSpot(sub, o, fx - dz / len * spread, fz + dx / len * spread, { gap = 16, rings = 6 })
	return x and issueBuild(sub, unitID, o, x, z, 0, "camera at the front") or false
end

function Jobs.jammer(sub, unitID, d, ux, uz)
	local options = buildableBy(d, function(od)
		return od.jammer > 0 and not od.mobile
	end)
	local zone = zoneFor(sub, ux, uz)
	if #options == 0 or not zone then
		return false
	end
	local o = options[1]
	-- jammers cost a lot of energy: only with a healthy grid
	if econ.eInc < defs[o].energyCost / 40 or not canSpend(sub, defs[o]) then
		return false
	end
	-- hide the most valuable cluster: weighted centre of factories and big structures
	local sx, sz, w = 0, 0, 0
	for _, u in ipairs(Zone.units(zone)) do
		local ud = unitDef(u)
		if ud and not ud.mobile and spGetUnitTeam(u) == myTeam and (ud.factory or ud.cost >= 150) then
			local x, _, z = spGetUnitPosition(u)
			sx, sz, w = sx + x * ud.cost, sz + z * ud.cost, w + ud.cost
		end
	end
	if w == 0 then
		return false
	end
	local tx, tz = sx / w, sz / w
	local units = spGetUnitsInCylinder(tx, tz, defs[o].jammer)
	for i = 1, #units do
		local ud = unitDef(units[i])
		if ud and ud.jammer > 0 and Spring.AreTeamsAllied(spGetUnitTeam(units[i]), myTeam) then
			return false
		end
	end
	if plannedConflict(defs[o], tx, tz, defs[o].jammer * 0.5) then
		return false
	end
	local x, z = findBuildSpot(sub, o, tx, tz, { gap = 24, rings = 8 })
	return x and issueBuild(sub, unitID, o, x, z, 0, "jammer over the base") or false
end

function Jobs.sonar(sub, unitID, d, ux, uz)
	local options = buildableBy(d, function(od)
		return od.sonar > 0
	end)
	local zone = zoneFor(sub, ux, uz)
	if #options == 0 or not zone or not canSpend(sub, defs[options[1]]) then
		return false
	end
	if countStatics(sub, zone, function(od)
		return od.sonar > 0
	end) > 0 then
		return false
	end
	-- only where there is water
	local x1, z1, x2, z2 = Zone.bounds(zone)
	for _ = 1, 12 do
		local x, z = x1 + random() * (x2 - x1), z1 + random() * (z2 - z1)
		if Zone.contains(zone, x, z) and spGetGroundHeight(x, z) < -20 then
			local bx, bz = findBuildSpot(sub, options[1], x, z, { gap = 24, rings = 4 })
			if bx then
				return issueBuild(sub, unitID, options[1], bx, bz, 0, "sonar")
			end
		end
	end
	return false
end

-- known enemy radar/jammer/camera to hit next: near our zones, not covered by known turrets
function Intel.huntTarget(sub, x, z)
	local best, bestD
	for u, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		if ed.intelStructure then
			local dd = dist2(x, z, e.x, e.z)
			if dd < 4000 * 4000 and (not bestD or dd < bestD) then
				local guarded = 0
				for _, o in pairs(Enemy.units) do
					if defs[o.defID].staticDef and not defs[o.defID].aaOnly and dist2(o.x, o.z, e.x, e.z) < 650 * 650 then
						guarded = guarded + 1
					end
				end
				if guarded == 0 then
					best, bestD = u, dd
				end
			end
		end
	end
	return best
end

-- scouting: visit the enemy start and metal spots outside our zones, least recently seen first
function Intel.nextScoutPoint(sub, x, z)
	sub.scouted = sub.scouted or {}
	local candidates = {}
	for _, st in ipairs(getEnemyStarts()) do
		candidates[#candidates + 1] = { x = st.x, z = st.z, key = "start" .. floor(st.x) }
	end
	for i, spot in ipairs(metalSpots() or {}) do
		if not inSubZones(sub, spot.x, spot.z) then
			candidates[#candidates + 1] = { x = spot.x, z = spot.z, key = i }
		end
	end
	local best, bestScore
	for _, c in ipairs(candidates) do
		if Spring.IsPosInLos(c.x, 0, c.z, myAlly) then
			sub.scouted[c.key] = frame
		end
		local age = frame - (sub.scouted[c.key] or -30 * 600)
		local score = age - sqrt(dist2(x, z, c.x, c.z)) * 0.5
		if not bestScore or score > bestScore then
			best, bestScore = c, score
		end
	end
	if best then
		sub.scouted[best.key] = frame
	end
	return best
end

-- intelligence units: scouts look around, the rest hunt enemy intel, then guard the zone edge
function Intel.thinkUnit(sub, unitID, d, st, threats)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return
	end
	local busy = (spGetUnitCommandCount(unitID) or 0) > 0
	if d.scout or (d.air and not d.armed) then
		if not busy or (st.softUntil and frame > st.softUntil) then
			local p = Intel.nextScoutPoint(sub, x, z)
			if p then
				order(unitID, CMD.MOVE, { p.x, spGetGroundHeight(p.x, p.z), p.z })
				setTask(unitID, "scout", "scouting", true)
			end
		end
		return
	end
	if not d.armed then
		-- mobile radar / jammer: stay at the zone edge toward the enemy
		local zone = nearestZone(sub, x, z)
		if zone and not busy then
			local cx, cz = Zone.center(zone)
			local ex, ez = enemyDirectionRef(cx, cz)
			local fx, fz = Zone.edgeToward(zone, ex, ez, d.jammer > 0 and 300 or 100)
			order(unitID, CMD.MOVE, { fx, spGetGroundHeight(fx, fz), fz })
			setTask(unitID, "post", d.jammer > 0 and "jamming" or "radar post", true)
		end
		return
	end
	local target = Intel.huntTarget(sub, x, z)
	if target then
		if st.hunting ~= target or not busy then
			local e = Enemy.units[target]
			if spGetUnitPosition(target) then
				order(unitID, CMD.ATTACK, { target })
			else
				order(unitID, CMD.FIGHT, { e.x, spGetGroundHeight(e.x, e.z), e.z })
			end
			st.hunting = target
			setTask(unitID, "hunt", "hunting " .. defs[e.defID].human, true)
		end
		return
	end
	st.hunting = nil
	Intel.combat(sub, unitID, d, st, threats)
end

-- factories only join when the player assigns them, so an army without one asks for one
function Jobs.needFactory(sub, unitID, d, ux, uz)
	if sub.counts.factories == 0 and frame - (sub.factoryNoted or -99999) > 30 * 90 then
		sub.factoryNoted = frame
		log(sub, "no factory: select one and Assign sel. to let me produce")
	end
	return false
end

function Jobs.goToZone(sub, unitID, d, ux, uz)
	if inSubZones(sub, ux, uz) then
		return false
	end
	local zone = nearestZone(sub, ux, uz)
	if not zone then
		return false
	end
	local x, z = Zone.center(zone)
	order(unitID, CMD.MOVE, { x, spGetGroundHeight(x, z), z })
	setTask(unitID, "move", "moving to zone", true, x, z)
	return true
end

local function energyShort()
	return econ.eFrac < 0.15 or (econ.eFrac < 0.4 and econ.eInc < max(econ.eNeed or econ.ePull, econ.mInc * 9))
end

-- metal extractors and energy, alternating when both are short so a constant
-- energy drain from other sub-commanders can't starve metal expansion
function Jobs.basicEconomy(sub, unitID, d, ux, uz)
	local st = getState(unitID)
	-- energy also falls behind when income is under ~10 per metal: T1 building needs more than that
	local eShort = energyShort() or (econ.eInc < econ.mInc * 10 and econ.eFrac < 0.9)
	local mexFirst = not eShort or (econ.mFrac < 0.25 and st.lastEco == "energy")
	local acted
	if mexFirst then
		acted = Jobs.mex(sub, unitID, d, ux, uz) or (eShort and Jobs.energy(sub, unitID, d, ux, uz, true))
	else
		acted = Jobs.energy(sub, unitID, d, ux, uz, true) or Jobs.mex(sub, unitID, d, ux, uz)
	end
	if acted then
		local p = planned[unitID]
		st.lastEco = (p and defs[p.defID].mex > 0) and "mex" or "energy"
	end
	return acted
end

local function energyWanted()
	-- metal piling up while energy runs low: energy is what holds spending back
	return (econ.eFrac < 0.8 and econ.eInc < econ.mInc * 15) or (econ.mFrac > 0.8 and econ.eFrac < 0.6)
end

-- nothing left to do while resources overflow: tell the player once in a while
function Jobs.overflowNote(sub, unitID, d, ux, uz)
	if econ.mFrac > 0.95 and frame - (sub.overflowNoted or -99999) > 30 * 60 then
		sub.overflowNoted = frame
		log(sub, "metal is overflowing: give me a factory or more roles to spend it")
	end
	return false
end

local BUILDER_PLANS = {
	economy = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.basicEconomy(sub, u, d, x, z)
			or (energyWanted() and Jobs.energy(sub, u, d, x, z, false))
			or Jobs.buildPower(sub, u, d, x, z)
			or Jobs.storage(sub, u, d, x, z)
			or Jobs.converter(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or (sub.posture == "spend" and econ.eFrac < 0.9 and Jobs.energy(sub, u, d, x, z, false))
			or Jobs.goToZone(sub, u, d, x, z)
			or Jobs.overflowNote(sub, u, d, x, z)
	end,
	defense = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or Jobs.radar(sub, u, d, x, z)
			-- enemy aircraft are a real part of what they field: anti-air on our line too
			or (Enemy.share("air") > 0.2 and Jobs.airDefense(sub, u, d, x, z))
			or Jobs.defense(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	airdefense = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or Jobs.airDefense(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	intelligence = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.radarNet(sub, u, d, x, z)
			or Jobs.cameras(sub, u, d, x, z)
			or Jobs.sonar(sub, u, d, x, z)
			or Jobs.jammer(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	army = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or Jobs.needFactory(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
}

--------------------------------------------------------------------------------
-- Factories
--------------------------------------------------------------------------------

local function pickProduction(sub, facID, fd)
	local p = POSTURE_INFO[sub.posture]
	local counts = sub.counts
	local cap = costCap(sub, 1.2)
	if sub.focus then
		local options = buildableBy(fd, function(od, o)
			return sub.focus[o]
		end)
		if #options > 0 then
			if counts.combat + counts.builders >= p.army * 1.5 then
				return nil, "at unit cap"
			end
			return options[random(#options)], "focus"
		end
	end
	local wantBuilder
	if sub.role == "economy" then
		wantBuilder = counts.builders < p.builders
		-- enough constructors: only make fighters (to guard the economy) when metal piles up
		if not wantBuilder and econ.mFrac < 0.75 then
			return nil, "enough constructors"
		end
	elseif sub.role ~= "army" and counts.builders < 1 then
		wantBuilder = true
	end
	if wantBuilder then
		local options = buildableBy(fd, function(od)
			return od.builder and not od.commander
		end)
		tsort(options, function(a, b)
			return defs[a].cost < defs[b].cost
		end)
		if options[1] then
			return options[1], "constructor"
		end
		if sub.role == "economy" then
			return nil, "factory can't make constructors"
		end
	end
	if sub.role == "intelligence" then
		-- a few scouts, one mobile radar / jammer, then fast raiders to hunt enemy intel
		local scoutCap = sub.posture == "conserve" and 1 or (sub.posture == "spend" and 4 or 2)
		if counts.scouts < scoutCap then
			local options = buildableBy(fd, function(od)
				return (od.scout or (od.air and not od.armed and not od.transport and od.radarRange > 0)) and od.cost <= cap
			end)
			tsort(options, function(a, b)
				return defs[a].cost < defs[b].cost
			end)
			if options[1] then
				return options[1], "scout"
			end
		end
		if counts.intelUnits < 1 then
			local options = buildableBy(fd, function(od)
				return od.mobile and not od.armed and not od.builder and (od.jammer > 0 or od.radarRange > 0) and od.cost <= cap
			end)
			if options[1] then
				return options[1], "mobile intel"
			end
		end
		if counts.combat - counts.scouts >= max(2, floor(p.army / 3)) then
			return nil, "enough raiders"
		end
		local options = buildableBy(fd, function(od)
			return od.combat and not od.aaOnly and not od.air and od.cost <= cap
		end)
		tsort(options, function(a, b)
			return defs[a].speed > defs[b].speed
		end)
		if options[1] then
			return options[1], "raider"
		end
		return nil, "nothing to build"
	end
	-- metal piling up: units are how it turns into map control
	local armyCap = p.army * (sub.role == "army" and 1.5 or 1) * (econ.mFrac > 0.8 and 2 or 1)
	if counts.combat >= armyCap then
		return nil, "at unit cap"
	end
	local wantAA = sub.role == "airdefense"
	local options = buildableBy(fd, function(od)
		return od.combat and od.aaOnly == wantAA and od.cost <= cap
	end)
	if #options == 0 then
		return nil, wantAA and "factory has no anti-air" or "nothing affordable"
	end
	-- prefer stronger units, but keep some mix
	tsort(options, function(a, b)
		return defs[a].cost > defs[b].cost
	end)
	local pick = options[min(#options, 1 + floor(random() ^ 2 * #options))]
	return pick, wantAA and "anti-air" or "army"
end

-- Decision model (optional, behind the bridge): picks the next combat unit from the factory's
-- options given what the enemy fields and what we have. Answers arrive a few frames later;
-- without an answer within 2 s the rules decide.
local Decider = {}

-- what each kind is for: decision models match these against what the enemy fields
Decider.hints = {
	raider = "fast and cheap, good against artillery, skirmishers and lone extractors, weak against riot units and turrets",
	assault = "all-round fighter, good against raiders",
	heavy = "armored, good against assault units and raiders, weak against massed cheap units and artillery",
	skirmisher = "long range, good against slow heavy units, weak against fast raiders",
	artillery = "long arcing range, good against turrets and static defence, weak against fast raiders",
	["mobile anti-air"] = "shoots aircraft only, good against bombers and gunships, useless against ground units and unarmed scout planes",
	scout = "very fast scout, finds the enemy, weak in fights",
	fighter = "aircraft that shoots aircraft only, good against bombers and gunships",
	bomber = "aircraft, good against slow units and buildings, weak against anti-air",
	gunship = "aircraft, good against ground units without anti-air",
}

function Decider.describe(d)
	local hint = Decider.hints[(d.kind:gsub("^hover ", ""))]
	return sformat("%s (%s): %s, range %d, speed %d, health %d, cost %d metal%s", d.human, d.name, d.kind, d.range, d.speed, d.health, d.metal, hint and ("; " .. hint) or "")
end

function Decider.countsText(map)
	local list = {}
	for k, n in pairs(map) do
		list[#list + 1] = { k, n }
	end
	tsort(list, function(a, b)
		return a[2] > b[2]
	end)
	local parts = {}
	for _, kv in ipairs(list) do
		parts[#parts + 1] = kv[2] .. " " .. kv[1]
	end
	return #parts > 0 and tconcat(parts, ", ") or "none"
end

function Decider.state(sub)
	local mix = Enemy.mix()
	local ours = {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.combat then
			ours[d.kind] = (ours[d.kind] or 0) + 1
		end
	end
	local air = 0
	for _, t in ipairs(sub.threats) do
		if t.air then
			air = air + 1
		end
	end
	return sformat("Beyond All Reason RTS. Our %s sub-commander's factory is choosing its next unit. Enemy units seen in the last 5 minutes: %s. First seen in the last 3 minutes: %s. Our units: %s. Enemies in our zone now: %d (%d aircraft). Metal %d/%d (+%.1f/s), energy %d/%d (+%.0f/s).",
		ROLE_INFO[sub.role].label, Decider.countsText(mix.kinds), Decider.countsText(mix.recentKinds), Decider.countsText(ours), #sub.threats, air, econ.m, econ.mS, econ.mInc, econ.e, econ.eS, econ.eInc)
end

-- returns a defID to build, nil while waiting for an answer, or false to let the rules decide
function Decider.production(sub, facID, fd, st)
	local ai = WG.SubCommandersAI
	if not (ai and ai.deciderReady and ai.deciderReady()) or sub.focus then
		return false
	end
	if st.pick and frame - st.pickFrame < 300 then
		local pick = st.pick
		st.pick = nil
		return pick
	end
	if st.asking then
		if frame - st.asking < 60 then
			return nil
		end
		st.asking, st.askFailed = nil, frame
	end
	if st.askFailed and frame - st.askFailed < 300 then
		return false
	end
	local cap = costCap(sub, 1.2)
	local options = buildableBy(fd, function(od)
		return od.combat and od.cost <= cap and (sub.role ~= "airdefense" or od.aaOnly)
	end)
	if #options < 2 then
		return false
	end
	tsort(options, function(a, b)
		return defs[a].cost > defs[b].cost
	end)
	local criteria = {}
	for i = 1, min(#options, 8) do
		criteria[defs[options[i]].name] = Decider.describe(defs[options[i]])
	end
	local questions = { unit = { type = "choice", instructions = "Which unit should the factory build next to best counter the enemy and complement our army?", criteria = criteria } }
	local sent = ai.decide(sub.id, Decider.state(sub), questions, function(answers, err)
		st.asking = nil
		local choice = answers and answers.unit and answers.unit.choice
		if choice and UnitDefNames[choice] then
			st.pick, st.pickFrame = UnitDefNames[choice].id, frame
		else
			st.askFailed = frame
		end
	end)
	if not sent then
		return false
	end
	st.asking = frame
	return nil
end

local function thinkFactory(sub, facID, fd, st)
	if spGetUnitIsBeingBuilt(facID) then
		return
	end
	if (spGetFactoryCommandCount(facID) or 0) > 0 then
		return
	end
	local defID, why = pickProduction(sub, facID, fd)
	if not defID then
		st.factoryNote = why
		return
	end
	if why == "army" or why == "anti-air" then
		local pick = Decider.production(sub, facID, fd, st)
		if pick == nil then
			st.factoryNote = "deciding"
			return
		elseif pick then
			defID, why = pick, "decision model"
		end
	end
	if not canSpend(sub, defs[defID]) then
		st.factoryNote = "waiting for resources"
		return
	end
	order(facID, -defID, {})
	st.factoryNote = defs[defID].human
	log(sub, sformat("factory: %s (%s)", defs[defID].human, why))
end

--------------------------------------------------------------------------------
-- Combat units
--------------------------------------------------------------------------------

local function scanThreats(sub)
	local threats = {}
	local seen = {}
	for _, zone in ipairs(sub.zones) do
		local units = Zone.units(zone, 300)
		for i = 1, #units do
			local u = units[i]
			if not seen[u] and isEnemyUnit(u) then
				seen[u] = true
				local x, _, z = spGetUnitPosition(u)
				if x then
					local ud = unitDef(u)
					threats[#threats + 1] = { id = u, x = x, z = z, air = ud and ud.air or false }
				end
			end
		end
	end
	return threats
end

local function patrolZone(sub, unitID, ux, uz)
	local zone = nearestZone(sub, ux, uz)
	if not zone then
		return
	end
	if not Zone.contains(zone, ux, uz, 200) then
		local x, z = Zone.randomPoint(zone, 150)
		order(unitID, CMD.FIGHT, { x, spGetGroundHeight(x, z), z })
		setTask(unitID, "move", "moving to zone", true)
		return
	end
	local x1, z1 = Zone.randomPoint(zone, 150)
	local x2, z2 = Zone.randomPoint(zone, 150)
	order(unitID, CMD.PATROL, { x1, spGetGroundHeight(x1, z1), z1 })
	order(unitID, CMD.PATROL, { x2, spGetGroundHeight(x2, z2), z2 }, { "shift" })
	setTask(unitID, "patrol", "patrolling zone", true)
end

-- army rally point: inside the main zone, on its edge toward the enemy
local function rallyPoint(sub)
	local zone = largestZone(sub)
	if not zone then
		return nil
	end
	local cx, cz = Zone.center(zone)
	local ex, ez = enemyDirectionRef(cx, cz)
	return Zone.edgeToward(zone, ex, ez, 250)
end

local function thinkCombat(sub, unitID, d, st, threats)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return
	end
	-- badly damaged units worth saving fall back to the zone centre, where constructors repair them
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	if hp and maxHp and maxHp > 0 then
		local f = hp / maxHp
		if st.retreating then
			if f > 0.8 or frame - st.retreating > 30 * 40 then
				st.retreating = nil
			else
				return
			end
		elseif f < 0.3 and d.cost >= 100 and not d.air then
			local zone = largestZone(sub)
			if zone then
				local zx, zz = Zone.center(zone)
				if dist2(x, z, zx, zz) > 300 * 300 then
					order(unitID, CMD.MOVE, { zx, spGetGroundHeight(zx, zz), zz })
					st.retreating, st.engaged = frame, nil
					setTask(unitID, "retreat", "falling back to repair", true)
					return
				end
			end
		end
	end
	-- an army chooses from where the army is, so every unit goes for the same enemy
	local fromX, fromZ = x, z
	if sub.role == "army" and sub.armyX then
		fromX, fromZ = sub.armyX, sub.armyZ
	end
	local target, targetD
	for i = 1, #threats do
		local t = threats[i]
		if (d.aaOnly and t.air) or (not d.aaOnly and (not t.air or d.air)) then
			local dd = dist2(fromX, fromZ, t.x, t.z)
			if not targetD or dd < targetD then
				target, targetD = t, dd
			end
		end
	end
	if not target and sub.role == "army" then
		-- no intruder in our zones: help the other sub-commanders, if we aren't badly outnumbered
		for i = 1, #baseThreats do
			local t = baseThreats[i]
			if (not t.air or d.air or d.aaOnly) and not (d.aaOnly and not t.air) then
				local dd = dist2(fromX, fromZ, t.x, t.z)
				if dd < 3500 * 3500 and (not targetD or dd < targetD) then
					target, targetD = t, dd
				end
			end
		end
		if target and sub.counts.power < 0.8 * Enemy.powerNear(target.x, target.z, 900) then
			target = nil
		end
	end
	local busy = (spGetUnitCommandCount(unitID) or 0) > 0
	if target then
		if st.engaged ~= target.id or not busy or frame - (st.engagedFrame or 0) > 150 then
			order(unitID, CMD.FIGHT, { target.x, spGetGroundHeight(target.x, target.z), target.z })
			st.engaged, st.engagedFrame = target.id, frame
			setTask(unitID, "engage", "engaging intruder", true)
		end
		return
	end
	st.engaged = nil
	if sub.role == "army" then
		-- gather: the army waits together at its rally point instead of spreading out on patrol
		local rx, rz = rallyPoint(sub)
		if rx and (not busy or (st.softUntil and frame > st.softUntil)) and dist2(x, z, rx, rz) > 260 * 260 then
			local a = (unitID % 12) / 12 * 2 * pi
			local gx, gz = clampToMap(rx + cos(a) * 120, rz + sin(a) * 120)
			order(unitID, CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
			setTask(unitID, "rally", "gathering", true)
		end
		return
	end
	if not busy or (st.softUntil and frame > st.softUntil) or (#sub.zones > 0 and not inSubZones(sub, x, z, 900)) then
		patrolZone(sub, unitID, x, z)
	end
end

Intel.combat = thinkCombat

--------------------------------------------------------------------------------
-- Sub-commander lifecycle
--------------------------------------------------------------------------------

local function findSub(id)
	for _, sub in ipairs(subs) do
		if sub.id == id then
			return sub
		end
	end
end

local function createSub(role, name)
	role = ROLE_INFO[role] and role or "economy"
	local id = nextSubID
	nextSubID = nextSubID + 1
	local sub = {
		id = id,
		name = name or (ROLE_INFO[role].label .. " " .. id),
		role = role,
		posture = "balanced",
		paused = false,
		zones = {},
		units = {},
		log = {},
		status = "waiting for units",
		colorIndex = ((id - 1) % #PALETTE) + 1,
		counts = { builders = 0, factories = 0, combat = 0, nanos = 0, statics = 0, total = 0, scouts = 0, intelUnits = 0, power = 0 },
		spendM = 0,
		spendE = 0,
		threats = {},
		ai = false,
		removals = {}, -- own structures to reclaim: unitID -> true
	}
	sub.color = PALETTE[sub.colorIndex]
	subs[#subs + 1] = sub
	activeSub = sub
	log(sub, "created (" .. ROLE_INFO[role].label .. ")")
	return sub
end

-- build priority: the posture's, but low while the player builds and metal is short
local function subPriority(sub)
	return Player.yield and 0 or POSTURE_INFO[sub.posture].priority
end

local function applyPriority(sub, unitID)
	local d = unitDef(unitID)
	if CMD_PRIORITY and d and (d.builder or d.factory or d.nano) and not d.commander then
		-- a unit the player took over works for the player: normal priority
		local st = ustate[unitID]
		order(unitID, CMD_PRIORITY, { (st and st.manual) and 1 or subPriority(sub) })
	end
end

Player.restorePriority = applyPriority

-- re-apply when the priority a sub-commander should have changes (player started/stopped building)
local function refreshPriorities()
	for _, sub in ipairs(subs) do
		local want = subPriority(sub)
		if sub.appliedPriority ~= want then
			sub.appliedPriority = want
			for u in pairs(sub.units) do
				applyPriority(sub, u)
			end
			if want == 0 and Player.yield then
				log(sub, "you're building and metal is short: giving your builds priority")
			end
		end
	end
end

local function releaseUnit(unitID, silent)
	local sub = owner[unitID]
	if not sub then
		return
	end
	sub.units[unitID] = nil
	owner[unitID] = nil
	planned[unitID] = nil
	ustate[unitID] = nil
	if not silent then
		log(sub, "unit released")
	end
end

local function addUnit(sub, unitID, opts)
	if spGetUnitTeam(unitID) ~= myTeam then
		return false
	end
	local d = unitDef(unitID)
	if not d then
		return false
	end
	if owner[unitID] and owner[unitID] ~= sub then
		releaseUnit(unitID, true)
	end
	owner[unitID] = sub
	sub.units[unitID] = true
	local st = getState(unitID)
	st.manual, st.task, st.nextThink = false, nil, frame
	if opts and opts.takeOver and d.mobile and not spGetUnitIsBeingBuilt(unitID) then
		order(unitID, CMD.STOP)
	end
	if opts and opts.takeOver then
		applyPriority(sub, unitID)
	end
	return true
end

local function autoZone(sub, unitIDs)
	if #sub.zones > 0 then
		return
	end
	local sx, sz, n = 0, 0, 0
	for _, u in ipairs(unitIDs) do
		local x, _, z = spGetUnitPosition(u)
		if x then
			sx, sz, n = sx + x, sz + z, n + 1
		end
	end
	if n == 0 then
		return
	end
	local x, z = clampToMap(sx / n, sz / n)
	sub.zones[1] = { kind = "circle", x = x, z = z, r = sub.role == "economy" and 1100 or 850 }
	log(sub, "no zone yet: claimed the area around its units (redraw with + Zone)")
end

local function assignUnits(sub, unitIDs)
	local added = {}
	for _, u in ipairs(unitIDs) do
		if addUnit(sub, u, { takeOver = true }) then
			added[#added + 1] = u
		end
	end
	if #added > 0 then
		autoZone(sub, added)
		local names = {}
		for _, u in ipairs(added) do
			local d = unitDef(u)
			names[d.human] = (names[d.human] or 0) + 1
		end
		local parts = {}
		for n, c in pairs(names) do
			parts[#parts + 1] = c > 1 and (c .. "x " .. n) or n
		end
		log(sub, "received " .. tconcat(parts, ", "))
	end
	return #added
end

local function deleteSub(sub)
	for u in pairs(sub.units) do
		releaseUnit(u, true)
	end
	for i = #subs, 1, -1 do
		if subs[i] == sub then
			tremove(subs, i)
		end
	end
	if activeSub == sub then
		activeSub = subs[1]
	end
	if zoneTool and zoneTool.sub == sub then
		zoneTool, zoneDrag = nil, nil
	end
	if orderInput and orderInput.sub == sub then
		stopOrderInput(false)
	end
end

local function setPosture(sub, posture)
	if not POSTURE_INFO[posture] then
		return
	end
	sub.posture = posture
	for u in pairs(sub.units) do
		applyPriority(sub, u)
	end
	log(sub, "posture: " .. POSTURE_INFO[posture].label)
end

local function setRole(sub, role)
	if not ROLE_INFO[role] then
		return
	end
	local oldLabel = ROLE_INFO[sub.role].label
	sub.role = role
	if sub.name:find("^" .. oldLabel .. " %d+$") then
		sub.name = ROLE_INFO[role].label .. " " .. sub.id
	end
	for u in pairs(sub.units) do
		local st = getState(u)
		st.task, st.nextThink = nil, frame
	end
	log(sub, "role: " .. ROLE_INFO[role].label)
end

local function cycle(list, value, dir)
	for i, v in ipairs(list) do
		if v == value then
			return list[((i - 1 + (dir or 1)) % #list) + 1]
		end
	end
	return list[1]
end

--------------------------------------------------------------------------------
-- Scheduler
--------------------------------------------------------------------------------

local function updateCounts(sub)
	local c = { builders = 0, factories = 0, combat = 0, nanos = 0, statics = 0, total = 0, scouts = 0, intelUnits = 0, power = 0 }
	local spendM, spendE = 0, 0
	local sx, sz, sn = 0, 0, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d then
			c.total = c.total + 1
			if d.scout or (d.air and not d.armed and not d.transport) then
				c.scouts = c.scouts + 1
			elseif d.mobile and not d.builder and (d.jammer > 0 or d.radarRange > 0) and not d.armed then
				c.intelUnits = c.intelUnits + 1
			end
			if d.combat and not spGetUnitIsBeingBuilt(u) then
				c.power = c.power + d.cost
				local x, _, z = spGetUnitPosition(u)
				if x then
					sx, sz, sn = sx + x, sz + z, sn + 1
				end
			end
			if d.builder then
				c.builders = c.builders + 1
			elseif d.factory then
				c.factories = c.factories + 1
			elseif d.combat then
				c.combat = c.combat + 1
			elseif d.nano then
				c.nanos = c.nanos + 1
			else
				c.statics = c.statics + 1
			end
			if d.builder or d.factory or d.nano then
				local _, mUse, _, eUse = Spring.GetUnitResources(u)
				spendM, spendE = spendM + (mUse or 0), spendE + (eUse or 0)
			end
		end
	end
	sub.counts = c
	sub.spendM, sub.spendE = spendM, spendE
	-- where the army is: it picks targets from here so all units fight the same enemy
	if sn > 0 then
		sub.armyX, sub.armyZ = sx / sn, sz / sn
	else
		sub.armyX, sub.armyZ = nil, nil
	end
end

local function manualHeld(unitID, st, d)
	if not st.manual then
		return false
	end
	local busy
	if d.factory then
		busy = (spGetFactoryCommandCount(unitID) or 0) > 0
	else
		busy = (spGetUnitCommandCount(unitID) or 0) > 0
	end
	if busy or frame < (st.manualUntil or 0) then
		return true
	end
	st.manual = false
	st.task = nil
	if owner[unitID] then
		Player.restorePriority(owner[unitID], unitID)
	end
	return false
end

local function builderNeedsThink(unitID, st)
	if frame < st.nextThink then
		return false
	end
	if (spGetUnitCommandCount(unitID) or 0) == 0 then
		if st.task and st.task.kind == "build" and not st.task.started and frame - st.task.frame < 30 * 45 and st.task.x then
			-- the build order vanished without anything being started: avoid that spot for a while
			badSpots[#badSpots + 1] = { x = st.task.x, z = st.task.z, untilFrame = frame + 30 * 120 }
		end
		planned[unitID] = nil
		return true
	end
	local task = st.task
	if not task then
		-- e.g. restored after a reload while busy: look again once it had time to finish
		setTask(unitID, "unknown", "busy", true)
		return false
	end
	if task.kind == "build" and not task.started and frame - task.frame > 30 * 45 then
		if task.x then
			badSpots[#badSpots + 1] = { x = task.x, z = task.z, untilFrame = frame + 30 * 120 }
		end
		planned[unitID] = nil
		log(owner[unitID], "gave up on " .. task.text .. " (couldn't start it)")
		return true
	end
	return st.softUntil ~= nil and frame >= st.softUntil
end

local function thinkBuilder(sub, unitID, d, st)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return
	end
	st.nextThink = frame + BUILDER_COOLDOWN
	local plan = BUILDER_PLANS[sub.role]
	local acted = plan and plan(sub, unitID, d, x, z)
	if not acted then
		if not st.task or st.task.kind ~= "idle" then
			setTask(unitID, "idle", "nothing to do", false)
		end
		st.nextThink = frame + 30 * 3
	end
end

local function thinkNano(sub, unitID, st)
	if (spGetUnitCommandCount(unitID) or 0) > 0 then
		return
	end
	local x, y, z = spGetUnitPosition(unitID)
	if x then
		order(unitID, CMD.PATROL, { x + 20, y, z + 20 })
		setTask(unitID, "patrol", "assisting nearby", true)
	end
end

local function runSub(sub, budget, combatPass)
	if sub.paused then
		return budget
	end
	for unitID in pairs(sub.units) do
		if not isAlive(unitID) then
			releaseUnit(unitID, true)
		else
			local d = unitDef(unitID)
			local st = getState(unitID)
			if d and not spGetUnitIsBeingBuilt(unitID) and not manualHeld(unitID, st, d) then
				if d.builder then
					if budget > 0 and builderNeedsThink(unitID, st) then
						thinkBuilder(sub, unitID, d, st)
						budget = budget - 1
					end
				elseif d.factory then
					if combatPass then
						thinkFactory(sub, unitID, d, st)
					end
				elseif d.nano then
					if combatPass then
						thinkNano(sub, unitID, st)
					end
				elseif d.combat or (d.mobile and not d.builder and not d.commander) then
					if combatPass then
						if sub.role == "intelligence" then
							Intel.thinkUnit(sub, unitID, d, st, sub.threats)
						elseif d.combat then
							thinkCombat(sub, unitID, d, st, sub.threats)
						end
					end
				end
			end
		end
	end
	return budget
end

--------------------------------------------------------------------------------
-- Public API (for other widgets, e.g. an LLM strategist)
--------------------------------------------------------------------------------

local function zoneInfo(zone)
	local info = table.copy(zone)
	local cx, cz = Zone.center(zone)
	info.cx, info.cz = floor(cx), floor(cz)
	local total, free = 0, 0
	local spots = metalSpots()
	if spots then
		for i = 1, #spots do
			if Zone.contains(zone, spots[i].x, spots[i].z) then
				total = total + 1
				if not extractorAt(spots[i]) then
					free = free + 1
				end
			end
		end
	end
	local structures, ground, air = 0, 0, 0
	for _, u in ipairs(Zone.units(zone)) do
		if spGetUnitTeam(u) == myTeam then
			local d = unitDef(u)
			if d and not d.mobile then
				structures = structures + 1
				if d.staticDef then
					if d.aaOnly then
						air = air + 1
					else
						ground = ground + 1
					end
				end
			end
		end
	end
	info.metalSpots, info.freeMetalSpots = total, free
	info.ownStructures, info.groundDefenses, info.airDefenses = structures, ground, air
	return info
end

-- counts per key, as a list sorted by count: { { key = ..., count = n }, ... }
local function tally(map)
	local out = {}
	for k, n in pairs(map) do
		out[#out + 1] = { k, n }
	end
	tsort(out, function(a, b)
		return a[2] > b[2]
	end)
	return out
end

local function summarize(sub)
	local units, byType, byTask, manual = {}, {}, {}, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		local task = st and st.task and st.task.text or nil
		units[#units + 1] = { id = u, name = d and d.name, task = task, manual = st and st.manual or false }
		if d and (d.mobile or d.factory) then
			byType[d.human] = (byType[d.human] or 0) + 1
			if st and st.manual then
				manual = manual + 1
			elseif task then
				byTask[task] = (byTask[task] or 0) + 1
			end
		end
	end
	local recent = {}
	for i = 1, min(#sub.log, 10) do
		local e = sub.log[i]
		recent[i] = { frame = e.frame, text = e.text, count = e.count or 1, ai = e.ai or false }
	end
	local zones = {}
	for i, z in ipairs(sub.zones) do
		zones[i] = zoneInfo(z)
	end
	local airThreats = 0
	for _, t in ipairs(sub.threats) do
		if t.air then
			airThreats = airThreats + 1
		end
	end
	local focus
	if sub.focus then
		focus = {}
		for defID in pairs(sub.focus) do
			focus[#focus + 1] = defs[defID].name
		end
	end
	-- what the player does in our zones: their queued builds by kind, and their units there
	local playerBuilds, playerUnits = {}, 0
	for _, p in ipairs(Player.plans) do
		if inSubZones(sub, p.x, p.z) then
			local k = defs[p.defID].kind
			playerBuilds[k] = (playerBuilds[k] or 0) + 1
		end
	end
	for _, zone in ipairs(sub.zones) do
		for _, u in ipairs(Zone.units(zone)) do
			local ud = unitDef(u)
			if ud and ud.mobile and spGetUnitTeam(u) == myTeam and (not owner[u] or (ustate[u] and ustate[u].manual)) then
				playerUnits = playerUnits + 1
			end
		end
	end
	return {
		id = sub.id,
		name = sub.name,
		role = sub.role,
		posture = sub.posture,
		paused = sub.paused,
		ai = sub.ai or false,
		directive = sub.directive,
		aiStatus = sub.aiStatus,
		status = sub.status,
		zones = zones,
		counts = sub.counts,
		spendMetal = sub.spendM,
		spendEnergy = sub.spendE,
		threats = #sub.threats,
		airThreats = airThreats,
		focus = focus,
		composition = tally(byType),
		activity = tally(byTask),
		manualUnits = manual,
		playerActivity = (playerUnits > 0 or next(playerBuilds)) and { queuedBuilds = tally(playerBuilds), unitsInZones = playerUnits } or nil,
		units = units,
		recent = recent,
	}
end

local function enemyIntel()
	local cells = {}
	for _, s in ipairs(enemySightings) do
		local age = (frame - s.frame) / 30
		if age < 180 then
			local key = floor(s.x / 1024) .. ":" .. floor(s.z / 1024)
			local c = cells[key]
			if not c then
				c = { x = 0, z = 0, sightings = 0, newestSecondsAgo = age }
				cells[key] = c
			end
			c.x, c.z = c.x + s.x, c.z + s.z
			c.sightings = c.sightings + 1
			c.newestSecondsAgo = min(c.newestSecondsAgo, age)
		end
	end
	local recent = {}
	for _, c in pairs(cells) do
		recent[#recent + 1] = { x = floor(c.x / c.sightings), z = floor(c.z / c.sightings), sightings = c.sightings, newestSecondsAgo = floor(c.newestSecondsAgo) }
	end
	local starts = {}
	for _, st in ipairs(getEnemyStarts()) do
		starts[#starts + 1] = { x = floor(st.x), z = floor(st.z), guess = st.guess or nil }
	end
	-- known enemy structures worth knowing about: intel (targets for the intelligence role) and defences
	local intel, defenses = {}, {}
	for u, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		local entry = { x = floor(e.x), z = floor(e.z), kind = d.kind, name = d.human, secondsAgo = floor((frame - e.last) / 30) }
		if d.intelStructure then
			intel[#intel + 1] = entry
		elseif d.staticDef or d.kind == "long-range artillery" then
			defenses[#defenses + 1] = entry
		end
	end
	local byRecent = function(a, b)
		return a.secondsAgo < b.secondsAgo
	end
	tsort(intel, byRecent)
	tsort(defenses, byRecent)
	for i = #intel, 13, -1 do
		intel[i] = nil
	end
	local defenseCount = #defenses
	for i = #defenses, 13, -1 do
		defenses[i] = nil
	end
	local mix = Enemy.mix()
	local types = tally(mix.types)
	for i = #types, 9, -1 do
		types[i] = nil
	end
	return {
		recentSightings = recent,
		startPositions = starts,
		-- what they field (units seen in the last 5 min), per kind; newKinds: first seen in the last 3 min
		composition = tally(mix.kinds),
		newKinds = tally(mix.recentKinds),
		topTypes = types,
		tech2Units = mix.tech2,
		intelStructures = intel,
		defenses = defenses,
		defenseCount = defenseCount,
	}
end

local function defKind(d)
	if d.factory then
		return "factory"
	elseif d.builder then
		return "constructor"
	elseif d.combat then
		return d.aaOnly and "mobile anti-air" or (d.air and "air combat" or "combat")
	elseif d.staticDef then
		return d.aaOnly and "anti-air turret" or "defense turret"
	elseif d.mex > 0 then
		return "metal extractor"
	elseif d.energy > 0 then
		return "energy"
	elseif d.conv > 0 then
		return "converter"
	elseif d.mstore > 0 or d.estore > 0 then
		return "storage"
	elseif d.radar > 0 then
		return "radar"
	elseif d.nano then
		return "construction turret"
	end
	return "other"
end

local function buildOptions(sub)
	local seen, out = {}, {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and (d.builder or d.factory) then
			local by = d.factory and "factory" or "constructors"
			for _, o in ipairs(d.options) do
				local od = defs[o]
				if od and not seen[o] then
					seen[o] = true
					out[#out + 1] = { name = od.name, human = od.human, kind = defKind(od), by = by, metal = floor(od.metal), energy = floor(od.energyCost), tech = od.tech }
				end
			end
		end
	end
	tsort(out, function(a, b)
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		return a.metal < b.metal
	end)
	return out
end

local Api = { MAX_LISTED_STRUCTURES = 60 } -- helpers behind the WG.SubCommanders strategist hooks

-- the sub's own structures (factories excluded), ones in a factory's keep-out area first
function Api.structureList(sub, kind, blockingOnly)
	local out, total = {}, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local x, _, z = spGetUnitPosition(u)
		if d and x and not d.mobile and not d.factory then
			local hx, hz = halfSize(d, Spring.GetUnitBuildFacing(u) or 0)
			local blocking = blocksFactory(x, z, hx, hz)
			local k = defKind(d)
			if (not kind or kind == "" or kind == k) and (blocking or not blockingOnly) then
				total = total + 1
				out[#out + 1] = { id = u, name = d.name, human = d.human, kind = k, x = floor(x), z = floor(z), blocksFactory = blocking, unfinished = spGetUnitIsBeingBuilt(u) and true or false, marked = sub.removals[u] or false }
			end
		end
	end
	tsort(out, function(a, b)
		if a.blocksFactory ~= b.blocksFactory then
			return a.blocksFactory
		end
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		return a.id < b.id
	end)
	for i = #out, Api.MAX_LISTED_STRUCTURES + 1, -1 do
		out[i] = nil
	end
	return { total = total, listed = #out, structures = out }
end

-- mark own structures for reclaiming; an empty list cancels pending removals
function Api.markRemovals(sub, unitIDs)
	if #unitIDs == 0 then
		sub.removals = {}
		log(sub, "pending removals cancelled")
		return { marked = 0, rejected = {} }
	end
	local canReclaim = false
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.reclaimer then
			canReclaim = true
			break
		end
	end
	if not canReclaim then
		return nil, "you have no constructor that can reclaim"
	end
	local names, rejected, marked = {}, {}, 0
	for _, u in ipairs(unitIDs) do
		local d = unitDef(u)
		local x, _, z = spGetUnitPosition(u)
		if not d or not x or owner[u] ~= sub then
			rejected[#rejected + 1] = { id = u, reason = "not one of your structures" }
		elseif d.mobile or d.factory then
			rejected[#rejected + 1] = { id = u, reason = "only structures other than factories can be removed" }
		elseif not sub.removals[u] then
			sub.removals[u] = true
			marked = marked + 1
			names[d.human] = (names[d.human] or 0) + 1
			-- don't put the same thing straight back
			badSpots[#badSpots + 1] = { x = x, z = z, untilFrame = frame + 30 * 300 }
		end
	end
	if marked > 0 then
		local parts = {}
		for n, c in pairs(names) do
			parts[#parts + 1] = c > 1 and (c .. "x " .. n) or n
		end
		log(sub, "removing " .. tconcat(parts, ", "))
		-- builders on soft tasks (assist, patrol, wreckage) switch over now; builds in progress finish first
		for u in pairs(sub.units) do
			local st = ustate[u]
			if st and st.softUntil then
				st.softUntil, st.nextThink = frame, frame
			end
		end
	end
	return { marked = marked, rejected = rejected }
end

-- area for a map picture: the whole map, or the sub's zones with some surroundings
function Api.viewBounds(sub, view)
	if view ~= "zones" or #sub.zones == 0 then
		return 0, 0, MAP_X, MAP_Z
	end
	local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
	for _, zone in ipairs(sub.zones) do
		local a, b, c, d = Zone.bounds(zone)
		x1, z1, x2, z2 = min(x1, a), min(z1, b), max(x2, c), max(z2, d)
	end
	local size = max(2000, (x2 - x1) * 1.6, (z2 - z1) * 1.6)
	local cx, cz = (x1 + x2) * 0.5, (z1 + z2) * 0.5
	return floor(max(0, cx - size * 0.5)), floor(max(0, cz - size * 0.5)), floor(min(MAP_X, cx + size * 0.5)), floor(min(MAP_Z, cz + size * 0.5))
end

-- everything the strategist bridge needs to draw a picture of x1..x2, z1..z2 (terrain comes separately)
function Api.mapView(sub, view)
	local x1, z1, x2, z2 = Api.viewBounds(sub, view)
	local out = { bounds = { x1 = x1, z1 = z1, x2 = x2, z2 = z2 }, subs = {}, zones = {}, metal = {}, units = {}, enemies = {}, intel = enemyIntel() }
	for _, s in ipairs(subs) do
		out.subs[#out.subs + 1] = { id = s.id, name = s.name, color = s.color }
		for _, zone in ipairs(s.zones) do
			out.zones[#out.zones + 1] = { sub = s.id, zone = zone }
		end
	end
	for _, spot in ipairs(metalSpots() or {}) do
		if spot.x >= x1 and spot.x <= x2 and spot.z >= z1 and spot.z <= z2 then
			local mex = extractorAt(spot)
			local taken = "free"
			if mex then
				local team = spGetUnitTeam(mex)
				taken = team == myTeam and "own" or (Spring.AreTeamsAllied(team, myTeam) and "ally" or "enemy")
			end
			out.metal[#out.metal + 1] = { x = floor(spot.x), z = floor(spot.z), taken = taken }
		end
	end
	for _, u in ipairs(Spring.GetUnitsInRectangle(x1, z1, x2, z2) or {}) do
		local x, _, z = spGetUnitPosition(u)
		local team = spGetUnitTeam(u)
		local d = unitDef(u)
		if x and team then
			if team == myTeam or Spring.AreTeamsAllied(team, myTeam) then
				if d then
					local facing = Spring.GetUnitBuildFacing(u) or 0
					local hx, hz = halfSize(d, facing)
					local s = owner[u]
					out.units[#out.units + 1] = {
						x = floor(x), z = floor(z), hx = hx, hz = hz, facing = facing,
						side = team == myTeam and "own" or "ally",
						sub = s and s.id or 0,
						structure = not d.mobile, factory = d.factory, kind = defKind(d),
						marked = s and s.removals[u] or false,
					}
				end
			else
				-- radar-only blips have no known type
				out.enemies[#out.enemies + 1] = { x = floor(x), z = floor(z), known = d ~= nil, structure = d and not d.mobile or false, air = d and d.air or false }
			end
		end
	end
	return out
end

local function logAI(sub, text)
	tinsert(sub.log, 1, { frame = frame, text = text, ai = true })
	if #sub.log > 40 then
		sub.log[#sub.log] = nil
	end
	sub.aiStatus = text
end

local function setDirective(sub, text)
	text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
	sub.directive = text ~= "" and text or nil
	log(sub, sub.directive and ("orders: " .. sub.directive) or "orders cleared")
end

local function setAI(sub, on)
	sub.ai = on and true or false
	log(sub, sub.ai and "AI strategist on" or "AI strategist off")
end

local function setFocus(sub, defIDs)
	if not defIDs or #defIDs == 0 then
		sub.focus = nil
		log(sub, "production focus: automatic")
		return
	end
	sub.focus = {}
	local names = {}
	for _, defID in ipairs(defIDs) do
		if defs[defID] and not sub.focus[defID] then
			sub.focus[defID] = true
			names[#names + 1] = defs[defID].human
		end
	end
	log(sub, "production focus: " .. tconcat(names, ", "))
end

local function exportAPI()
	WG.SubCommanders = {
		ROLES = ROLES,
		POSTURES = POSTURES,
		list = function()
			local out = {}
			for i, sub in ipairs(subs) do
				out[i] = summarize(sub)
			end
			return out
		end,
		get = function(id)
			local sub = findSub(id)
			return sub and summarize(sub)
		end,
		economy = function()
			return { metal = econ.m, metalStorage = econ.mS, metalIncome = econ.mInc, metalPull = econ.mPull or 0, energy = econ.e, energyStorage = econ.eS, energyIncome = econ.eInc, energyPull = econ.ePull or 0 }
		end,
		create = function(role, name)
			return createSub(role, name).id
		end,
		remove = function(id)
			local sub = findSub(id)
			if sub then
				deleteSub(sub)
			end
		end,
		assign = function(id, unitIDs)
			local sub = findSub(id)
			return sub and assignUnits(sub, unitIDs) or 0
		end,
		release = function(unitIDs)
			for _, u in ipairs(unitIDs) do
				releaseUnit(u)
			end
		end,
		setRole = function(id, role)
			local sub = findSub(id)
			if sub then
				setRole(sub, role)
			end
		end,
		setPosture = function(id, posture)
			local sub = findSub(id)
			if sub then
				setPosture(sub, posture)
			end
		end,
		setPaused = function(id, paused)
			local sub = findSub(id)
			if sub then
				sub.paused = paused and true or false
				log(sub, sub.paused and "paused" or "resumed")
			end
		end,
		addZone = function(id, zone)
			local sub = findSub(id)
			if sub and zone and (zone.kind == "rect" or zone.kind == "circle") then
				sub.zones[#sub.zones + 1] = zone
				log(sub, "zone added")
			end
		end,
		clearZones = function(id)
			local sub = findSub(id)
			if sub then
				sub.zones = {}
				log(sub, "zones cleared")
			end
		end,
		setFocus = function(id, unitDefNames)
			local sub = findSub(id)
			if not sub then
				return
			end
			local ids = {}
			for _, n in ipairs(unitDefNames or {}) do
				if UnitDefNames[n] then
					ids[#ids + 1] = UnitDefNames[n].id
				end
			end
			setFocus(sub, ids)
		end,
		note = function(id, text)
			local sub = findSub(id)
			if sub then
				log(sub, tostring(text))
			end
		end,
		-- strategist hooks
		setAI = function(id, on)
			local sub = findSub(id)
			if sub then
				setAI(sub, on)
			end
		end,
		setDirective = function(id, text)
			local sub = findSub(id)
			if sub then
				setDirective(sub, text)
			end
		end,
		noteAI = function(id, text)
			local sub = findSub(id)
			if sub then
				logAI(sub, tostring(text))
			end
		end,
		setAIStatus = function(id, text)
			local sub = findSub(id)
			if sub then
				sub.aiStatus = text
			end
		end,
		buildOptions = function(id)
			local sub = findSub(id)
			return sub and buildOptions(sub) or {}
		end,
		structures = function(id, kind, blockingOnly)
			local sub = findSub(id)
			return sub and Api.structureList(sub, kind, blockingOnly)
		end,
		removeStructures = function(id, unitIDs)
			local sub = findSub(id)
			if not sub then
				return nil, "no sub-commander with id " .. tostring(id)
			end
			return Api.markRemovals(sub, unitIDs or {})
		end,
		mapView = function(id, view)
			local sub = findSub(id)
			return sub and Api.mapView(sub, view)
		end,
		enemyIntel = enemyIntel,
		frame = function()
			return frame
		end,
		ownerOf = function(unitID)
			return owner[unitID] and owner[unitID].id
		end,
	}
end

--------------------------------------------------------------------------------
-- Text commands: /luaui sc <verb> [args]
--------------------------------------------------------------------------------

local HELP = {
	"Sub-Commanders: /luaui sc <command>",
	"  new [economy|defense|airdefense|army]   create one (becomes active)",
	"  assign [id]      give selected units to the active (or given) sub-commander",
	"  release          take selected units back",
	"  zone [id]        drag on the map to add a zone (shift keeps drawing)",
	"  clearzones [id]  remove all zones",
	"  role <role> [id] / posture <conserve|balanced|spend> [id]",
	"  focus [id]       factory produces only the selected unit types (none selected = automatic)",
	"  pause [id] / resume [id] / delete [id] / select [id] / list",
	"  tell [id] <orders>   standing orders in plain words for its AI strategist (empty = clear)",
	"  ai <on|off> [id]     let the AI strategist (scbridge + opencode) steer it",
	"Orders in chat: @2 <orders> (by id), @eco <orders> (name or role), @ <orders> (selected one), @all <orders>",
}

--------------------------------------------------------------------------------
-- Orders in chat: your own chat lines starting with @ (allies or all chat)
--   @2 hold the ridge     sub-commander 2
--   @eco expand east      first whose name or role starts with "eco"
--   @ hold the ridge      the selected one
--   @all fall back        every sub-commander
-- Nothing after the tag clears the orders.
--------------------------------------------------------------------------------

local Chat = { myName = Spring.GetPlayerInfo(myPlayer, false) }

function Chat.subsForTag(tag)
	if tag == "" then
		return { activeSub }
	elseif tag == "all" then
		return subs
	elseif tonumber(tag) then
		return { findSub(tonumber(tag)) }
	end
	for _, sub in ipairs(subs) do
		if sub.name:lower():find(tag, 1, true) == 1 or sub.role:find(tag, 1, true) == 1 or ROLE_INFO[sub.role].label:lower():find(tag, 1, true) == 1 then
			return { sub }
		end
	end
	return {}
end

function Chat.chatOrders(tag, text)
	local targets = Chat.subsForTag(tag:lower())
	if #targets == 0 then
		spEcho("Sub-Commanders: no sub-commander matches @" .. tag .. " (use @<id>, @<name or role>, @ for the selected one, or @all)")
		return
	end
	for _, sub in ipairs(targets) do
		setDirective(sub, text)
		local note = sub.directive and "orders received" or "orders cleared"
		if not sub.ai then
			note = note .. " (AI is off: only the AI strategist acts on orders)"
		end
		spEcho("[" .. sub.name .. "] " .. note)
	end
end

function widget:AddConsoleLine(lines)
	if not Chat.myName then
		return
	end
	local prefix = "<" .. Chat.myName .. "> "
	lines = lines:match("^%[f=%-?%d+%] (.*)$") or lines
	for line in lines:gmatch("[^\n]+") do
		if line:sub(1, #prefix) == prefix then
			local text = line:sub(#prefix + 1)
			text = text:match("^Allies: (.*)$") or text
			local tag, rest = text:match("^@(%S*)%s*(.-)%s*$")
			if tag then
				Chat.chatOrders(tag, rest)
			end
		end
	end
end

local function startZoneTool(sub)
	zoneTool = { sub = sub }
	zoneDrag = nil
	activeSub = sub
end

local function selectedDefIDs()
	local ids, seen = {}, {}
	for _, u in ipairs(spGetSelectedUnits()) do
		local defID = Spring.GetUnitDefID(u)
		if defID and not seen[defID] then
			seen[defID] = true
			ids[#ids + 1] = defID
		end
	end
	return ids
end

local function textCommand(_, line, words)
	local verb = words[1] or "help"
	local function target(argIndex)
		local n = tonumber(words[argIndex or 2])
		return n and findSub(n) or activeSub
	end
	if verb == "help" then
		for _, l in ipairs(HELP) do
			spEcho(l)
		end
	elseif verb == "new" then
		createSub(words[2])
	elseif verb == "list" then
		for _, sub in ipairs(subs) do
			spEcho(sformat("[%d] %s  %s/%s  units=%d zones=%d  %s", sub.id, sub.name, sub.role, sub.posture, sub.counts.total, #sub.zones, sub.status or ""))
		end
	else
		local sub
		if verb == "role" or verb == "posture" or verb == "ai" then
			sub = target(3)
		elseif verb == "tell" then
			sub = tonumber(words[2]) and findSub(tonumber(words[2])) or activeSub
		else
			sub = target(2)
		end
		if verb ~= "release" and not sub then
			spEcho("Sub-Commanders: no sub-commander yet, use /luaui sc new")
			return true
		end
		if verb == "assign" then
			assignUnits(sub, spGetSelectedUnits())
		elseif verb == "release" then
			for _, u in ipairs(spGetSelectedUnits()) do
				releaseUnit(u)
			end
		elseif verb == "zone" then
			startZoneTool(sub)
		elseif verb == "clearzones" then
			sub.zones = {}
			log(sub, "zones cleared")
		elseif verb == "role" then
			setRole(sub, words[2])
		elseif verb == "posture" then
			setPosture(sub, words[2])
		elseif verb == "focus" then
			setFocus(sub, selectedDefIDs())
		elseif verb == "pause" or verb == "resume" then
			sub.paused = verb == "pause"
			log(sub, sub.paused and "paused" or "resumed")
		elseif verb == "delete" then
			deleteSub(sub)
		elseif verb == "tell" then
			local text = line:gsub("^%s*tell%s*", "")
			if tonumber(words[2]) then
				text = text:gsub("^%d+%s*", "")
			end
			setDirective(sub, text)
		elseif verb == "ai" then
			setAI(sub, words[2] ~= "off")
		elseif verb == "select" then
			local list = {}
			for u in pairs(sub.units) do
				list[#list + 1] = u
			end
			Spring.SelectUnitArray(list)
			activeSub = sub
		else
			spEcho("Sub-Commanders: unknown command '" .. verb .. "' (try /luaui sc help)")
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Panel UI
--------------------------------------------------------------------------------

local function uiScale()
	local _, vsy = Spring.GetViewGeometry()
	return vsy / 1080 * Spring.GetConfigFloat("ui_scale", 1)
end

local texts = {}
local function queueText(text, x, y, size, opts, r, g, b, a)
	texts[#texts + 1] = { text, x, y, size, opts or "o", r or 1, g or 1, b or 1, a or 1 }
end

local function addButton(x1, y1, x2, y2, label, onClick, highlight, size)
	local over = false
	local mx, my = Spring.GetMouseState()
	if mx >= x1 and mx <= x2 and my >= y1 and my <= y2 then
		over = true
	end
	if highlight then
		glColor(highlight[1] * 0.45, highlight[2] * 0.45, highlight[3] * 0.45, 0.9)
	elseif over then
		glColor(0.32, 0.32, 0.36, 0.95)
	else
		glColor(0.18, 0.18, 0.2, 0.92)
	end
	glRect(x1, y1, x2, y2)
	queueText(label, (x1 + x2) * 0.5, (y1 + y2) * 0.5, size, "ocv", 1, 1, 1, 1)
	buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, onClick = onClick }
end

local function buttonRow(x1, x2, y, h, s, specs, fontSize)
	local gap = 4 * s
	local w = (x2 - x1 - gap * (#specs - 1)) / #specs
	for i, spec in ipairs(specs) do
		local bx = x1 + (i - 1) * (w + gap)
		addButton(bx, y - h, bx + w, y, spec[1], spec[2], spec[3], fontSize)
	end
end

local function truncate(text, maxChars)
	if #text > maxChars then
		return text:sub(1, maxChars - 1) .. "…"
	end
	return text
end

local function formatTime(f)
	local s = floor(f / 30)
	return sformat("%d:%02d", floor(s / 60), s % 60)
end

startOrderInput = function(sub)
	if orderInput then
		stopOrderInput(false)
	end
	if not widgetHandler:OwnText() then
		return
	end
	orderInput = { sub = sub, text = sub.directive or "" }
	Spring.SDLStartTextInput()
end

stopOrderInput = function(save)
	if not orderInput then
		return
	end
	if save then
		setDirective(orderInput.sub, orderInput.text)
	end
	orderInput = nil
	widgetHandler:DisownText()
end

local function drawSubRow(sub, x1, x2, y, s)
	local rowH = 24 * s
	local isActive = sub == activeSub
	glColor(sub.color[1], sub.color[2], sub.color[3], isActive and 0.22 or 0.08)
	glRect(x1, y - rowH, x2, y)
	glColor(sub.color[1], sub.color[2], sub.color[3], 1)
	glRect(x1, y - rowH, x1 + 5 * s, y)
	local c = sub.counts
	local name = sub.name .. (sub.paused and "  (paused)" or "")
	queueText(name, x1 + 12 * s, y - rowH * 0.5, 14 * s, "ov", 1, 1, 1, 1)
	local tag = sformat("%s · %s", ROLE_INFO[sub.role].short, POSTURE_INFO[sub.posture].label)
	queueText(tag, x2 - 8 * s, y - rowH * 0.5, 12 * s, "orv", 0.8, 0.8, 0.85, 1)
	buttons[#buttons + 1] = {
		x1 = x1,
		y1 = y - rowH,
		x2 = x2,
		y2 = y,
		onClick = function()
			activeSub = sub
		end,
	}
	y = y - rowH
	local line = sformat("B%d F%d U%d  -%.1fm/s  %s", c.builders, c.factories, c.combat + c.nanos, sub.spendM, #sub.threats > 0 and (#sub.threats .. " threats!") or "")
	queueText(line, x1 + 12 * s, y - 9 * s, 11 * s, "ov", 0.75, 0.75, 0.8, 1)
	y = y - 18 * s
	queueText(truncate(sub.status or "", 58), x1 + 12 * s, y - 8 * s, 11 * s, "ov", sub.color[1], sub.color[2], sub.color[3], 1)
	y = y - 18 * s
	if sub.ai then
		queueText(truncate("AI: " .. (sub.aiStatus or "waiting for the strategist"), 58), x1 + 12 * s, y - 8 * s, 11 * s, "ov", 0.78, 0.65, 1, 1)
		y = y - 16 * s
	end
	if sub.directive and not (orderInput and orderInput.sub == sub) then
		queueText(truncate("Orders: " .. sub.directive, 58), x1 + 12 * s, y - 8 * s, 11 * s, "ov", 1, 0.9, 0.55, 1)
		y = y - 16 * s
	end
	return y - 2 * s
end

local function drawActiveControls(sub, x1, x2, y, s)
	local h, fs = 22 * s, 11 * s
	buttonRow(x1, x2, y, h, s, {
		{ "Assign sel.", function()
			assignUnits(sub, spGetSelectedUnits())
		end },
		{ "Release sel.", function()
			for _, u in ipairs(spGetSelectedUnits()) do
				if owner[u] == sub then
					releaseUnit(u)
				end
			end
		end },
		{ "Select units", function()
			local list = {}
			for u in pairs(sub.units) do
				list[#list + 1] = u
			end
			Spring.SelectUnitArray(list)
		end },
	}, fs)
	y = y - h - 4 * s
	buttonRow(x1, x2, y, h, s, {
		{ "Role: " .. ROLE_INFO[sub.role].label, function(button)
			setRole(sub, cycle(ROLES, sub.role, button == 3 and -1 or 1))
		end },
		{ "Spend: " .. POSTURE_INFO[sub.posture].label, function(button)
			setPosture(sub, cycle(POSTURES, sub.posture, button == 3 and -1 or 1))
		end },
		{ sub.paused and "Resume" or "Pause", function()
			sub.paused = not sub.paused
			log(sub, sub.paused and "paused" or "resumed")
		end, sub.paused and { 1, 0.6, 0.2 } or nil },
	}, fs)
	y = y - h - 4 * s
	local drawing = zoneTool and zoneTool.sub == sub
	buttonRow(x1, x2, y, h, s, {
		{ drawing and "Drawing…" or "+ Zone", function()
			if drawing then
				zoneTool, zoneDrag = nil, nil
			else
				startZoneTool(sub)
			end
		end, drawing and sub.color or nil },
		{ "Clear zones", function()
			sub.zones = {}
			log(sub, "zones cleared")
		end },
		{ sub.focus and "Focus: set" or "Focus: auto", function()
			setFocus(sub, selectedDefIDs())
		end, sub.focus and { 0.5, 0.9, 1 } or nil },
	}, fs)
	y = y - h - 4 * s
	local typing = orderInput and orderInput.sub == sub
	buttonRow(x1, x2, y, h, s, {
		{ sub.ai and "AI: on" or "AI: off", function()
			setAI(sub, not sub.ai)
		end, sub.ai and { 0.78, 0.65, 1 } or nil },
		{ typing and "Save orders" or "Orders…", function()
			if typing then
				stopOrderInput(true)
			else
				startOrderInput(sub)
			end
		end, typing and { 1, 0.9, 0.55 } or nil },
		{ "Delete", function()
			deleteSub(sub)
		end },
	}, fs)
	y = y - h - 4 * s
	if typing then
		glColor(0.02, 0.02, 0.03, 0.95)
		glRect(x1, y - 22 * s, x2, y)
		local caret = (math.floor(os.clock() * 2) % 2 == 0) and "_" or " "
		local shown = orderInput.text
		if #shown > 56 then
			shown = "…" .. shown:sub(-55)
		end
		queueText(shown .. caret, x1 + 6 * s, y - 11 * s, 12 * s, "ov", 1, 0.95, 0.7, 1)
		y = y - 24 * s
		queueText("Plain words, e.g. \"hold the north ridge, prioritise anti-air\". Enter saves, Esc cancels.", x1 + 4 * s, y - 7 * s, 9.5 * s, "ov", 0.75, 0.75, 0.8, 1)
		y = y - 14 * s
	end
	y = y - 2 * s
	for i = 1, min(#sub.log, 6) do
		local e = sub.log[i]
		local text = formatTime(e.frame) .. "  " .. (e.ai and "AI: " or "") .. e.text .. ((e.count or 1) > 1 and (" x" .. e.count) or "")
		if e.ai then
			queueText(truncate(text, 62), x1 + 4 * s, y - 7 * s, 10.5 * s, "ov", 0.78, 0.65, 1, i == 1 and 1 or 0.8)
		else
			queueText(truncate(text, 62), x1 + 4 * s, y - 7 * s, 10.5 * s, "ov", 0.85, 0.85, 0.85, i == 1 and 1 or 0.75)
		end
		y = y - 15 * s
	end
	return y
end

local function panelGeometry()
	local vsx, vsy = Spring.GetViewGeometry()
	local s = uiScale()
	local w = 390 * s
	if not panel.x then
		panel.x = vsx - w - 12 * s
		panel.y = vsy - 90 * s
	end
	panel.x = max(0, min(vsx - w, panel.x))
	panel.y = max(60 * s, min(vsy, panel.y))
	return panel.x, panel.y, panel.x + w, s
end

local function drawPanel()
	buttons = {}
	texts = {}
	local x1, top, x2, s = panelGeometry()
	local pad = 8 * s
	local y = top
	-- header
	local headerH = 28 * s
	glColor(0.05, 0.05, 0.07, 0.85)
	glRect(x1, y - headerH, x2, y)
	queueText("Sub-Commanders", x1 + pad, y - headerH * 0.5, 15 * s, "ov", 1, 0.85, 0.4, 1)
	local link = WG.SubCommandersAI and WG.SubCommandersAI.linkStatus and WG.SubCommandersAI.linkStatus()
	if link then
		local online = link == "online"
		local titleW = font and font:GetTextWidth("Sub-Commanders") * 15 * s or 120 * s
		queueText("AI " .. link, x1 + pad + titleW + 10 * s, y - headerH * 0.5, 10.5 * s, "ov", online and 0.78 or 0.6, online and 0.65 or 0.6, online and 1 or 0.6, 1)
	end
	panel.header = { x1 = x1, y1 = y - headerH, x2 = x2 - 150 * s, y2 = y }
	local bw = 66 * s
	addButton(x2 - pad - bw, y - headerH + 4 * s, x2 - pad, y - 4 * s, "+ New", function(button)
		createSub(button == 3 and "defense" or "economy")
	end, nil, 12 * s)
	addButton(x2 - pad - bw - 4 * s - 28 * s, y - headerH + 4 * s, x2 - pad - bw - 4 * s, y - 4 * s, panel.collapsed and "▸" or "▾", function()
		panel.collapsed = not panel.collapsed
	end, nil, 12 * s)
	y = y - headerH
	if panel.collapsed then
		panel.bottom = y
		return
	end
	if not canControl then
		queueText("Unit-control widgets are disabled in this game.", x1 + pad, y - 12 * s, 11 * s, "ov", 1, 0.5, 0.4, 1)
		y = y - 22 * s
	end
	if #subs == 0 then
		queueText("No sub-commanders yet.", x1 + pad, y - 14 * s, 12 * s, "ov", 0.85, 0.85, 0.85, 1)
		queueText("Click + New, select units, then Assign sel.", x1 + pad, y - 32 * s, 11 * s, "ov", 0.7, 0.7, 0.75, 1)
		y = y - 44 * s
	end
	for _, sub in ipairs(subs) do
		y = drawSubRow(sub, x1 + pad, x2 - pad, y - 4 * s, s)
		if sub == activeSub then
			y = drawActiveControls(sub, x1 + pad, x2 - pad, y - 2 * s, s)
		end
	end
	if zoneTool then
		queueText("Drag on the map to add a zone · click = circle · shift = keep drawing · right-click = done", x1 + pad, y - 10 * s, 10 * s, "ov", 1, 0.9, 0.5, 1)
		y = y - 20 * s
	end
	panel.bottom = y - pad
end

local function drawPanelBackground(x1, x2, top, bottom)
	glColor(0.05, 0.05, 0.07, 0.62)
	glRect(x1, bottom, x2, top)
end

local function flushTexts()
	if not font then
		font = WG.fonts and WG.fonts.getFont and WG.fonts.getFont() or gl.LoadFont("FreeSansBold.otf", 32, 6, 1.6)
	end
	font:Begin()
	for i = 1, #texts do
		local t = texts[i]
		font:SetTextColor(t[6], t[7], t[8], t[9])
		font:Print(t[1], t[2], t[3], t[4], t[5])
	end
	font:End()
	texts = {}
end

--------------------------------------------------------------------------------
-- World drawing
--------------------------------------------------------------------------------

local function groundY(x, z)
	return spGetGroundHeight(x, z) + 6
end

local function drawRectOutline(x1, z1, x2, z2)
	gl.BeginEnd(GL.LINE_STRIP, function()
		local step = 48
		for x = x1, x2, step do
			glVertex(x, groundY(x, z1), z1)
		end
		for z = z1, z2, step do
			glVertex(x2, groundY(x2, z), z)
		end
		for x = x2, x1, -step do
			glVertex(x, groundY(x, z2), z2)
		end
		for z = z2, z1, -step do
			glVertex(x1, groundY(x1, z), z)
		end
		glVertex(x1, groundY(x1, z1), z1)
	end)
end

-- the lanes kept free of structures, faintly, inside a zone
function Lanes.draw(zone)
	local x1, z1, x2, z2 = Zone.bounds(zone)
	local S, step = Lanes.spacing, 48
	glLineWidth(1)
	glColor(1, 1, 1, 0.12)
	for lx = math.ceil(x1 / S) * S, x2, S do
		gl.BeginEnd(GL.LINE_STRIP, function()
			for z = z1, z2, step do
				if Zone.contains(zone, lx, z) then
					glVertex(lx, groundY(lx, z), z)
				end
			end
		end)
	end
	for lz = math.ceil(z1 / S) * S, z2, S do
		gl.BeginEnd(GL.LINE_STRIP, function()
			for x = x1, x2, step do
				if Zone.contains(zone, x, lz) then
					glVertex(x, groundY(x, lz), lz)
				end
			end
		end)
	end
end

local function drawZone(zone, color, alpha, width)
	glColor(color[1], color[2], color[3], alpha)
	glLineWidth(width)
	if zone.kind == "circle" then
		glDrawGroundCircle(zone.x, groundY(zone.x, zone.z), zone.z, zone.r, 64)
		glLineWidth(max(1, width * 0.5))
		glColor(color[1], color[2], color[3], alpha * 0.35)
		glDrawGroundCircle(zone.x, groundY(zone.x, zone.z), zone.z, zone.r - 24, 64)
	else
		drawRectOutline(zone.x1, zone.z1, zone.x2, zone.z2)
		glLineWidth(max(1, width * 0.5))
		glColor(color[1], color[2], color[3], alpha * 0.35)
		drawRectOutline(zone.x1 + 24, zone.z1 + 24, zone.x2 - 24, zone.z2 - 24)
	end
end

local function drawPlans()
	glLineWidth(1.5)
	for builderID, p in pairs(planned) do
		local c = p.sub.color
		local d = defs[p.defID]
		glColor(c[1], c[2], c[3], 0.85)
		glDrawGroundCircle(p.x, groundY(p.x, p.z), p.z, max(d.hx, d.hz) + 8, 20)
		local x, y, z = spGetUnitPosition(builderID)
		if x then
			glColor(c[1], c[2], c[3], 0.45)
			gl.BeginEnd(GL.LINES, function()
				glVertex(x, y + 10, z)
				glVertex(p.x, groundY(p.x, p.z) + 4, p.z)
			end)
		end
	end
end

local function drawUnitMarkers(sub)
	local c = sub.color
	glLineWidth(2)
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and (d.mobile or d.factory) then
			local x, y, z = spGetUnitPosition(u)
			if x then
				local st = ustate[u]
				if st and st.manual then
					glColor(1, 1, 1, 0.8)
				else
					glColor(c[1], c[2], c[3], 0.9)
				end
				glDrawGroundCircle(x, y, z, max(d.hx, d.hz) + 10, 16)
			end
		end
	end
end

-- structures waiting to be reclaimed: red rings
local function drawRemovals()
	glLineWidth(2)
	glColor(1, 0.25, 0.2, 0.9)
	for _, sub in ipairs(subs) do
		for u in pairs(sub.removals) do
			local d = unitDef(u)
			local x, y, z = spGetUnitPosition(u)
			if d and x then
				glDrawGroundCircle(x, y, z, max(d.hx, d.hz) + 12, 20)
			end
		end
	end
end

function widget:DrawWorldPreUnit()
	if #subs == 0 and not zoneDrag then
		return
	end
	gl.DepthTest(false)
	for _, sub in ipairs(subs) do
		local isActive = sub == activeSub
		for _, zone in ipairs(sub.zones) do
			drawZone(zone, sub.color, isActive and 0.9 or 0.45, isActive and 3 or 2)
		end
	end
	drawPlans()
	if activeSub then
		drawUnitMarkers(activeSub)
		for _, zone in ipairs(activeSub.zones) do
			Lanes.draw(zone)
		end
	end
	drawRemovals()
	if zoneDrag and zoneTool then
		local c = zoneTool.sub.color
		local z = zoneDrag
		drawZone({ kind = "rect", x1 = min(z.x1, z.x2), z1 = min(z.z1, z.z2), x2 = max(z.x1, z.x2), z2 = max(z.z1, z.z2) }, c, 1, 3)
	end
	glLineWidth(1)
	glColor(1, 1, 1, 1)
end

local function drawZoneLabels(s)
	for _, sub in ipairs(subs) do
		for i, zone in ipairs(sub.zones) do
			local x, z
			if zone.kind == "circle" then
				x, z = zone.x, zone.z - zone.r
			else
				x, z = (zone.x1 + zone.x2) * 0.5, zone.z1
			end
			local sx, sy, sz = Spring.WorldToScreenCoords(x, groundY(x, z), z)
			if sz and sz < 1 then
				queueText(sub.name, sx, sy + 6 * s, 13 * s, "oc", sub.color[1], sub.color[2], sub.color[3], 0.95)
			end
		end
	end
end

function widget:DrawScreen()
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then
		return
	end
	local x1, top, x2, s = panelGeometry()
	-- measure pass would be nicer; draw background using last frame's bottom
	if panel.bottom then
		drawPanelBackground(x1, x2, top, panel.bottom)
	end
	drawPanel()
	drawZoneLabels(s)
	flushTexts()
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function overPanel(x, y)
	if not panel.x or not panel.bottom then
		return false
	end
	local x1, top, x2 = panelGeometry()
	return x >= x1 and x <= x2 and y <= top and y >= panel.bottom
end

function widget:IsAbove(x, y)
	return overPanel(x, y)
end

function widget:GetTooltip(x, y)
	return "Sub-Commanders: select units and press Assign sel. Right-click Role/Spend to cycle backwards."
end

local function worldPos(x, y)
	local kind, pos = Spring.TraceScreenRay(x, y, true)
	if kind == "ground" and pos then
		return pos[1], pos[3]
	end
end

function widget:MousePress(x, y, button)
	if overPanel(x, y) then
		for i = #buttons, 1, -1 do
			local b = buttons[i]
			if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
				b.onClick(button)
				return true
			end
		end
		local h = panel.header
		if h and button == 1 and x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then
			panel.dragging = { dx = x - panel.x, dy = y - panel.y }
		end
		return true
	end
	if zoneTool then
		if button == 3 then
			zoneTool, zoneDrag = nil, nil
			return true
		end
		if button == 1 then
			local wx, wz = worldPos(x, y)
			if wx then
				zoneDrag = { x1 = wx, z1 = wz, x2 = wx, z2 = wz }
				return true
			end
		end
	end
	return false
end

function widget:MouseMove(x, y, dx, dy, button)
	if panel.dragging then
		panel.x = x - panel.dragging.dx
		panel.y = y - panel.dragging.dy
		return
	end
	if zoneDrag then
		local wx, wz = worldPos(x, y)
		if wx then
			zoneDrag.x2, zoneDrag.z2 = wx, wz
		end
	end
end

function widget:MouseRelease(x, y, button)
	if panel.dragging then
		panel.dragging = false
		return true
	end
	if zoneDrag and zoneTool then
		local sub = zoneTool.sub
		local z = zoneDrag
		local w, h = abs(z.x2 - z.x1), abs(z.z2 - z.z1)
		if w < 96 and h < 96 then
			local cx, cz = clampToMap(z.x1, z.z1)
			sub.zones[#sub.zones + 1] = { kind = "circle", x = cx, z = cz, r = 700 }
		else
			sub.zones[#sub.zones + 1] = { kind = "rect", x1 = max(0, min(z.x1, z.x2)), z1 = max(0, min(z.z1, z.z2)), x2 = min(MAP_X, max(z.x1, z.x2)), z2 = min(MAP_Z, max(z.z1, z.z2)) }
		end
		log(sub, sformat("zone %d added", #sub.zones))
		for u in pairs(sub.units) do
			local st = ustate[u]
			if st then
				st.nextThink = frame
			end
		end
		zoneDrag = nil
		local _, _, _, shift = Spring.GetModKeyState()
		if not shift then
			zoneTool = nil
		end
		return true
	end
	return false
end

local function dropLastUtf8(text)
	local i = #text
	while i > 0 do
		local b = text:byte(i)
		if b < 0x80 or b >= 0xC0 then
			return text:sub(1, i - 1)
		end
		i = i - 1
	end
	return ""
end

function widget:KeyPress(key)
	if orderInput then
		if key == 13 or key == 271 then -- return / keypad enter
			stopOrderInput(true)
		elseif key == 27 then
			stopOrderInput(false)
		elseif key == 8 then
			orderInput.text = dropLastUtf8(orderInput.text)
		end
		return true
	end
	if zoneTool and key == 27 then -- escape
		zoneTool, zoneDrag = nil, nil
		return true
	end
	return false
end

function widget:TextInput(char)
	if orderInput then
		if #orderInput.text < 300 then
			orderInput.text = orderInput.text .. char
		end
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Unit events
--------------------------------------------------------------------------------

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	if unitTeam ~= myTeam or not builderID then
		return
	end
	local sub = owner[builderID]
	if not sub then
		return
	end
	local st = ustate[builderID]
	if st and st.task and st.task.kind == "build" then
		st.task.started = true
	end
	-- factories stay with the player until assigned, otherwise everything they make would join too
	local d = defs[unitDefID]
	if d and d.factory then
		log(sub, d.human .. " stays yours: assign it to me if I should produce with it")
		return
	end
	addUnit(sub, unitID)
	getState(unitID).graceUntil = math.huge
	if CMD_PRIORITY and d and (d.builder or d.nano) then
		getState(unitID).needsPriority = true
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local sub = owner[unitID]
	if not sub then
		return
	end
	local st = getState(unitID)
	st.nextThink = frame
	st.graceUntil = frame + 60
	if st.needsPriority then
		st.needsPriority = nil
		applyPriority(sub, unitID)
	end
	local d = defs[unitDefID]
	if d and (d.factory or d.builder) then
		log(sub, "new " .. d.human)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	local sub = owner[unitID]
	if sub then
		local d = defs[unitDefID]
		if d and (d.mobile or d.factory) and not spGetUnitIsBeingBuilt(unitID) then
			log(sub, "lost " .. d.human)
		end
		releaseUnit(unitID, true)
	end
	ustate[unitID] = nil
	if Enemy.units[unitID] then
		Enemy.units[unitID] = nil
		Enemy.known = Enemy.known - 1
	end
end

function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
	if owner[unitID] and newTeam ~= myTeam then
		releaseUnit(unitID)
	end
end

-- re-plan right away so other idle-builder helpers don't grab our units first
function widget:UnitIdle(unitID)
	local sub = owner[unitID]
	local st = ustate[unitID]
	if not sub or not st then
		return
	end
	local d = unitDef(unitID)
	if d and d.builder and not sub.paused and not spGetUnitIsBeingBuilt(unitID) and not manualHeld(unitID, st, d) then
		st.nextThink = 0
		if builderNeedsThink(unitID, st) then
			thinkBuilder(sub, unitID, d, st)
		end
	else
		st.nextThink = min(st.nextThink, frame + 2)
	end
end

-- Recoil reports every order as fromSynced with the issuing player's number, gadget
-- orders included, so "ours or not" is decided by matching the orders we gave.
function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, playerID, fromSynced, fromLua)
	if not owner[unitID] or playerID ~= myPlayer then
		return
	end
	local st = getState(unitID)
	local ours = st.expect[cmdID]
	if ours and frame - ours <= 45 then
		return
	end
	-- fresh units get move-out orders from their factory
	if frame < (st.graceUntil or 0) then
		return
	end
	-- other helper widgets (e.g. Auto Repair Idle Builders) mark their orders internal
	if type(cmdOpts) == "table" and cmdOpts.internal then
		return
	end
	-- the player orders what they have selected; helper widgets order unselected units
	-- (e.g. "Idle Constructor Guard After Build" makes builders guard a factory forever).
	-- A build order we didn't give is always the player's: helpers don't place buildings.
	if cmdID >= 0 and not Spring.IsUnitSelected(unitID) then
		return
	end
	if cmdID < 0 or MANUAL_CMDS[cmdID] then
		if not st.manual then
			local d = defs[unitDefID]
			local what = cmdID < 0 and ("build " .. (defs[-cmdID] and defs[-cmdID].human or "?")) or MANUAL_CMDS[cmdID]
			log(owner[unitID], sformat("you took over %s (%s), resuming when it's idle", d and d.human or "a unit", what))
		end
		local was = st.manual
		st.manual = true
		st.manualUntil = frame + MANUAL_HOLD_FRAMES
		planned[unitID] = nil
		if not was then
			Player.restorePriority(owner[unitID], unitID)
		end
	end
end

function widget:UnitEnteredLos(unitID, unitTeam)
	if unitTeam and Spring.AreTeamsAllied(unitTeam, myTeam) then
		return
	end
	local x, _, z = spGetUnitPosition(unitID)
	if x then
		enemySightings[#enemySightings + 1] = { x = x, z = z, frame = frame }
		if #enemySightings > 64 then
			tremove(enemySightings, 1)
		end
		local defID = Spring.GetUnitDefID(unitID)
		if defID and defs[defID] then
			local e = Enemy.units[unitID]
			if not e then
				e = { defID = defID, first = frame }
				Enemy.units[unitID] = e
				Enemy.known = Enemy.known + 1
			end
			e.last, e.x, e.z = frame, x, z
		end
	end
end

-- forget enemies that died, and structures whose spot we can see empty
function Enemy.prune()
	local oldest, oldestFrame
	for u, e in pairs(Enemy.units) do
		if not defs[e.defID].mobile and Spring.IsPosInLos(e.x, 0, e.z, myAlly) and not spGetUnitPosition(u) then
			Enemy.units[u] = nil
			Enemy.known = Enemy.known - 1
		elseif not oldestFrame or e.last < oldestFrame then
			oldest, oldestFrame = u, e.last
		end
	end
	if Enemy.known > 1500 and oldest then
		Enemy.units[oldest] = nil
		Enemy.known = Enemy.known - 1
	end
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

function widget:GameFrame(n)
	frame = n
	if n % THINK_EVERY ~= 0 then
		return
	end
	local combatPass = n % COMBAT_EVERY == 0
	econUpdate()
	Player.refresh()
	if n % 60 == 0 then
		refreshPriorities()
	end
	if n % 300 == 0 then
		Enemy.prune()
	end
	-- forget stale plans
	for unitID, p in pairs(planned) do
		if n - p.frame > 30 * 90 or not owner[unitID] then
			planned[unitID] = nil
		end
	end
	if combatPass then
		-- threats everywhere first: armies also answer raids on the other sub-commanders' zones
		baseThreats = {}
		for _, sub in ipairs(subs) do
			updateCounts(sub)
			sub.threats = scanThreats(sub)
			for _, t in ipairs(sub.threats) do
				baseThreats[#baseThreats + 1] = t
			end
		end
	end
	local budget = MAX_THINKS_PER_PASS
	for _, sub in ipairs(subs) do
		budget = runSub(sub, budget, combatPass)
	end
end

--------------------------------------------------------------------------------
-- Persistence: keep sub-commanders across /luaui reload in the same game
--------------------------------------------------------------------------------

local function serialize()
	local out = {}
	for _, sub in ipairs(subs) do
		local units = {}
		for u in pairs(sub.units) do
			local d = unitDef(u)
			if d then
				units[#units + 1] = { u, d.name }
			end
		end
		local focus
		if sub.focus then
			focus = {}
			for defID in pairs(sub.focus) do
				focus[#focus + 1] = defs[defID].name
			end
		end
		out[#out + 1] = { id = sub.id, name = sub.name, role = sub.role, posture = sub.posture, paused = sub.paused, zones = sub.zones, colorIndex = sub.colorIndex, units = units, focus = focus, ai = sub.ai, directive = sub.directive }
	end
	return out
end

local function restore(game)
	if not game or game.map ~= Game.mapName or game.team ~= myTeam then
		return
	end
	local now = spGetGameFrame()
	if now <= 0 or now < game.frame or (os and os.time and game.time and os.time() - game.time > 1800) then
		return
	end
	for _, s in ipairs(game.subs or {}) do
		local sub = createSub(s.role, s.name)
		sub.id = s.id
		nextSubID = max(nextSubID, s.id + 1)
		sub.posture = POSTURE_INFO[s.posture] and s.posture or "balanced"
		sub.paused = s.paused and true or false
		sub.ai = s.ai and true or false
		sub.directive = s.directive
		sub.zones = s.zones or {}
		sub.colorIndex = s.colorIndex or sub.colorIndex
		sub.color = PALETTE[sub.colorIndex] or sub.color
		for _, pair in ipairs(s.units or {}) do
			local u, defName = pair[1], pair[2]
			local d = unitDef(u)
			if d and d.name == defName and spGetUnitTeam(u) == myTeam then
				addUnit(sub, u)
			end
		end
		if s.focus then
			local ids = {}
			for _, n in ipairs(s.focus) do
				if UnitDefNames[n] then
					ids[#ids + 1] = UnitDefNames[n].id
				end
			end
			setFocus(sub, ids)
		end
		log(sub, "restored after reload")
	end
	activeSub = subs[1]
end

function widget:GetConfigData()
	local data = { panelX = panel.x, panelY = panel.y, collapsed = panel.collapsed }
	local f = spGetGameFrame()
	if f > 0 and #subs > 0 then
		data.game = { map = Game.mapName, team = myTeam, frame = f, time = os and os.time and os.time() or nil, subs = serialize() }
	end
	return data
end

function widget:SetConfigData(data)
	savedConfig = data
	if data then
		panel.x, panel.y = data.panelX, data.panelY
		panel.collapsed = data.collapsed and true or false
	end
end

--------------------------------------------------------------------------------
-- Init / shutdown
--------------------------------------------------------------------------------

local function checkSpectator()
	if Spring.GetSpectatingState() then
		widgetHandler:RemoveWidget()
		return true
	end
	return false
end

function widget:PlayerChanged()
	myTeam = Spring.GetMyTeamID()
	myAlly = Spring.GetMyAllyTeamID()
	myPlayer = Spring.GetMyPlayerID()
	checkSpectator()
end

function widget:ViewResize()
	font = nil
end

function widget:Initialize()
	if checkSpectator() then
		return
	end
	if widget.canControlUnits == false then
		canControl = false
		spEcho("Sub-Commanders: this game disallows unit-control widgets; sub-commanders will only observe.")
	end
	frame = spGetGameFrame()
	widgetHandler:AddAction("sc", textCommand, nil, "t")
	exportAPI()
	if savedConfig then
		restore(savedConfig.game)
	end
end

function widget:Shutdown()
	if orderInput then
		stopOrderInput(false)
	end
	WG.SubCommanders = nil
end
