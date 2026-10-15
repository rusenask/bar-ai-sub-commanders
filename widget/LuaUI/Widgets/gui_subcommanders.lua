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

local THINK_EVERY = 15 -- frames between scheduler passes (0.5 s)
local COMBAT_EVERY = 30 -- frames between combat / bookkeeping passes
local BUILDER_COOLDOWN = 45 -- min frames between decisions for one builder
local SOFT_TASK_FRAMES = 30 * 20 -- assist / reclaim / patrol tasks are re-evaluated after this
local MANUAL_HOLD_FRAMES = 30 * 10 -- after a player order, leave the unit alone at least this long
local MAX_THINKS_PER_PASS = 8
-- constants kept out of the main chunk's locals (BAR's Lua refuses a chunk with more than 200:
-- scripts/lua-locals.sh)
local Const = {}

--------------------------------------------------------------------------------
-- Roles and postures
--------------------------------------------------------------------------------

-- the Air Force does air attack and air defence both (anti-air turrets, mobile anti-air, fighters,
-- gunships, bombers); "airdefense" (the old Air Defense role) is an alias of it
local ROLES = { "economy", "defense", "army", "intelligence", "air" }
local ROLE_INFO = {
	economy = { label = "Economy", short = "ECO" },
	defense = { label = "Defense", short = "DEF" },
	army = { label = "Army", short = "ARMY" },
	intelligence = { label = "Intelligence", short = "INTEL" },
	air = { label = "Air Force", short = "AIR" },
}
local ROLE_ALIASES = { airdefense = "air", aa = "air", ["air defense"] = "air", ["air force"] = "air", intel = "intelligence" }
local function canonicalRole(role)
	return ROLE_ALIASES[role] or role
end

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

local defs = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)

-- The engine modules (design/engine.md): doctrine data, the threat map (world model), threat-aware
-- pathing, squad decisions, production and auto zones. Plain Lua, unit-tested in widget/tests.
local Engine = {}
do
	local function include(name)
		return VFS.Include("LuaUI/Include/" .. name .. ".lua", nil, VFS.RAW_FIRST)
	end
	Engine.D = include("sc_doctrine")
	Engine.tm = include("sc_threatmap")({ defs = defs, mapX = Game.mapSizeX, mapZ = Game.mapSizeZ, doctrine = Engine.D })
	Engine.path = include("sc_pathing")(Engine.tm)
	Engine.squads = include("sc_squads")({ tm = Engine.tm, doctrine = Engine.D })
	Engine.prod = include("sc_production")({ defs = defs, doctrine = Engine.D })
	Engine.zones = include("sc_autozones")({ mapX = Game.mapSizeX, mapZ = Game.mapSizeZ })
	Engine.terr = include("sc_territory")({ mapX = Game.mapSizeX, mapZ = Game.mapSizeZ, cell = 256, reach = 700 })
	Engine.team = include("sc_team")({ doctrine = Engine.D })
	Engine.com = include("sc_commander")({ doctrine = Engine.D })
	Engine.air = include("sc_air")({ doctrine = Engine.D })
	Engine.micro = include("sc_micro")({ doctrine = Engine.D })
	Engine.strategic = include("sc_strategic")({ doctrine = Engine.D })
	Engine.fb = include("sc_firebase")({ doctrine = Engine.D })
	Engine.armyStyle, Engine.armyStyleNow, Engine.armyStyleSince = "auto", "balanced", 0
	Engine.comMode, Engine.comPersonality = "auto", "careful"
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
Const.COMPOSITION_WINDOW = 30 * 60 * 5

function Enemy.mix()
	if Enemy.mixFrame == frame then
		return Enemy.mixCache
	end
	Enemy.mixFrame = frame
	local mix = { total = 0, air = 0, bombers = 0, ranged = 0, raiders = 0, heavy = 0, naval = 0, tech2 = 0, kinds = {}, recentKinds = {}, types = {} }
	for _, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if frame - e.last < Const.COMPOSITION_WINDOW and (d.mobile or d.staticDef) and d.kind ~= "constructor" and d.kind ~= "commander" then
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
	-- a build order is recognised by what and where too, however late it arrives (network latency; at
	-- test speed it outlasted the time window and our order passed for the player's)
	if cmdID < 0 and params and params[3] then
		st.expectBuild = { id = cmdID, x = params[1], z = params[3], frame = frame }
	end
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

-- metal spots with no extractor of anyone's on them (as far as we know) and out of known threat,
-- counted every 10 s
Engine.freeSpotsCache = { frame = -9999, n = 0 }
function Engine.freeSpots()
	local C = Engine.freeSpotsCache
	if frame - C.frame < 300 then
		return C.n
	end
	local spots, n = WG.resource_spot_finder and WG.resource_spot_finder.metalSpotsList, 0
	for _, sp in ipairs(spots or {}) do
		local taken = false
		for _, u in ipairs(spGetUnitsInCylinder(sp.x, sp.z, 60)) do
			local ud = unitDef(u)
			if ud and ud.mex > 0 then
				taken = true
				break
			end
		end
		if not taken and Engine.tm.threat(sp.x, sp.z) <= 0 then
			n = n + 1
		end
	end
	C.frame, C.n = frame, n
	return n
end

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
Const.EXIT_LANE = 300
Const.EXIT_LANE_AIR = 140
Const.FACTORY_RING = 64

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
				local lane = makesAircraft(fd) and Const.EXIT_LANE_AIR or Const.EXIT_LANE
				local w = 24 -- lane is a bit wider than the factory
				keepOut[#keepOut + 1] = { x - hx - Const.FACTORY_RING, z - hz - Const.FACTORY_RING, x + hx + Const.FACTORY_RING, z + hz + Const.FACTORY_RING }
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
Const.MAX_HALF = 96
local function areaClear(d, x, z, gap, facing)
	local hx, hz = halfSize(d, facing or 0)
	if Lanes.blocks(d, x, z, hx, hz) then
		return false
	end
	local reach = max(gap, 64) + Const.MAX_HALF
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

-- Search outward from (ax, az) for a buildable spot inside the sub's zones, away from enemies seen there
-- in the last seconds unless our own firepower covers it (threat map; older memories don't block building:
-- in engine-v4 they kept raided bases from rebuilding energy).
-- opts: gap, rings, facing, samples, score(x, z) -> number (higher is better), underFire (allow threat),
-- anywhere (not limited to the sub's zones: radar serves the whole team)
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
			if x > 64 and z > 64 and x < MAP_X - 64 and z < MAP_Z - 64 and (opts.anywhere or inSubZones(sub, x, z)) then
				local bx, by, bz = Spring.Pos2BuildPos(defID, x, spGetGroundHeight(x, z), z, facing)
				if Spring.TestBuildOrder(defID, bx, by, bz, facing) > 0 and not nearMetalSpot(bx, bz, d) and not isBadSpot(bx, bz) and areaClear(d, bx, bz, gap, facing)
					and (opts.underFire or Engine.tm.enemyPower(bx, bz, 600, frame, { fresh = true }) <= Engine.tm.influence(bx, bz)) then
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
	-- a long walk through enemy reach: take the threat-aware route (sc_pathing), or don't go at all
	local route
	local ux, _, uz = spGetUnitPosition(unitID)
	if ux and dist2(ux, uz, x, z) > 1000 * 1000 and Engine.path.lineDanger(ux, uz, x, z) > 0 then
		local danger
		route, danger = Engine.path.route(ux, uz, x, z, { avoid = 6 })
		if not route or danger > 0 then
			return false
		end
	end
	local opts
	if route and #route > 1 then
		for i = 1, #route - 1 do
			order(unitID, CMD.MOVE, { route[i].x, spGetGroundHeight(route[i].x, route[i].z), route[i].z }, i > 1 and { "shift" } or nil)
		end
		opts = { "shift" }
	end
	if not order(unitID, -defID, { x, spGetGroundHeight(x, z), z, facing or 0 }, opts) then
		return false
	end
	planned[unitID] = { sub = sub, defID = defID, x = x, z = z, facing = facing or 0, frame = frame }
	setTask(unitID, "build", d.human, false, x, z)
	getState(unitID).task.started = false
	getState(unitID).task.routed = opts ~= nil
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
	-- strategic structures (shields, long-range cannons, Juno: Jobs.strategic) are deliberate: no cost cap
	-- (a 5000-metal cannon was over it below 270 metal/s), only a little metal in hand to start
	if kind == "strategic" then
		return econ.mFrac >= 0.1
	end
	if cost > costCap(sub, kind == "essential" and 1.5 or 1) then
		return false
	end
	if kind == "essential" then
		return true
	end
	-- the metal kept in reserve: a share of storage, but at most a few seconds of income (with 9000 storage,
	-- 25% held 2250 metal back while the player built: factories idle "with a good amount of resources")
	local frac = Player.yield and max(p.minM, 0.25) or p.minM
	local reserve = min(frac * (econ.mS or 0), max(150, (econ.mInc or 0) * (Player.yield and 8 or 4)))
	if metal > 20 and (econ.m or 0) < reserve then
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
	-- under a firebase's guns (doctrine.firebase.expandRadius, two turrets standing): ours to take even
	-- forward, as long as we're the stronger there
	if Engine.firebaseCovers(spot.x, spot.z) then
		return Engine.tm.threat(spot.x, spot.z) <= Engine.tm.influence(spot.x, spot.z)
	end
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
	-- the threat map remembers raids (mobile threat fades over ~90 s) and enemy defences
	if Engine.tm.threat(spot.x, spot.z) > 0 then
		return false
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
		local rs = Engine.raidedAt(spot.x, spot.z)
		local hardened = not rs or Engine.turretsNear(spot.x, spot.z, Engine.D.turrets.extractorCoverRadius) >= Engine.D.turrets.harden.turrets
		if hardened and (spotCooldown[i] or 0) <= frame and (inZone or (sub.role == "economy" and not d.commander and Engine.auto(sub).expand and Jobs.safeExpansion(sub, spot)))
			and Engine.tm.threat(spot.x, spot.z) <= Engine.tm.influence(spot.x, spot.z) and not plannedConflict(defs[bestMex], spot.x, spot.z, EXTRACTOR_RADIUS) then
			local exID, exDef = extractorAt(spot)
			local upgrade = exID and exDef.mex < bestYield and spGetUnitTeam(exID) == myTeam and not spGetUnitIsBeingBuilt(exID)
			if not exID or upgrade then
				-- walking distance plus safety: the corner and behind home before the middle (sc_territory)
				local safety = (sub.role == "economy" and Engine.homeX) and Engine.terr.spotCost(spot.x, spot.z, { Engine.homeX, Engine.homeZ }, { Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2 }) or 0
				-- tier-2 constructors go for upgrades first (several times the metal of a new T1 spot)
				local upgradeCost = upgrade and ((d.tech or 1) >= 2 and -1500 or 400) or 0
				candidates[#candidates + 1] = { i = i, spot = spot, d = sqrt(dist2(ux, uz, spot.x, spot.z)) + upgradeCost + (inZone and 0 or 700) + safety }
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
					local ok = issueBuild(sub, unitID, bestMex, pos.x, pos.z, 0, "new metal spot")
					if ok then
						Jobs.escortTurret(sub, unitID, d, pos.x, pos.z)
					end
					return ok
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
			-- strategic structures stand where they must (a cannon's site toward the enemy, a silo behind the
			-- base), outside the builder's zones: in zone only, a cannon was "can't place" 63 times with metal
			-- 52-99% full (g70)
			local x, z = findBuildSpot(sub, o, ax, az, { gap = gap or Lanes.gapFor(defs[o]), rings = 12, anywhere = kind == "strategic" })
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

-- where generators are safest (doctrine.economy.safeGenerators): behind our base, away from the enemy,
-- out of known threat, spread across (our games lost ~123 wind turbines a game to raids)
function Engine.safeEnergyAnchor()
	local hx, hz, ex, ez = Engine.homeX, Engine.homeZ, Engine.enemyX, Engine.enemyZ
	if not hx or not ex then
		return nil
	end
	local dx, dz = hx - ex, hz - ez
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local bx, bz = dx / len, dz / len -- away from the enemy
	local px, pz = -bz, bx
	for _, back in ipairs({ 300, 500, 700, 900 }) do
		local side = (random() - 0.5) * 2 * 500
		local x, z = clampToMap(hx + bx * back + px * side, hz + bz * back + pz * side)
		if Engine.tm.threat(x, z) <= 0 then
			return x, z
		end
	end
	return nil
end

function Jobs.energy(sub, unitID, d, ux, uz, urgent)
	local ax, az = anchorFor(sub, ux, uz)
	if Engine.D.economy.safeGenerators and not (urgent and econ.eFrac < 0.2) then
		local sx, sz = Engine.safeEnergyAnchor()
		if sx then
			ax, az = sx, sz
		end
	end
	-- out of energy: cheap generators that are up in seconds beat efficient ones that take minutes
	local cap = urgent and econ.eFrac < 0.2 and max(60, costCap(sub) * 0.3) or costCap(sub, urgent and 1.5 or 1)
	return buildCheapestUseful(sub, unitID, d, ax, az, function(od)
		return od.energy > 0 and od.cost <= cap
	end, function(od)
		return od.energy / max(od.cost, 1)
	end, urgent and "energy (short)" or "energy", urgent and "essential" or "energy")
end

function Jobs.storage(sub, unitID, d, ux, uz)
	local ax, az = anchorFor(sub, ux, uz)
	if econ.mFrac > 0.9 and econ.mS < Engine.D.economy.maxStorage then
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

-- a factory the player gave a sub-commander was destroyed: rebuild it where it stood
function Jobs.rebuildFactory(sub, unitID, d, ux, uz)
	if d.commander or econ.mFrac < 0.15 then
		return false
	end
	for _, other in ipairs(subs) do
		local lost = other.lostFactories
		if lost and #lost > 0 then
			for i = #lost, 1, -1 do
				local f = lost[i]
				if frame - f.frame > 30 * 600 then
					tremove(lost, i) -- ten minutes on: the player has moved on
				elseif not enemiesNear(f.x, f.z, 700) then
					local canBuild = false
					for _, o in ipairs(d.options) do
						canBuild = canBuild or o == f.defID
					end
					if canBuild then
						local fd = defs[f.defID]
						local x, z = f.x, f.z
						local bx, by, bz = Spring.Pos2BuildPos(f.defID, x, spGetGroundHeight(x, z), z, f.facing)
						if Spring.TestBuildOrder(f.defID, bx, by, bz, f.facing) == 0 then
							x, z = findBuildSpot(other, f.defID, x, z, { gap = 32, rings = 6, facing = f.facing })
						else
							x, z = bx, bz
						end
						if x and issueBuild(sub, unitID, f.defID, x, z, f.facing, "rebuilding " .. other.name .. "'s " .. fd.human) then
							getState(unitID).rebuildFor = other.id
							tremove(lost, i)
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- raiders in the economy's zone: cheap turrets next to what they go for (extractors, generators),
-- a few per zone, one at a time
function Jobs.guardTurret(sub, unitID, d, ux, uz)
	if d.commander or #sub.threats == 0 or sub.guardTurretFrame and frame - sub.guardTurretFrame < 30 * 40 then
		return false
	end
	local options = buildableBy(d, function(od)
		return od.staticDef and not od.aaOnly
	end)
	if #options == 0 then
		return false
	end
	tsort(options, function(a, b)
		return defs[a].cost < defs[b].cost
	end)
	local o = options[1]
	if not canSpend(sub, defs[o], "essential") or not Engine.turretBudget(defs[o].cost) then
		return false
	end
	local t = sub.threats[1]
	local turrets = 0
	for u in pairs(sub.units) do
		local ud = unitDef(u)
		if ud and ud.staticDef and not ud.aaOnly then
			turrets = turrets + 1
		end
	end
	if turrets >= 2 + POSTURE_INFO[sub.posture].density then
		return false
	end
	-- our structure nearest to the intruders
	local best, bestD
	for u in pairs(sub.units) do
		local ud = unitDef(u)
		if ud and not ud.mobile and not ud.staticDef then
			local x, _, z = spGetUnitPosition(u)
			local dd = x and dist2(x, z, t.x, t.z)
			if dd and (not bestD or dd < bestD) then
				best, bestD = { x, z }, dd
			end
		end
	end
	if not best then
		return false
	end
	local x, z = findBuildSpot(sub, o, best[1], best[2], { gap = 16, rings = 5, underFire = true })
	if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, t.x, t.z), "turret: raiders in the economy") then
		sub.guardTurretFrame = frame
		return true
	end
	return false
end

-- metal piling up: construction turrets next to a busy factory turn it into units faster
-- construction turrets: how many we have, and how many our income wants (doctrine.economy)
function Engine.nanoTarget()
	local E = Engine.D.economy
	return floor(max(0, econ.mInc - E.nanoFrom) * E.nanoRate / 10)
end

function Engine.nanoCount()
	local n = 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.nano then
			n = n + 1
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].nano then
			n = n + 1
		end
	end
	return n
end

-- every lab has its share of construction turrets around it: only then does another lab pay off
function Engine.labsSaturated()
	local per = Engine.D.economy.nanosPerLab
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local fd = unitDef(u)
		if fd and fd.factory and not spGetUnitIsBeingBuilt(u) then
			local fx, _, fz = spGetUnitPosition(u)
			local n = 0
			for _, v in ipairs(spGetUnitsInCylinder(fx, fz, 450)) do
				local nd = unitDef(v)
				if nd and nd.nano and spGetUnitTeam(v) == myTeam then
					n = n + 1
				end
			end
			if n < per then
				return false
			end
		end
	end
	return true
end

-- construction turrets next to our labs: the cheap way to more production (one per ~8 metal/s of income,
-- up to doctrine.economy.nanosPerLab each), and when metal piles up
function Jobs.buildPower(sub, unitID, d, ux, uz)
	local growth = Engine.nanoCount() < Engine.nanoTarget() and econ.eFrac > 0.25
	if not growth and (econ.mFrac < 0.6 or econ.eFrac < 0.4) then
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
	local limit = Engine.D.economy.nanosPerLab
	-- metal overflowing: more construction turrets per lab (doctrine.economy.overflowSpend)
	local OS = Engine.D.economy.overflowSpend
	if OS and econ.mFrac > OS.at then
		limit = limit * OS.nanoMul
	end
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
		return issueBuild(sub, unitID, o, x, z, 0, growth and "construction turret (income allows more production)" or "construction turret (metal piling up)")
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

local function pickDefense(sub, d, aa, role)
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
		return od.staticDef and (od.aaOnly == aa) and od.cost <= cap and (not role or Engine.prod.turretRole(od) == role)
	end)
	if #options == 0 then
		return nil
	end
	-- the decision model's current pick for this sub-commander's line (refreshed in the background)
	local tp = sub.turretPick
	if not aa and tp and frame - tp.frame < 30 * 90 and random() < 0.75 then
		for _, o in ipairs(options) do
			if o == tp.defID then
				return o
			end
		end
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
	-- light autonomy: turrets only where threats showed up in the last two minutes
	if #sub.threats > 0 then
		sub.lastThreatFrame = frame
	end
	if (sub.autonomy or "balanced") == "light" and frame - (sub.lastThreatFrame or -99999) > 30 * 120 then
		return false
	end
	-- the area's turret mix (doctrine.turrets.mix): light against raiders, heavy against assaults,
	-- long-range against their artillery; build the role furthest below its share
	local have = {}
	for _, role in ipairs({ "light", "heavy", "long" }) do
		have[role] = countStatics(sub, zone, function(od)
			return Engine.prod.turretRole(od) == role
		end)
	end
	local cap = costCap(sub)
	local available = {}
	for _, o in ipairs(d.options) do
		local od = defs[o]
		local role = od and od.cost <= cap and Engine.prod.turretRole(od)
		if role then
			available[role] = true
		end
	end
	local role = Engine.prod.turretNeed(have, POSTURE_INFO[sub.posture].density, frame, available, max(econ.mInc, 0))
	if not role then
		return false
	end
	local o = pickDefense(sub, d, false, not sub.focus and role or nil)
	if not o or not canSpend(sub, defs[o]) or not Engine.turretBudget(defs[o].cost) then
		return false
	end
	local cx, cz = Zone.center(zone)
	local ex, ez = enemyDirectionRef(cx, cz)
	local fx, fz = Zone.edgeToward(zone, ex, ez, 160)
	-- a firebase holds this front (doctrine.firebase.replaceFront): its turrets instead of a second line
	-- (v2 added firebases on top of the line: extractors at 20 min -5.6, army at 12 min -0.56k, g64)
	local FC = Engine.D.firebase
	if FC.on and FC.replaceFront then
		for _, b in ipairs(Engine.firebases) do
			if dist2(fx, fz, b.x, b.z) <= FC.replaceFront * FC.replaceFront then
				return false
			end
		end
	end
	-- long-range turrets stand back, behind the front line, where they still reach past it
	local longRange = Engine.prod.turretRole(defs[o]) == "long"
	if longRange then
		fx, fz = (fx + cx) * 0.5, (fz + cz) * 0.5
	end
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
			return longRange and -abs(sqrt(dist2(x, z, fx, fz))) or -sqrt(dist2(x, z, ex, ez))
		end,
	})
	return x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, ex, ez), (Engine.prod.turretRole(defs[o]) or "") .. " defense toward the enemy") or false
end

-- forward firebases (doctrine.firebase, sc_firebase.lua): layered turret groups just past our frontier
-- toward the enemy; complete ones let the next go further out. Engine.firebases: { x, z, n, started }
Engine.firebases = {}

-- what stands (or is planned) in a firebase, by role: light / heavy / long turrets, aa, radar
function Engine.firebaseHave(b)
	local R = Engine.D.firebase.radius
	local have, any = {}, 0
	local function add(od)
		local role = od.staticDef and not od.aaOnly and Engine.prod.turretRole(od)
			or (od.aaOnly and not od.mobile and od.armed and "aa")
			or (not od.mobile and not od.armed and od.radar > 0 and "radar")
		if role then
			have[role] = (have[role] or 0) + 1
			any = any + 1
		end
	end
	for _, u in ipairs(spGetUnitsInCylinder(b.x, b.z, R)) do
		local ud = spGetUnitTeam(u) == myTeam and unitDef(u)
		if ud and not ud.mobile then
			add(ud)
		end
	end
	for _, p in pairs(planned) do
		if dist2(p.x, p.z, b.x, b.z) <= R * R then
			add(defs[p.defID])
		end
	end
	return have, any
end

-- per-feature ledger (each piece judged on its own, not only by the game's result): metal spent on
-- each feature's structures, metal raised by resurrection; kills and losses are tagged by the harness
-- through WG.SubCommanders.featureOf
Engine.features = {}

-- which feature a unit of ours belongs to: firebase (a structure in one), lrpc, nuke, antinuke, shield,
-- juno, raised (resurrected), or nil
function Engine.featureOf(unitID)
	local d = unitDef(unitID)
	if not d then
		return nil
	end
	local st = ustate[unitID]
	if st and st.raised then
		return "raised"
	end
	if d.lrpc then
		return "lrpc"
	elseif d.nukeSilo then
		return "nuke"
	elseif d.antinuke then
		return "antinuke"
	elseif d.shieldGen then
		return "shield"
	elseif d.junoSilo then
		return "juno"
	elseif d.rezBot then
		return "rezbot"
	end
	if not d.mobile and Engine.D.firebase.on then
		local x, _, z = spGetUnitPosition(unitID)
		local R = Engine.D.firebase.radius
		for _, b in ipairs(Engine.firebases) do
			if x and dist2(x, z, b.x, b.z) <= R * R then
				return "firebase"
			end
		end
	end
	return nil
end

-- which of our features an enemy unit's death goes to (widgets aren't told the killer): a long-range
-- cannon's current target; inside a nuke's or a Juno's blast within 20 s of the shot (Juno: their
-- intel structures and mines only); in weapon range of a turret of a firebase. nil otherwise
function Engine.killCredit(unitID, defID, x, z)
	for _, u in ipairs(Engine.ourStrategic().lrpc) do
		local st = ustate[u]
		if st and st.lrpcTarget == unitID then
			return "lrpc"
		end
	end
	-- within secs of the order (a nuke flies for a while: 60 s)
	local function blast(b, secs)
		return b and frame - b.frame <= 30 * (secs or 20) and dist2(x, z, b.x, b.z) <= b.r * b.r
	end
	if blast(Engine.lastNukeAt, 60) then
		return "nuke"
	end
	local ed = defs[defID]
	if ed and blast(Engine.lastJunoAt) and ((ed.jammer or 0) > 0 or ed.intelStructure or ed.mine or ed.kind == "radar" or ed.kind == "camera") then
		return "juno"
	end
	if Engine.D.firebase.on then
		local R = Engine.D.firebase.radius
		for _, b in ipairs(Engine.firebases) do
			if dist2(x, z, b.x, b.z) <= (R + 1300) ^ 2 then
				for _, u in ipairs(spGetUnitsInCylinder(b.x, b.z, R)) do
					local ud = spGetUnitTeam(u) == myTeam and unitDef(u)
					if ud and ud.staticDef and not ud.mobile then
						local ux, _, uz = spGetUnitPosition(u)
						if ux and dist2(x, z, ux, uz) <= (ud.range + 32) ^ 2 then
							return "firebase"
						end
					end
				end
			end
		end
	end
	return nil
end

function Engine.featureSpend(unitID, d)
	local f = Engine.featureOf(unitID)
	if f and f ~= "raised" then
		local F = Engine.features[f] or { spent = 0, count = 0 }
		F.spent, F.count = F.spent + d.cost, F.count + 1
		Engine.features[f] = F
	end
end

-- free metal spots (no extractor of anyone's, not planned) within r of (x, z)
function Engine.freeSpotsNear(x, z, r)
	local n = 0
	for _, s in ipairs(metalSpots()) do
		if dist2(x, z, s.x, s.z) <= r * r then
			local taken = false
			for _, u in ipairs(spGetUnitsInCylinder(s.x, s.z, 40)) do
				local ud = unitDef(u)
				taken = taken or (ud and ud.mex and ud.mex > 0)
			end
			for _, p in pairs(planned) do
				taken = taken or (defs[p.defID].mex > 0 and dist2(p.x, p.z, s.x, s.z) < 48 * 48)
			end
			if not taken then
				n = n + 1
			end
		end
	end
	return n
end

-- is (x, z) under the guns of a firebase with two turrets standing (doctrine.firebase.expandRadius)
function Engine.firebaseCovers(x, z)
	local C = Engine.D.firebase
	if not C.on or not C.expandRadius then
		return false
	end
	for _, b in ipairs(Engine.firebases) do
		if dist2(x, z, b.x, b.z) <= C.expandRadius * C.expandRadius then
			local have = Engine.firebaseHave(b)
			if (have.light or 0) + (have.heavy or 0) + (have.long or 0) >= 2 then
				return true
			end
		end
	end
	return false
end

function Jobs.firebase(sub, unitID, d, ux, uz)
	local C = Engine.D.firebase
	if not C.on or Engine.minute() < C.minute or not Engine.homeX or not Engine.enemyX or d.commander then
		return false
	end
	local FB, bases = Engine.fb, Engine.firebases
	-- a firebase with nothing left (overrun, or never started) for two minutes is given up
	for i = #bases, 1, -1 do
		local b = bases[i]
		local _, any = Engine.firebaseHave(b)
		if any > 0 then
			b.seen = frame
		elseif frame - (b.seen or b.started) > 30 * 120 then
			log(sub, sformat("firebase %d at %d,%d is gone", b.n, b.x, b.z))
			tremove(bases, i)
		end
	end
	local air, minute, income = Enemy.share("air"), Engine.minute(), max(econ.mInc, 0)
	-- the army covers a place when its squad is within doctrine.firebase.cover of it or further forward
	-- (constructors building ahead of the army died: 14.7 lost a game against 10.6, g62)
	local army = Engine.anyArmy()
	local sq = army and army.squad
	local hx, hz, ex0, ez0 = Engine.homeX, Engine.homeZ, Engine.enemyX, Engine.enemyZ
	local function covered(x, z)
		if not C.cover then
			return true
		end
		if Engine.inBase(x, z) then
			return true
		end
		-- v6: our combat units right there, not a squad somewhere further forward
		if C.coverValue then
			local v = 0
			for _, u in ipairs(spGetUnitsInCylinder(x, z, C.coverRadius or 900)) do
				local ud = spGetUnitTeam(u) == myTeam and unitDef(u)
				if ud and ud.mobile and ud.armed and not ud.builder and not ud.commander and not ud.air then
					v = v + ud.cost
				end
			end
			return v >= C.coverValue
		end
		if not (sq and sq.x) then
			return false
		end
		local ax, az = ex0 - hx, ez0 - hz
		return dist2(x, z, sq.x, sq.z) <= C.cover * C.cover or (sq.x - hx) * ax + (sq.z - hz) * az >= (x - hx) * ax + (z - hz) * az
	end
	-- the nearest unfinished one that isn't under fire; else found the next
	local todo, role, bestD
	for _, b in ipairs(bases) do
		local r = FB.nextLayer((Engine.firebaseHave(b)), air, minute, income)
		local dd = dist2(ux, uz, b.x, b.z)
		if r and Engine.tm.threat(b.x, b.z) <= 0 and covered(b.x, b.z) and (not bestD or dd < bestD) then
			todo, role, bestD = b, r, dd
		end
	end
	if not todo then
		-- v5: `max` firebases unfinished at once, `maxTotal` standing (v1-v4 capped standing ones at 3, so
		-- three complete ones froze the line for the rest of the game: the LLM review of g62 saw the creep
		-- stall after 1-3 sites in 6 of 6 games); and the army keeps up: none while our turrets outweigh it
		local unfinished = 0
		for _, b in ipairs(bases) do
			if not FB.established((Engine.firebaseHave(b)), air, minute, income) then
				unfinished = unfinished + 1
			end
		end
		if unfinished >= C.max or #bases >= (C.maxTotal or C.max) or (C.cover and Engine.team.plan.phase == "defend") then
			return false
		end
		if C.armyRatio and (Engine.armyValue or 0) < (Engine.turretValue or 0) * C.armyRatio then
			return false
		end
		-- v7: how we stand against their strongest known group: outmatched, no new firebase; the creep's
		-- reach grows with our edge (v6 over-extended against hard: 7 games lost by minute 25, v4 2)
		local strength = (Engine.armyValue or 0) / max(Engine.enemyArmy or 0, 1)
		if C.foundStrength and (Engine.enemyArmy or 0) > 0 and strength < C.foundStrength then
			return false
		end
		local A = Engine.approach
		local pickets = Engine.terr.pickets(5, { Engine.homeX, Engine.homeZ }, { Engine.enemyX, Engine.enemyZ }, A and A.sectors)
		local reach
		if C.strengthFull and (Engine.enemyArmy or 0) > 0 then
			reach = C.reach * min(1, max(C.reachMin or 0.5, strength / C.strengthFull))
		end
		local site = FB.site(pickets, { x = Engine.homeX, z = Engine.homeZ }, { x = Engine.enemyX, z = Engine.enemyZ }, bases, function(x, z)
			return covered(x, z) and Engine.tm.threat(x, z) or 1
		end, C.metalWeight and function(x, z)
			return Engine.freeSpotsNear(x, z, C.metalRadius or 600)
		end, reach)
		if not site then
			return false
		end
		Engine.firebaseCount = (Engine.firebaseCount or 0) + 1
		todo = { x = site.x, z = site.z, n = Engine.firebaseCount, started = frame }
		bases[#bases + 1] = todo
		role = FB.nextLayer({}, air, minute, income)
		log(sub, sformat("founding firebase %d at %d,%d (%d standing)", todo.n, todo.x, todo.z, #bases))
	end
	-- what to build for the role
	local o
	if role == "radar" then
		local opts = buildableBy(d, function(od)
			return not od.mobile and not od.armed and od.radar > 0 and od.jammer == 0
		end)
		tsort(opts, function(a, b)
			return defs[a].cost < defs[b].cost
		end)
		o = opts[1]
	else
		o = pickDefense(sub, d, role == "aa", role ~= "aa" and role or nil)
	end
	if not o or not canSpend(sub, defs[o], (role == "light" or role == "radar") and "essential" or nil) then
		return false
	end
	if role ~= "aa" and role ~= "radar" and not Engine.turretBudget(defs[o].cost, C.budget) then
		return false
	end
	local ex, ez = enemyDirectionRef(todo.x, todo.z)
	local dx, dz = ex - todo.x, ez - todo.z
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local off, side = FB.offset(role), (random() - 0.5) * 2 * 120
	local ax, az = clampToMap(todo.x + dx / len * off - dz / len * side, todo.z + dz / len * off + dx / len * side)
	local x, z = findBuildSpot(sub, o, ax, az, { gap = 32, rings = 6, anywhere = true })
	return x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, ex, ez), sformat("firebase %d: %s", todo.n, role)) or false
end

function Engine.haveFactoryNamed(pattern)
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.factory and (ud.name or ""):find(pattern) then
			return true
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory and (defs[p.defID].name or ""):find(pattern) then
			return true
		end
	end
	return false
end

-- the Air Force's aircraft plant: one of its own (any tier its constructor makes), and a tier 2 one once
-- it has a tier 2 constructor and the income (doctrine.air.t2Income). Behind home, away from the enemy.
function Jobs.airPlant(sub, unitID, d, ux, uz)
	if not Engine.homeX or d.commander then
		return false
	end
	local have, haveT2 = 0, false
	for u in pairs(sub.units) do
		local ud = unitDef(u)
		if ud and ud.factory and makesAircraft(ud) then
			have, haveT2 = have + 1, haveT2 or (ud.tech or 1) >= 2
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory then
			return false -- one factory at a time
		end
	end
	local wantTier = (have == 0 and 1) or ((not haveT2 and max(econ.mInc, 0) >= Engine.D.air.t2Income) and 2) or nil
	if not wantTier then
		return false
	end
	-- the plant that makes the most kinds of planes (a drone plant makes one), the higher tier on a tie
	local o, oScore
	for _, opt in ipairs(d.options) do
		local od = defs[opt]
		if od and od.factory and makesAircraft(od) and (od.tech or 1) >= wantTier and not (od.name or ""):find("sy$") then
			local opts = {}
			for _, b in ipairs(od.options or {}) do
				opts[#opts + 1] = defs[b]
			end
			local _, n = Engine.air.classes(opts)
			local score = n * 10 + (od.tech or 1)
			if not oScore or score > oScore then
				o, oScore = opt, score
			end
		end
	end
	if not o or not canSpend(sub, defs[o]) or econ.m < defs[o].cost * 0.25 then
		return false
	end
	local dx, dz = (Engine.enemyX or MAP_X / 2) - Engine.homeX, (Engine.enemyZ or MAP_Z / 2) - Engine.homeZ
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local ax, az = clampToMap(Engine.homeX - dx / len * 500, Engine.homeZ - dz / len * 500)
	local x, z = findBuildSpot(sub, o, ax, az, { gap = 48, rings = 12, anywhere = true })
	if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2), wantTier >= 2 and "tier 2 aircraft plant" or "our aircraft plant") then
		getState(unitID).rebuildFor, getState(unitID).newFactory = sub.id, true
		return true
	end
	return false
end

function Engine.subOfRole(role)
	for _, s in ipairs(subs) do
		if s.role == role and not s.paused then
			return s
		end
	end
end

function Engine.haveAirPlant()
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.factory and makesAircraft(ud) then
			return true
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory and makesAircraft(defs[p.defID]) then
			return true
		end
	end
	return false
end

-- recon from the start: a radar toward the enemy near home from about minute 1.5 (the Intelligence
-- sub-commander arrives later; strong players have radar up early)
function Jobs.earlyRadar(sub, unitID, d, ux, uz)
	if frame < Engine.D.economy.radarFrom or not Engine.homeX or frame - (sub.radarTried or -99999) < 30 * 30 then
		return false
	end
	if Engine.radarNearHome() then
		return false
	end
	local options = buildableBy(d, function(od)
		return od.radar > 0
	end)
	if #options == 0 or not canSpend(sub, defs[options[1]], "essential") then
		return false
	end
	sub.radarTried = frame
	local dx, dz = (Engine.enemyX or MAP_X / 2) - Engine.homeX, (Engine.enemyZ or MAP_Z / 2) - Engine.homeZ
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local x, z = findBuildSpot(sub, options[1], Engine.homeX + dx / len * 500, Engine.homeZ + dz / len * 500, { gap = 24, rings = 8 })
	return x and issueBuild(sub, unitID, options[1], x, z, 0, "radar: see raids coming") or false
end

-- one of our radars covers home (or one is planned)?
function Engine.radarNearHome()
	for _, u in ipairs(spGetUnitsInCylinder(Engine.homeX, Engine.homeZ, 1600)) do
		local ud = unitDef(u)
		if ud and ud.radar > 0 and spGetUnitTeam(u) == myTeam then
			return true
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].radar > 0 and dist2(p.x, p.z, Engine.homeX, Engine.homeZ) < 1600 * 1600 then
			return true
		end
	end
	return false
end

-- an extractor going up with no turret near it: the same constructor queues a cheap light turret next to
-- it (from about minute 2, within the turret budget). Undefended extractors die to the first raid, also
-- at the back of the base (corner-first expansion lost its extractors to early raids).
function Jobs.escortTurret(sub, unitID, d, x, z)
	if sub.role ~= "economy" or d.commander or frame < 30 * 120 then
		return false
	end
	local r = Engine.D.turrets.extractorCoverRadius
	for _, u in ipairs(spGetUnitsInCylinder(x, z, r)) do
		local ud = unitDef(u)
		if ud and ud.staticDef and not ud.aaOnly and spGetUnitTeam(u) == myTeam then
			return false
		end
	end
	Engine.queuedTurrets = Engine.queuedTurrets or {}
	for i = #Engine.queuedTurrets, 1, -1 do
		local q = Engine.queuedTurrets[i]
		if frame - q.frame > 30 * 90 then
			tremove(Engine.queuedTurrets, i)
		elseif dist2(q.x, q.z, x, z) < r * r then
			return false
		end
	end
	local options = buildableBy(d, function(od)
		return od.staticDef and not od.aaOnly
	end)
	if #options == 0 then
		return false
	end
	tsort(options, function(a, b)
		return defs[a].cost < defs[b].cost
	end)
	local o = options[1]
	if not Engine.turretBudget(defs[o].cost) then
		return false
	end
	-- on the extractor's side toward the enemy
	local ex, ez = enemyDirectionRef(x, z)
	local dx, dz = ex - x, ez - z
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local tx, tz = findBuildSpot(sub, o, x + dx / len * 110, z + dz / len * 110, { gap = 16, rings = 4, underFire = true, anywhere = true })
	if not tx then
		return false
	end
	order(unitID, -o, { tx, spGetGroundHeight(tx, tz), tz, facingToward(tx, tz, ex, ez) }, { "shift" })
	tinsert(Engine.queuedTurrets, { x = x, z = z, frame = frame })
	log(sub, sformat("%s with the new extractor", defs[o].human))
	return true
end

-- tier 2 (doctrine.economy.t2*): the T2 ground lab once income allows (full autonomy; balanced when metal
-- piles up). It stays with the economy for its T2 constructors, then goes to the Army.
function Jobs.techLab(sub, unitID, d)
	local E = Engine.D.economy
	if d.commander or (Engine.factoryCount or 0) < 1 or Engine.haveTechLab() then
		return false
	end
	local income = max(econ.mInc, 0)
	local due = income >= E.t2Income or (frame >= 30 * 60 * E.t2Minute and income >= E.t2MinIncome)
	-- balanced waits for overflowing metal unless the team plan is tier 2
	if not due or (Engine.auto(sub).factories == "overflow" and econ.mFrac < 0.7 and Engine.team.plan.phase ~= "tech") then
		return false
	end
	local o
	for _, opt in ipairs(d.options) do
		local od = defs[opt]
		if od and od.factory and (od.tech or 1) >= 2 and not makesAircraft(od) and not (od.name or ""):find("hp$") and not (od.name or ""):find("sy$") then
			if not o or (od.name or ""):find("alab$") then
				o = opt
			end
		end
	end
	if not o or econ.m < 300 then
		return false
	end
	local dx, dz = (Engine.enemyX or MAP_X / 2) - Engine.homeX, (Engine.enemyZ or MAP_Z / 2) - Engine.homeZ
	local len = max(sqrt(dx * dx + dz * dz), 1)
	-- deep behind home: a 2600-metal frame near the front died before it finished
	local ax, az = clampToMap(Engine.homeX - dx / len * 700, Engine.homeZ - dz / len * 700)
	local x, z = findBuildSpot(sub, o, ax, az, { gap = 48, rings = 14, anywhere = true })
	if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2), "tier 2 lab: T2 constructors, then T2 units") then
		getState(unitID).rebuildFor, getState(unitID).newFactory = sub.id, true
		return true
	end
	return false
end

-- a tier 2 ground lab (aircraft plants don't count: the Air Force's T2 plant isn't the T2 lab)
function Engine.groundFactory(d)
	return d.factory and not makesAircraft(d) and not (d.name or ""):find("hp$") and not (d.name or ""):find("sy$")
end

function Engine.haveTechLab()
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.factory and (ud.tech or 1) >= 2 and Engine.groundFactory(ud) then
			return true
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory and (defs[p.defID].tech or 1) >= 2 then
			return true
		end
	end
	-- the player's own queued builds count too (a player-ordered T2 lab and ours were both built)
	for _, p in ipairs(Player.plans or {}) do
		local pd = defs[p.defID]
		if pd and pd.factory and (pd.tech or 1) >= 2 and Engine.groundFactory(pd) then
			return true
		end
	end
	return false
end

-- a tier 2 vehicle plant for the Army once the economy is big (doctrine.escalation.t2VehicleIncome) and
-- the T2 lab stands: heavy tanks, flak and artillery next to the T2 bots
function Jobs.techVehicles(sub, unitID, d)
	if d.commander or max(econ.mInc, 0) < Engine.D.escalation.t2VehicleIncome or Engine.haveFactoryNamed("avp$") then
		return false
	end
	local t2lab = false
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.factory and (ud.tech or 1) >= 2 and Engine.groundFactory(ud) and not spGetUnitIsBeingBuilt(u) then
			t2lab = true
		end
	end
	if not t2lab then
		return false
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory then
			return false
		end
	end
	local o
	for _, opt in ipairs(d.options) do
		if (defs[opt].name or ""):find("avp$") then
			o = opt
		end
	end
	-- not canSpend: its posture cap (1120 at 50 metal/s) is under the plant's 2600, so it was never built
	-- below 132 metal/s and the Cortex overlay's Tzars never came (g50: 0 in 24 games). Like the T2 lab
	if not o or econ.m < defs[o].cost * 0.25 then
		return false
	end
	local dx, dz = (Engine.enemyX or MAP_X / 2) - Engine.homeX, (Engine.enemyZ or MAP_Z / 2) - Engine.homeZ
	local len = max(sqrt(dx * dx + dz * dz), 1)
	-- behind home like the T2 lab, off to one side of it
	local ax, az = clampToMap(Engine.homeX - dx / len * 600 - dz / len * 500, Engine.homeZ - dz / len * 600 + dx / len * 500)
	local x, z = findBuildSpot(sub, o, ax, az, { gap = 48, rings = 14, anywhere = true })
	if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2), "tier 2 vehicle plant for the Army") then
		local army = Engine.anyArmy()
		getState(unitID).rebuildFor, getState(unitID).newFactory = (army or sub).id, true
		return true
	end
	return false
end

-- full autonomy: factories as income grows (strong players run one lab until about 25 metal/s, then add
-- about one per 22); the first one if there's none. A new lab goes to an Army without one.
function Jobs.newFactory(sub, unitID, d, ux, uz)
	if not Engine.auto(sub).factories or not Engine.homeX then
		return false
	end
	if Jobs.techLab(sub, unitID, d) or Jobs.techVehicles(sub, unitID, d) then
		return true
	end
	local E = Engine.D.economy
	local have = Engine.factoryCount or 0
	if d.commander and (have > 0 or frame < 30 * 40) then
		return false
	end
	local income = max(econ.mInc, 0)
	local want = 1
	if Engine.auto(sub).factories == "overflow" then
		-- balanced: only when metal piles up (and never the first: that's the player's)
		want = (econ.mFrac > 0.85 and have > 0) and have + 1 or have
		if E.secondLabIncome and have == 1 and income >= E.secondLabIncome then
			want = 2
		end
	else
		if income >= E.secondFactoryIncome then
			want = 2 + floor((income - E.secondFactoryIncome) / E.factoryPerIncome)
		end
		if econ.mFrac > 0.85 and have > 0 then
			want = want + 1
		end
	end
	-- metal overflowing (doctrine.economy.overflowSpend): labs beyond the cap to spend it
	local OS = E.overflowSpend
	local cap = E.maxFactories + ((OS and econ.mFrac > OS.at) and OS.extraFactories or 0)
	if have >= min(want, cap) then
		return false
	end
	-- construction turrets first: another lab only once every lab has its turrets, as long as energy can
	-- pay for turrets (3200 energy each); short of energy, a lab is the way to spend piling metal (engine-v4)
	local earlySecond = E.secondLabIncome and have == 1 and income >= E.secondLabIncome
	if have > 0 and not earlySecond and not Engine.labsSaturated() and econ.eFrac > 0.3 and econ.eInc > 300 then
		return false
	end
	for _, p in pairs(planned) do
		if defs[p.defID].factory then
			return false
		end
	end
	-- which kind: the first a bot lab; the second a vehicle plant (different units in parallel: strong
	-- players field about half vehicles); past doctrine.economy.airPlantIncome an aircraft plant
	-- (Intelligence: scout planes, then gunships); after that more of what we have
	local o
	-- with a big economy a second one for the Army: air raids (doctrine.escalation)
	-- (an Air Force sub-commander builds its own)
	local airForce = Engine.subOfRole("air")
	local armyAir = not airForce and have > 0 and income >= Engine.D.escalation.airRaidIncome and Engine.haveAirPlant() and not Engine.armyHasAirPlant()
	local wantAir = not airForce and ((have > 0 and income >= E.airPlantIncome and not Engine.haveAirPlant()) or armyAir)
	local wantVehicles = have > 0 and not wantAir and not Engine.haveFactoryNamed("vp$")
	local function rank(opt)
		local name = UnitDefs[opt].name or ""
		if wantAir then
			return makesAircraft(defs[opt]) and 3 or 0
		end
		if makesAircraft(defs[opt]) or name:find("hp$") or name:find("sy$") then
			return 0 -- no hovers or shipyards from this rule
		end
		if wantVehicles and name:find("vp$") then
			return 3
		end
		if opt == Engine.labDef then
			return 2
		end
		return name:find("lab$") and 1 or 0.5
	end
	local best = 0
	for _, opt in ipairs(d.options) do
		local od = defs[opt]
		if od and od.factory and rank(opt) > best then
			o, best = opt, rank(opt)
		end
	end
	if not o or (have > 0 and not canSpend(sub, defs[o], earlySecond and "essential" or nil)) or econ.m < defs[o].cost * 0.25 then
		return false
	end
	-- behind home, away from the enemy
	local dx, dz = (Engine.enemyX or MAP_X / 2) - Engine.homeX, (Engine.enemyZ or MAP_Z / 2) - Engine.homeZ
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local ax, az = clampToMap(Engine.homeX - dx / len * 250, Engine.homeZ - dz / len * 250)
	local x, z = findBuildSpot(sub, o, ax, az, { gap = 48, rings = 10 })
	if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2), have == 0 and "our first factory" or "another factory: income allows it") then
		local owner_ = Engine.armyToFeed() or sub
		-- a second kind of factory builds the army's units in parallel: it goes to the Army
		for _, s in ipairs(subs) do
			if s.role == "army" and not s.paused and owner_ == sub then
				owner_ = s
			end
		end
		if wantAir and not armyAir then
			for _, s in ipairs(subs) do
				if s.role == "intelligence" then
					owner_ = s
				end
			end
		end
		getState(unitID).rebuildFor, getState(unitID).newFactory = owner_.id, true
		return true
	end
	return false
end

-- a cheap turret at each exposed extractor cluster (ours, away from home toward the enemy) that has none:
-- strong players have one up by minute 3 and five by minute 6; raids go for extractors first
function Jobs.extractorCover(sub, unitID, d, ux, uz)
	local T = Engine.D.turrets
	if frame < T.extractorCoverFrom or not Engine.auto(sub).extractorCover or not Engine.homeX then
		return false
	end
	local options = buildableBy(d, function(od)
		return od.staticDef and not od.aaOnly
	end)
	if #options == 0 then
		return false
	end
	tsort(options, function(a, b)
		return defs[a].cost < defs[b].cost
	end)
	local o = options[1]
	if not canSpend(sub, defs[o], "essential") or not Engine.turretBudget(defs[o].cost) then
		return false
	end
	-- metal spots raided lately first (doctrine.turrets.harden): two turrets, the second a heavier one (one
	-- cheap turret per cluster died to Blitz packs; against hard we lost ~42 extractors a game in minutes 10-25)
	local H = T.harden
	if H then
		for _, rs in ipairs(Engine.raided) do
			if frame - rs.frame < 30 * H.memory then
				local n = Engine.turretsNear(rs.x, rs.z, T.extractorCoverRadius)
				if n < H.turrets and Engine.tm.threat(rs.x, rs.z) <= Engine.tm.influence(rs.x, rs.z) then
					local ho = n >= 1 and pickDefense(sub, d, false, "heavy") or o
					if ho and canSpend(sub, defs[ho], "essential") and Engine.turretBudget(defs[ho].cost, Engine.D.firebase.budget) then
						local ex, ez = enemyDirectionRef(rs.x, rs.z)
						local dx, dz = ex - rs.x, ez - rs.z
						local len = max(sqrt(dx * dx + dz * dz), 1)
						local x, z = findBuildSpot(sub, ho, rs.x + dx / len * 100, rs.z + dz / len * 100, { gap = 16, rings = 5, underFire = true, anywhere = true })
						if x and issueBuild(sub, unitID, ho, x, z, facingToward(x, z, ex, ez), "hardening a raided metal spot") then
							return true
						end
					end
				end
			end
		end
	end
	-- our factories first (raiders go for them), then the exposed extractor clusters
	local exposed = {}
	for _, v in ipairs(Engine.vitals or {}) do
		if v.factory then
			exposed[#exposed + 1] = v
		end
	end
	for _, m in ipairs(Engine.zones.exposed({ Engine.homeX, Engine.homeZ }, { Engine.enemyX, Engine.enemyZ }, Engine.extractors, 3)) do
		exposed[#exposed + 1] = m
	end
	-- and every other cluster of our extractors, the rear ones too (raids go around)
	for _, m in ipairs(Engine.zones.clusters(Engine.extractors, 500, 2)) do
		exposed[#exposed + 1] = m
	end
	-- and our generator clusters (wind farms: cheap, many, what raids hit most)
	for i, f in ipairs(Engine.farms or {}) do
		if i <= 2 then
			exposed[#exposed + 1] = f
		end
	end
	local r = T.extractorCoverRadius
	for _, m in ipairs(exposed) do
		local covered = false
		for _, u in ipairs(spGetUnitsInCylinder(m.x, m.z, r)) do
			local ud = unitDef(u)
			covered = covered or (ud and ud.staticDef and not ud.aaOnly and spGetUnitTeam(u) == myTeam)
		end
		for _, p in pairs(planned) do
			covered = covered or (defs[p.defID].staticDef and dist2(p.x, p.z, m.x, m.z) < r * r)
		end
		if not covered and Engine.tm.threat(m.x, m.z) <= Engine.tm.influence(m.x, m.z) then
			local ex, ez = enemyDirectionRef(m.x, m.z)
			local dx, dz = ex - m.x, ez - m.z
			local len = max(sqrt(dx * dx + dz * dz), 1)
			local x, z = findBuildSpot(sub, o, m.x + dx / len * 120, m.z + dz / len * 120, { gap = 16, rings = 5, underFire = true })
			if not x then
				-- outside its zones: place it anyway, it's covering our extractor
				local bx, by, bz = Spring.Pos2BuildPos(o, m.x + dx / len * 120, spGetGroundHeight(m.x, m.z), m.z + dz / len * 120, 0)
				if Spring.TestBuildOrder(o, bx, by, bz, 0) > 0 and not nearMetalSpot(bx, bz, defs[o]) then
					x, z = bx, bz
				end
			end
			if x and issueBuild(sub, unitID, o, x, z, facingToward(x, z, ex, ez), m.factory and "covering a factory" or "covering an exposed extractor") then
				return true
			end
		end
	end
	return false
end

-- their aircraft in this sub-commander's areas now
function Engine.airThreatened(sub)
	for _, t in ipairs(sub.threats or {}) do
		if t.air then
			return true
		end
	end
	return false
end

-- the Air Force builds anti-air turrets once their air is a real part of what they field
-- (doctrine.air.aaTurretShare) or their aircraft come into its areas
function Engine.airDefenseNeeded(sub)
	return Engine.airThreatened(sub) or Enemy.share("air") >= (Engine.D.air.aaTurretShare or 0.1)
end

-- our allies' bases: each allied team's start position, else the centre of its factories. { team, x, z }
function Engine.allyBases()
	local out = {}
	for _, t in ipairs(Spring.GetTeamList(myAlly) or {}) do
		if t ~= myTeam then
			local x, _, z = Spring.GetTeamStartPosition(t)
			if not x or x <= 0 then
				local sx, sz, n = 0, 0, 0
				for _, u in ipairs(Spring.GetTeamUnits(t) or {}) do
					local ud = unitDef(u)
					if ud and ud.factory then
						local ux, _, uz = spGetUnitPosition(u)
						if ux then
							sx, sz, n = sx + ux, sz + uz, n + 1
						end
					end
				end
				if n > 0 then
					x, z = sx / n, sz / n
				end
			end
			if x and x > 0 then
				out[#out + 1] = { team = t, x = x, z = z }
			end
		end
	end
	return out
end

-- cover an area (the Air Force's fighters, gunships and anti-air go there): a circle zone of its own
function Engine.coverArea(sub, x, z, r)
	Engine.manualZones(sub)
	sub.zones[#sub.zones + 1] = { kind = "circle", x = x, z = z, r = r or 1300 }
	log(sub, sformat("covering the area at %d,%d", x, z))
end

-- defend an ally: cover the nearest ally's base (nearest our home)
function Engine.coverAlly(sub)
	local best, bestD
	for _, a in ipairs(Engine.allyBases()) do
		local dd = dist2(a.x, a.z, Engine.homeX or a.x, Engine.homeZ or a.z)
		if not bestD or dd < bestD then
			best, bestD = a, dd
		end
	end
	if not best then
		log(sub, "no ally to cover")
		return false
	end
	Engine.coverArea(sub, best.x, best.z, 1500)
	log(sub, sformat("defending our ally's base (team %d)", best.team))
	return true
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
		anywhere = true,
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
	-- radar behind each of the territory's pickets (a third of the way back toward home): it still sees
	-- the approach (range ~2000) without standing where raids and artillery arrive (radars on the
	-- frontier died 35 times in one game)
	for _, p in ipairs(Engine.pickets or {}) do
		local hx, hz = Engine.homeX or p.x, Engine.homeZ or p.z
		points[#points + 1] = { p.x + (hx - p.x) * 0.35, p.z + (hz - p.z) * 0.35 }
	end
	for _, zone in ipairs(sub.zones) do
		local cx, cz = Zone.center(zone)
		local ex, ez = enemyDirectionRef(cx, cz)
		local fx, fz = Zone.edgeToward(zone, ex, ez, 0)
		points[#points + 1] = { fx, fz }
		points[#points + 1] = { cx, cz }
	end
	return points
end

-- Intelligence v2: a seismic detector at home from doctrine.intel.seismicMinute (reveals cloaked units moving)
function Jobs.seismic(sub, unitID, d, ux, uz)
	local I = Engine.D.intel
	if not I or not I.seismicMinute or Engine.minute() < I.seismicMinute or not Engine.homeX then
		return false
	end
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and not ud.mobile and (ud.seismic or 0) > 0 then
			return false
		end
	end
	for _, p in pairs(planned) do
		if (defs[p.defID].seismic or 0) > 0 then
			return false
		end
	end
	return buildCheapestUseful(sub, unitID, d, Engine.homeX, Engine.homeZ, function(od)
		return not od.mobile and (od.seismic or 0) > 0
	end, function(od)
		return -od.cost
	end, "seismic detector (finds cloaked units)")
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
-- a unit that can spot for Intelligence v2: a cheap cloaking, radar-stealthy unit (the spies: Ghost,
-- Spectre, Eidolon) or a scout
function Engine.isSpotter(d)
	return d and d.mobile and not d.air and ((d.canCloak and d.stealthy and d.cost <= 400) or d.scout) or false
end

-- a sub-commander's cloaking spies (spotters that cloak)
function Engine.cloakSpies(sub)
	local n = 0
	for u in pairs(sub.units) do
		local ud = unitDef(u)
		if ud and Engine.isSpotter(ud) and ud.canCloak then
			n = n + 1
		end
	end
	return n
end

-- how many spotters Intelligence wants (doctrine.intel.spotters)
function Engine.spottersWanted()
	local I = Engine.D.intel
	if not I then
		return 0
	end
	return min(I.spotters.max, I.spotters.base + floor(max(econ.mInc, 0) / I.spotters.perIncome))
end

-- where eyes help most: our cannons', strikes' and the army's targets, their factories (nearest our base
-- first), their start when no factory of theirs is known. { x, z, why }, a point per 800 elmos
function Engine.watchPoints()
	local pts = {}
	local function add(x, z, why)
		for _, p in ipairs(pts) do
			if dist2(p.x, p.z, x, z) < 800 * 800 then
				return
			end
		end
		pts[#pts + 1] = { x = x, z = z, why = why }
	end
	for _, p in ipairs(Engine.operationPoints()) do
		add(p.x, p.z, "our target")
	end
	local facs = {}
	for _, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		if ed and ed.factory then
			facs[#facs + 1] = e
		end
	end
	local hx, hz = Engine.homeX or 0, Engine.homeZ or 0
	tsort(facs, function(a, b)
		return dist2(a.x, a.z, hx, hz) < dist2(b.x, b.z, hx, hz)
	end)
	for i = 1, min(#facs, 3) do
		add(facs[i].x, facs[i].z, "their factory")
	end
	if #facs == 0 and Engine.enemyX then
		add(Engine.enemyX, Engine.enemyZ, "their base")
	end
	return pts
end

-- a spotter's post: the watch point least watched (nearest first), held `standoff` back toward our base;
-- a spotter that can't cloak keeps out of their known reach. Returns true when it acted
function Intel.spot(sub, unitID, d, st, x, z)
	local I = Engine.D.intel
	local pts = Engine.watchPoints()
	if #pts == 0 then
		return false
	end
	if d.canCloak and not st.cloakOn then
		order(unitID, Engine.CMD_WANT_CLOAK, { 1 })
		st.cloakOn = true
	end
	local p = st.watch
	if not p or frame - (st.watchFrame or 0) > I.retarget then
		local load = {}
		for u in pairs(sub.units) do
			local o = ustate[u]
			if u ~= unitID and o and o.watch then
				load[o.watch.key] = (load[o.watch.key] or 0) + 1
			end
		end
		local best, bestScore
		for _, q in ipairs(pts) do
			q.key = floor(q.x / 400) .. ":" .. floor(q.z / 400)
			local score = (load[q.key] or 0) * 1e8 + dist2(x, z, q.x, q.z)
			if not bestScore or score < bestScore then
				best, bestScore = q, score
			end
		end
		p, st.watch, st.watchFrame = best, best, frame
	end
	local hx, hz = Engine.homeX or x, Engine.homeZ or z
	local dx, dz = hx - p.x, hz - p.z
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local px, pz = clampToMap(p.x + dx / len * I.standoff, p.z + dz / len * I.standoff)
	if not d.canCloak and Engine.tm.threat(px, pz) > 0 then
		local sx, sz = Engine.tm.safePoint(px, pz, hx, hz)
		if sx then
			px, pz = sx, sz
		end
	end
	if dist2(x, z, px, pz) > 150 * 150 and (frame - (st.spotOrder or 0) > 90 or (spGetUnitCommandCount(unitID) or 0) == 0) then
		order(unitID, CMD.MOVE, { px, spGetGroundHeight(px, pz), pz })
		st.spotOrder = frame
	end
	setTask(unitID, "spot", "watching " .. p.why, true)
	return true
end

-- counter-intelligence: their scouts, spies, cameras and unarmed units in our zones or base, seen lately
function Intel.spyTarget(sub, x, z)
	local best, bestD
	for u, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		if ed and frame - e.last < 30 * 30 and (ed.scout or ed.kind == "camera" or (ed.canCloak and ed.stealthy) or (ed.mobile and not ed.armed and not ed.air))
			and (inSubZones(sub, e.x, e.z) or Engine.inBase(e.x, e.z)) then
			local dd = dist2(x, z, e.x, e.z)
			if not bestD or dd < bestD then
				best, bestD = u, dd
			end
		end
	end
	return best
end

function Intel.huntTarget(sub, x, z)
	if Engine.D.intel then
		local spy = Intel.spyTarget(sub, x, z)
		if spy then
			return spy
		end
	end
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
	-- Intelligence v2: spotters hold watch over targets (cloakers always; scouts while spotters are short)
	if Engine.D.intel and Engine.isSpotter(d) then
		local cloaker = d.canCloak and d.stealthy
		local posted = 0
		if not cloaker then
			for u in pairs(sub.units) do
				local o = ustate[u]
				posted = posted + ((u ~= unitID and o and o.watch and frame - (o.watchFrame or 0) < 30 * 60) and 1 or 0)
			end
		end
		if (cloaker or posted < Engine.spottersWanted()) and Intel.spot(sub, unitID, d, st, x, z) then
			return
		end
		st.watch = nil
	end
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
		-- Intelligence v2: a mobile jammer follows the army (hides it), a little behind its centre
		local army = Engine.D.intel and Engine.D.intel.jammerFollow and d.jammer > 0 and Engine.anyArmy()
		local sq = army and army.squad
		if sq and sq.x then
			local ex, ez = enemyDirectionRef(sq.x, sq.z)
			local dx, dz = sq.x - ex, sq.z - ez
			local len = max(sqrt(dx * dx + dz * dz), 1)
			local jx, jz = clampToMap(sq.x + dx / len * 150, sq.z + dz / len * 150)
			if dist2(x, z, jx, jz) > 250 * 250 and (not busy or frame - (st.jamFrame or 0) > 90) then
				order(unitID, CMD.MOVE, { jx, spGetGroundHeight(jx, jz), jz })
				st.jamFrame = frame
			end
			setTask(unitID, "post", "jamming over the army", true)
			return
		end
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

-- energy behind metal (doctrine.economy.energyFirst): income under energyPerMetal x metal income, or
-- under what we spend. Building takes energy with every bit of metal: our games sat on full metal
-- storage 727 s and near-empty energy 598 s a game, at 9.4 energy per metal at minute 8
local function energyBehind()
	local E = Engine.D.economy
	return E.energyFirst and econ.eFrac < 0.9 and (econ.eInc < econ.mInc * E.energyPerMetal or econ.eInc < (econ.ePull or 0) * 1.05)
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
			or Jobs.guardTurret(sub, u, d, x, z)
			-- energy behind: generators before anything that spends it (build power, labs, radar)
			or (energyBehind() and Jobs.energy(sub, u, d, x, z, econ.eFrac < 0.3))
			-- metal piling up with energy to spare: build power first (constructors otherwise always found
			-- one more contested extractor to try, and a watched game sat on full storage at +90 metal/s)
			or (econ.mFrac > 0.7 and econ.eFrac > 0.3 and not energyBehind() and Jobs.buildPower(sub, u, d, x, z))
			or Jobs.rebuildFactory(sub, u, d, x, z)
			or Jobs.newFactory(sub, u, d, x, z)
			or Jobs.strategic(sub, u, d, x, z)
			or Jobs.earlyRadar(sub, u, d, x, z)
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
			or Jobs.strategic(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			-- intruders in its zone: a cheap turret by the structure nearest them (Defense's constructors stood
			-- "nothing to do" through raids)
			or (Engine.D.turrets.defenseGuard and Jobs.guardTurret(sub, u, d, x, z))
			or Jobs.firebase(sub, u, d, x, z)
			or Jobs.extractorCover(sub, u, d, x, z)
			or Jobs.radar(sub, u, d, x, z)
			-- enemy aircraft are a real part of what they field: anti-air on our line too
			or (Enemy.share("air") > 0.2 and Jobs.airDefense(sub, u, d, x, z))
			or Jobs.defense(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	intelligence = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.strategic(sub, u, d, x, z)
			or Jobs.radarNet(sub, u, d, x, z)
			or Jobs.cameras(sub, u, d, x, z)
			or Jobs.sonar(sub, u, d, x, z)
			or Jobs.jammer(sub, u, d, x, z)
			or Jobs.seismic(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	-- the Air Force: anti-air turrets first while their aircraft are in its areas, its air plant (tier 2
	-- later), anti-air turrets once they field aircraft, then radar for its planes to see by
	air = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			or Jobs.repair(sub, u, d, x, z)
			or (Engine.airThreatened(sub) and Jobs.airDefense(sub, u, d, x, z))
			or Jobs.airPlant(sub, u, d, x, z)
			or (Engine.airDefenseNeeded(sub) and Jobs.airDefense(sub, u, d, x, z))
			or Jobs.radarNet(sub, u, d, x, z)
			or Jobs.helpBuild(sub, u, d, x, z)
			or Jobs.assistFactory(sub, u, d, x, z)
			or Jobs.reclaim(sub, u, d, x, z)
			or Jobs.goToZone(sub, u, d, x, z)
	end,
	army = function(sub, u, d, x, z)
		return Jobs.removeMarked(sub, u, d, x, z)
			-- the construction vehicle a faction overlay's quota makes (doctrine.factions) is the Army's
			or (not d.commander and Engine.auto(sub).factories and Jobs.techVehicles(sub, u, d))
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

-- an Army sub-commander without a factory of its own: the economy's lab builds its units (strong players
-- run one lab until about minute 8-10)
function Engine.armyToFeed()
	for _, s in ipairs(subs) do
		if s.role == "army" and not s.paused and s.counts.factories == 0 then
			return s
		end
	end
	-- an Army that asked the team for production (a known enemy army outweighs it) gets the economy's
	-- combat units even with labs of its own
	for _, r in ipairs(Engine.team.open("production")) do
		for _, s in ipairs(subs) do
			if s.id == r.from and s.role == "army" and not s.paused then
				return s
			end
		end
	end
end

-- the economy's lab: the opening (constructors and raiders in doctrine order), then the income tier's mix
-- of constructors and combat units; combat units go to an Army without a lab, else stay as a guard
-- does any constructor of ours (any sub-commander's, or the player's) have this flag's structure in its options
Engine.canBuildCache = {}
function Engine.teamCanBuild(flag)
	local c = Engine.canBuildCache[flag]
	if c and frame - c.frame < 90 then
		return c.v
	end
	local v = Engine.teamCanBuildNow(flag)
	Engine.canBuildCache[flag] = { frame = frame, v = v }
	return v
end

function Engine.teamCanBuildNow(flag)
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.builder and not spGetUnitIsBeingBuilt(u) then
			for _, o in ipairs(ud.options or {}) do
				if defs[o] and defs[o][flag] then
					return true
				end
			end
		end
	end
	return false
end

function Engine.economyProduction(sub, facID, fd, cap)
	local st = getState(facID)
	st.handOff, st.handOffCombat, st.openingPending = nil, nil, nil
	-- a tier-2 lab: its constructors first (extractor upgrades, fusion), then it goes to the Army
	if (fd.tech or 1) >= 2 then
		local t2 = 0
		for u in pairs(sub.units) do
			local ud = unitDef(u)
			if ud and ud.builder and (ud.tech or 1) >= 2 then
				t2 = t2 + 1
			end
		end
		-- one more while a strategic structure is due that no constructor on the team can build (Jobs.strategic)
		local want = Engine.D.economy.t2Builders + ((frame - (Engine.wantT2Builder or -99999) < 30 * 60) and 1 or 0)
		if t2 < want then
			-- the real T2 constructor (legack / armack / corack), else the builder with the most build
			-- options: the cheapest "builder" was the Infestor, built 212 times in one batch
			local cons = buildableBy(fd, function(od)
				return od.builder and not od.commander
			end)
			tsort(cons, function(a, b)
				local an, bn = (defs[a].name or ""):find("ack$") and 1 or 0, (defs[b].name or ""):find("ack$") and 1 or 0
				if an ~= bn then
					return an > bn
				end
				return #(defs[a].options or {}) > #(defs[b].options or {})
			end)
			if cons[1] then
				return cons[1], "tier 2 constructor"
			end
		end
		-- Intelligence v2: spies for Intelligence (its own factory is tier 1 or missing): handed over
		local intel = Engine.D.intel and Engine.subOfRole("intelligence")
		if intel and not intel.paused and Engine.cloakSpies(intel) < Engine.spottersWanted() then
			local spies = buildableBy(fd, function(od)
				return Engine.isSpotter(od) and od.canCloak
			end)
			tsort(spies, function(a, b)
				return defs[a].cost < defs[b].cost
			end)
			if spies[1] then
				st.handOff, st.handOffCombat = intel.id, true
				return spies[1], "spy for " .. intel.name
			end
		end
		for _, s in ipairs(subs) do
			if s.role == "army" and not s.paused then
				Engine.addUnit(s, facID)
				log(sub, fd.human .. ": T2 constructors done, handed to " .. s.name)
				log(s, "received " .. fd.human .. " (tier 2 units)")
				return nil, "handed to the army"
			end
		end
	end
	st.handOff, st.handOffCombat, st.openingPending = nil, nil, nil
	local counts = sub.counts
	local income = max(econ.mInc, 0)
	local target = Engine.D.economy.builders(income) + (Engine.D.economy.builderBonus or 0)
	-- expansion drive (doctrine.economy.expandDrive): free metal spots out of known threat call for
	-- constructors too, not only income (low income -> few constructors -> slow expansion: we stalled
	-- at 12-15 extractors while BARbarian hard reached 85)
	local XD = Engine.D.economy.expandDrive
	if XD then
		target = max(target, min(XD.cap, 3 + floor(Engine.freeSpots() / XD.perSpots)))
	end
	if (sub.autonomy or "balanced") == "light" then
		target = min(target, 3)
	end
	if sub.posture == "conserve" then
		target = min(target, 2)
	elseif sub.posture == "spend" then
		target = target + 2
	end
	-- army parity (doctrine.economy.armyParity): our army under `below` x their known mobile army: no
	-- new constructors, the factory builds army until it catches up (Cortex had 12 constructors and a
	-- third of BARbarian's army at minutes 10-14; the constructors couldn't hold any expansion)
	local AP = Engine.D.economy.armyParity
	if AP then
		local army = Engine.anyArmy()
		local ours = army and army.counts and army.counts.power or 0
		local theirs = 0
		for _, g in ipairs(Engine.tm.groups(frame, 20)) do
			theirs = theirs + max(0, g.power - g.static)
		end
		if theirs > AP.minEnemy and ours < AP.below * theirs then
			target = min(target, counts.builders)
		end
	end
	local feed = Engine.D.production.feedArmy and Engine.armyToFeed()
	local have = {}
	for k, v in pairs(counts.cats or {}) do
		have[k] = v
	end
	if feed then
		for k, v in pairs(feed.counts.cats or {}) do
			if k ~= "constructor" then
				have[k] = (have[k] or 0) + v
			end
		end
	end
	local kinds = Enemy.mix().kinds
	local defID, cat
	st.openStep = st.openStep or 1
	local step = frame < 30 * 60 * 6 and Engine.prod.opening(st.openStep)
	if step then
		defID, cat = Engine.prod.pick(fd.options, have, income, kinds, { category = step, cap = cap })
		st.openingPending = defID ~= nil
	end
	if not defID and counts.builders >= target then
		-- the faction's quota units (Armada's Gremlins) once the economy has its constructors
		defID = Engine.quotaPick(fd, cap)
		cat = defID and Engine.prod.category(defs[defID]) or nil
	end
	if not defID then
		-- raiders for the Army only once the economy has its constructors (v21b: the Army's production
		-- request made it feed raiders from 2 constructors on; the economy never grew past 3)
		local raider = feed and counts.builders >= target and Engine.raidNeed(feed) and "raider" or nil
		defID, cat = Engine.prod.pick(fd.options, have, income, kinds, { cap = cap, combatOnly = counts.builders >= target or raider ~= nil, category = raider })
	end
	if not defID then
		return nil, "nothing affordable"
	end
	if cat == "constructor" then
		return defID, "constructor"
	end
	-- the commander's escort first (v20: every unit went to the Army, the commander died alone twice)
	if feed and counts.combat >= Engine.D.economy.escorts then
		st.handOff, st.handOffCombat = feed.id, true
		return defID, "army (for " .. feed.name .. ")"
	end
	local guard = sub.posture == "conserve" and 2 or (sub.posture == "spend" and 8 or 4)
	if counts.combat >= guard then
		st.openingPending = nil
		-- metal piling up: more units, but for the Army (v19 kept 130 guards at home)
		local army = econ.mFrac >= 0.75 and Engine.anyArmy()
		if army then
			st.handOff, st.handOffCombat = army.id, true
			return defID, "army (for " .. army.name .. ", metal piling up)"
		end
		return nil, "enough guards"
	end
	return defID, step and "opening" or "guard"
end

-- Raids on: keep about doctrine.raid.share of the army's units raiders (at least enough for one squad)
function Engine.raidNeed(army)
	if not Engine.raiding(army) then
		return false
	end
	-- enough raider metal for a raid squad (doctrine.raid.min, with spare for losses), and their share
	local R = Engine.D.raid
	local power = (army.counts.catPower or {}).raider or 0
	local raiders = (army.counts.cats or {}).raider or 0
	return power < R.min * 1.5 or raiders < R.share * army.counts.combat
end

function Engine.anyArmy()
	for _, s in ipairs(subs) do
		if s.role == "army" and not s.paused then
			return s
		end
	end
end

-- does the sub-commander have a tier 2 constructor?
function Engine.hasT2Builder(sub)
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.builder and not d.commander and (d.tech or 1) >= 2 then
			return true
		end
	end
	return false
end

-- does an Army have an aircraft plant (air raids)?
function Engine.armyHasAirPlant()
	for _, s in ipairs(subs) do
		if s.role == "army" then
			for u in pairs(s.units) do
				local d = unitDef(u)
				if d and d.factory and makesAircraft(d) then
					return true
				end
			end
		end
	end
	return false
end

-- a sub-commander asked the team for a constructor (sc_team.lua): any economy or army factory that can
-- build one of the asked tier answers, once a minute per request. Tier 2: the real T2 constructor (the
-- one with the most build options; the cheapest "builder" was the Infestor)
function Engine.answerConstructor(fd, facID, cap)
	for _, r in ipairs(Engine.team.open("constructor")) do
		if frame - (r.answered or -99999) > 30 * 60 then
			local tier = r.tier or 1
			local cons = buildableBy(fd, function(od)
				return od.builder and not od.commander and (od.tech or 1) >= tier and od.cost <= cap * 2
			end)
			tsort(cons, function(a, b)
				if tier >= 2 then
					return #(defs[a].options or {}) > #(defs[b].options or {})
				end
				return defs[a].cost < defs[b].cost
			end)
			if cons[1] then
				r.answered = frame
				getState(facID).handOff = r.from
				return cons[1], sformat("%sconstructor for sub-commander %d (asked)", tier >= 2 and "tier 2 " or "", r.from)
			end
		end
	end
end

-- the Army's aircraft plant (air raids): two bombers to a gunship; fighters when the enemy flies (up to a
-- third of the wing)
function Engine.airProduction(sub, fd, cap)
	local have = { bomber = 0, gunship = 0, fighter = 0 }
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.air and have[d.kind] then
			have[d.kind] = have[d.kind] + 1
		end
	end
	local want
	if Enemy.share("air") > 0.15 and have.fighter * 2 < have.bomber + have.gunship then
		want = "fighter"
	elseif have.bomber < have.gunship * 2 + 1 then
		want = "bomber"
	else
		want = "gunship"
	end
	for _, kind in ipairs({ want, "bomber", "gunship" }) do
		local options = buildableBy(fd, function(od)
			return od.air and od.kind == kind and od.cost <= cap
		end)
		tsort(options, function(a, b)
			return defs[a].cost > defs[b].cost
		end)
		if options[1] then
			return options[1], "air wing (" .. kind .. ")"
		end
	end
	return nil, "no aircraft to build"
end

-- the Air Force's plants: the class sc_air.lua wants next (a scout, fighters to their share, bombers
-- and gunships), the strongest affordable of it
function Engine.airForceProduction(sub, fd, cap)
	local A = Engine.air
	local have = {}
	for u in pairs(sub.units) do
		local c = A.class(unitDef(u))
		if c then
			have[c] = (have[c] or 0) + 1
		end
	end
	local opts = {}
	for _, b in ipairs(fd.options or {}) do
		if defs[b] and defs[b].cost <= cap then
			opts[#opts + 1] = defs[b]
		end
	end
	local available = A.classes(opts)
	if not sub.airClassesNoted then
		sub.airClassesNoted = true
		local list = {}
		for c in pairs(available) do
			list[#list + 1] = c
		end
		tsort(list)
		log(sub, fd.human .. " makes: " .. (#list > 0 and tconcat(list, ", ") or "no planes we use"))
	end
	local want = A.want(have, Enemy.share("air"), available)
	if not want then
		return nil, "no aircraft to build"
	end
	for _, class in ipairs({ want }) do
		local options = buildableBy(fd, function(od)
			return A.class(od) == class and od.cost <= cap
		end)
		tsort(options, function(a, b)
			if class == "scout" then
				return (defs[a].radarRange or 0) > (defs[b].radarRange or 0)
			end
			return defs[a].cost > defs[b].cost
		end)
		if options[1] then
			return options[1], class
		end
	end
	return nil, "no aircraft to build"
end

-- an Army's own labs: the income tier's mix, moved toward what counters the enemy (sc_production.lua)
-- a faction's unit quotas (doctrine.production.quota: name -> how many to keep alive), first from a
-- factory that can build them (Armada's cloaked Gremlins for clandestine raids)
function Engine.quotaPick(fd, cap)
	-- resurrection bots (doctrine.strategic.resurrect)
	local R = Engine.D.strategic and Engine.D.strategic.resurrect
	if R and R.on and #Engine.ourStrategic().rezBot < R.bots then
		for _, o in ipairs(fd.options or {}) do
			if defs[o] and defs[o].rezBot and defs[o].cost <= (cap or math.huge) then
				return o
			end
		end
	end
	local Q = Engine.D.production.quota
	if not Q or not next(Q) then
		return nil
	end
	for _, o in ipairs(fd.options or {}) do
		local od = defs[o]
		local want = od and Q[od.name or ""]
		if want and od.cost <= (cap or math.huge) and (Spring.GetTeamUnitDefCount(myTeam, o) or 0) < want then
			return o
		end
	end
	return nil
end

-- our strategic structures and units (unitkinds flags: antinuke, shieldGen, lrpc, juno, rezBot), with
-- planned builds, counted once a second
Engine.stratCache = { frame = -9999 }
-- the cost-weighted centre of our finished factories (where a shield covers the most), or nil
function Engine.labsCentre()
	local sx, sz, w = 0, 0, 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud and ud.factory and not spGetUnitIsBeingBuilt(u) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				sx, sz, w = sx + x * ud.cost, sz + z * ud.cost, w + ud.cost
			end
		end
	end
	if w > 0 then
		return sx / w, sz / w
	end
end

function Engine.ourStrategic()
	local C = Engine.stratCache
	if frame - C.frame < 30 then
		return C
	end
	C.frame = frame
	for _, k in ipairs({ "antinuke", "shieldGen", "lrpc", "junoSilo", "rezBot", "nukeSilo" }) do
		C[k] = {}
	end
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local ud = unitDef(u)
		if ud then
			for _, k in ipairs({ "antinuke", "shieldGen", "lrpc", "junoSilo", "rezBot", "nukeSilo" }) do
				if ud[k] then
					C[k][#C[k] + 1] = u
				end
			end
		end
	end
	C.planned = {}
	for _, p in pairs(planned) do
		local pd = defs[p.defID]
		for _, k in ipairs({ "antinuke", "shieldGen", "lrpc", "junoSilo", "nukeSilo" }) do
			if pd and pd[k] then
				C.planned[k] = (C.planned[k] or 0) + 1
			end
		end
	end
	return C
end

-- what we know of theirs, by strategic role (Enemy.units)
function Engine.enemyHas(flag)
	local list = {}
	for u, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		if ed and ed[flag] then
			list[#list + 1] = { id = u, x = e.x, z = e.z, def = ed }
		end
	end
	return list
end

-- Defense's and Intelligence's strategic builds (doctrine.strategic): anti-nuke, shield and long-range
-- cannons (Defense; Economy when there is no Defense), Juno (Intelligence). One at a time.
function Jobs.strategic(sub, unitID, d, ux, uz)
	local G = Engine.D.strategic
	if not G or not Engine.homeX then
		return false
	end
	local C = Engine.ourStrategic()
	local minute, income = frame / 1800, max(econ.mInc, 0)
	local function have(k)
		return #C[k] + (C.planned[k] or 0)
	end
	-- Defense's and the Economy's constructors (the Economy has most of the T2 ones; Defense's two were
	-- always repairing), Intelligence's for Juno (the Economy's too: Intelligence runs one constructor)
	local defenseRole = sub.role == "defense" or sub.role == "economy"
	local intelRole = sub.role == "intelligence" or sub.role == "economy"
	-- due but not started: say why, once in a while (no constructor that can build it, can't afford it)
	local function blocked(what)
		local can = #buildableBy(d, function(od)
			return od[what]
		end) > 0
		-- nobody on the team can build it (tier 2): the T2 lab makes one more constructor (economyProduction)
		if not can and not Engine.teamCanBuild(what) then
			Engine.wantT2Builder = frame
		end
		local key = "strat:" .. what
		if frame - (sub[key] or -99999) > 30 * 300 then
			sub[key] = frame
			log(sub, sformat("%s due: %s", what, can and sformat("can't place or afford it yet (metal %d%%)", econ.mFrac * 100)
				or (Engine.teamCanBuild(what) and "waiting for a tier 2 constructor to be free" or "no constructor on the team can build it: asking for one")))
		end
	end
	local hx, hz = Engine.homeX, Engine.homeZ
	if defenseRole then
		local A = G.antinuke
		if A.on and have("antinuke") < A.max and (#Engine.enemyHas("nukeSilo") > 0 or (A.minute and minute >= A.minute and income >= A.income)) then
			if buildCheapestUseful(sub, unitID, d, hx, hz, function(od)
				return od.antinuke
			end, function(od)
				return -od.cost
			end, "anti-nuke", "essential") then
				return true
			end
			blocked("antinuke")
		end
		local Sh = G.shield
		local threat = #Engine.enemyHas("lrpc") > 0 or Enemy.share("air") > 0.15
		if Sh.on and have("shieldGen") < Sh.max and income >= Sh.income and (threat or (Sh.minute and minute >= Sh.minute)) then
			local fx, fz = Engine.labsCentre()
			fx, fz = fx or hx, fz or hz
			if buildCheapestUseful(sub, unitID, d, fx, fz, function(od)
				return od.shieldGen
			end, function(od)
				return -od.cost
			end, "shield over the labs", "strategic") then
				return true
			end
			blocked("shieldGen")
		end
		local L = G.lrpc
		local losing = Engine.team.plan.phase == "defend"
		local counter = #Engine.enemyHas("lrpc") > 0
		local surplus = income >= L.income and econ.mFrac >= (L.surplus or 0) and not losing
		if L.on and have("lrpc") < L.max and minute >= L.minute and (counter or surplus) and Engine.enemyX then
			-- the cheapest cannon (Olympus 5200, not Legion's 63000-metal Starfall: smoke test 4 started 26)
			local function isGun(od)
				return od.lrpc and od.cost <= (L.maxCost or 8000)
			end
			local opts = buildableBy(d, isGun)
			tsort(opts, function(a, b)
				return defs[a].cost < defs[b].cost
			end)
			if #opts > 0 then
				local function threatAt(px, pz)
					return Engine.tm.threat(px, pz)
				end
				local range = defs[opts[1]].range
				-- a safe place that reaches their base; else one that reaches a lab or something worth 200+
				-- of theirs (their base centre sat inside their threat on All That Simmers), the safest
				local x, z = Engine.strategic.lrpcSite({ x = hx, z = hz }, { x = Engine.enemyX, z = Engine.enemyZ }, range, threatAt)
				if not x then
					local bestD
					for _, e in pairs(Enemy.units) do
						local ed = defs[e.defID]
						if ed and not ed.mobile and (ed.factory or ed.cost >= 200) then
							local sx, sz = Engine.strategic.lrpcSite({ x = hx, z = hz }, { x = e.x, z = e.z }, range, threatAt)
							local dd = sx and dist2(hx, hz, sx, sz) - (ed.factory and 1e6 or 0)
							if sx and (not bestD or dd < bestD) then
								x, z, bestD = sx, sz, dd
							end
						end
					end
				end
				-- worth it only with enough of theirs in reach from there (doctrine.strategic.lrpc.minTargetValue)
				local inReach = 0
				if x then
					for _, e in pairs(Enemy.units) do
						local ed = defs[e.defID]
						-- every structure of theirs we have seen (they don't move; the 10-minute window missed most of
						-- their base: "only N metal in reach" 90+ times in g70)
						if ed and not ed.mobile and dist2(x, z, e.x, e.z) <= (range * 0.95) ^ 2 then
							inReach = inReach + ed.cost
						end
					end
				end
				if not x or inReach < (L.minTargetValue or 0) then
					if frame - (sub["strat:lrpcsite"] or -99999) > 30 * 300 then
						sub["strat:lrpcsite"] = frame
						log(sub, x and sformat("lrpc due: only %d metal of theirs in reach", inReach) or "lrpc due: no safe place reaches anything of theirs")
					end
				elseif buildCheapestUseful(sub, unitID, d, x, z, isGun, function(od)
					return -od.cost
				end, "long-range cannon on their base", "strategic") then
					return true
				end
			end
			blocked("lrpc")
		end
		-- a nuke silo late, with a big economy and a surplus, not while defending (doctrine.strategic.nuke)
		local N = G.nuke
		if N and N.on and have("nukeSilo") < N.max and minute >= N.minute and income >= N.income and econ.eInc >= N.energy
			and econ.mFrac >= N.surplus and not losing then
			local ax, az = Engine.safeEnergyAnchor()
			if buildCheapestUseful(sub, unitID, d, ax or hx, az or hz, function(od)
				return od.nukeSilo
			end, function(od)
				return -od.cost
			end, "nuke silo", "strategic") then
				return true
			end
			blocked("nukeSilo")
		end
	end
	if intelRole then
		local J = G.juno
		local jt, jw = Engine.junoTargets(), 0
		for _, t in ipairs(jt) do
			jw = jw + (t.weight or 1)
		end
		if J.on and have("junoSilo") < 1 and income >= J.income and jw >= J.minTargets then
			-- behind the base, where generators go: its centre was too crowded to place one (smoke test 4)
			local jx, jz = Engine.safeEnergyAnchor()
			if buildCheapestUseful(sub, unitID, d, jx or hx, jz or hz, function(od)
				return od.junoSilo
			end, function(od)
				return -od.cost
			end, "Juno (their radar and jammers)", "strategic") then
				return true
			end
			blocked("junoSilo")
		end
	end
	return false
end

-- their radar, jammers, cameras and mines we know of (Juno's targets)
-- where we're operating right now: the Air Force's strike, the army's push, our long-range cannons'
-- targets. Juno there helps the operation: their radar no longer sees our bombers or army coming, and
-- their jammers no longer hide what our cannons should hit
function Engine.operationPoints()
	local pts = {}
	for _, s in ipairs(subs) do
		local strike = s.airOrders and s.airOrders.strike
		if strike and strike.action == "strike" then
			pts[#pts + 1] = { x = strike.x, z = strike.z }
		end
		if s.pushTarget and s.pushTarget.x then
			pts[#pts + 1] = { x = s.pushTarget.x, z = s.pushTarget.z }
		end
	end
	for _, u in ipairs(Engine.ourStrategic().lrpc) do
		local st = ustate[u]
		local e = st and st.lrpcTarget and Enemy.units[st.lrpcTarget]
		if e then
			pts[#pts + 1] = { x = e.x, z = e.z }
		end
	end
	return pts
end

function Engine.junoTargets()
	local list = {}
	local J = Engine.D.strategic.juno
	local ops = J.opWeight and Engine.operationPoints() or {}
	for _, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		local t
		if ed and (ed.jammer or 0) > 0 and not ed.commander then
			-- jammers, static or mobile: they hide an army (worth a missile on their own)
			t = { x = e.x, z = e.z, cost = ed.cost, weight = 2 }
		elseif ed and not ed.mobile and (ed.intelStructure or ed.mine or ed.kind == "radar" or ed.kind == "camera") then
			t = { x = e.x, z = e.z, cost = ed.cost, weight = 1 }
		end
		if t then
			-- v2: near one of our operations (doctrine.strategic.juno.opWeight, within opRadius) it counts more
			for _, p in ipairs(ops) do
				if dist2(t.x, t.z, p.x, p.z) <= (J.opRadius or 1800) ^ 2 then
					t.weight = t.weight * J.opWeight
					break
				end
			end
			list[#list + 1] = t
		end
	end
	return list
end

-- a target's role for the long-range cannons (sc_strategic.lua lrpcTarget)
function Engine.strategicRole(ed)
	if ed.lrpc then
		return "lrpc"
	elseif ed.nukeSilo then
		return "nuke"
	elseif ed.antinuke then
		return "antinuke"
	elseif ed.factory then
		return "factory"
	elseif ed.shieldGen then
		return "shield"
	elseif (ed.energy or 0) > 0 and ed.cost >= 500 then
		return "energy"
	elseif (ed.mex or 0) > 0 then
		return "extractor"
	elseif ed.staticDef then
		return "turret"
	end
	return "other"
end

-- every 2 s: interceptors and Juno missiles stockpiled, Juno fired at their densest intel, the long-range
-- cannons on their best target, resurrection bots on the best wreck
function Engine.strategicControl()
	local G = Engine.D.strategic
	if not G or not canControl then
		return
	end
	local C = Engine.ourStrategic()
	local function stock(u, want)
		local have, queued = Spring.GetUnitStockpile(u)
		for _ = 1, want - (have or 0) - (queued or 0) do
			order(u, CMD.STOCKPILE, {})
		end
		return have or 0
	end
	if G.antinuke.on then
		for _, u in ipairs(C.antinuke) do
			if not spGetUnitIsBeingBuilt(u) then
				stock(u, G.antinuke.stockpile)
			end
		end
	end
	if G.juno.on then
		for _, u in ipairs(C.junoSilo) do
			if not spGetUnitIsBeingBuilt(u) and stock(u, G.juno.stockpile) > 0 then
				local st = getState(u)
				if frame >= (st.junoNext or 0) then
					local x, z, n = Engine.strategic.junoTarget(Engine.junoTargets(), G.juno.aoe, G.juno.minTargets)
					if x then
						order(u, CMD.ATTACK, { x, spGetGroundHeight(x, z), z })
						st.junoNext = frame + 30 * 20
						Engine.lastJunoAt = { x = x, z = z, r = G.juno.aoe, frame = frame }
						local sub = owner[u]
						if sub then
							log(sub, sformat("Juno on %d of their radar / jammers / mines at %d,%d", n, x, z))
						end
					end
				end
			end
		end
	end
	if G.lrpc.on and #C.lrpc > 0 then
		local targets, shields = {}, {}
		for u, e in pairs(Enemy.units) do
			local ed = defs[e.defID]
			if ed and not ed.mobile and frame - e.last < 30 * 600 then
				targets[#targets + 1] = { id = u, x = e.x, z = e.z, cost = ed.cost, role = Engine.strategicRole(ed) }
				if ed.shieldGen then
					shields[#shields + 1] = { x = e.x, z = e.z, r = 550 }
				end
			end
		end
		for _, u in ipairs(C.lrpc) do
			local ud = unitDef(u)
			local x, _, z = spGetUnitPosition(u)
			if x and ud and not spGetUnitIsBeingBuilt(u) then
				local st = getState(u)
				local t = Engine.strategic.lrpcTarget({ x = x, z = z, range = ud.range }, targets, shields)
				if t and (st.lrpcTarget ~= t.id or not isAlive(t.id)) then
					order(u, CMD.ATTACK, { t.id })
					st.lrpcTarget = t.id
					local td = Enemy.units[t.id] and defs[Enemy.units[t.id].defID]
					if owner[u] then
						log(owner[u], sformat("%s fires on their %s (%s, %d metal)", ud.human, td and td.human or "structure", t.role, t.cost or 0))
					end
				end
			end
		end
	end
	-- nukes: one stockpiled, fired at the richest cluster of theirs no anti-nuke covers
	local N = G.nuke
	if N and N.on and #C.nukeSilo > 0 then
		local cands, antis = {}, {}
		-- never near our own army or base (their army in a fight with ours is ours too under the blast)
		local army = Engine.anyArmy()
		local sq = army and army.squad
		local function ours(x, z)
			return Engine.inBase(x, z) or (sq and sq.x and dist2(x, z, sq.x, sq.z) < 1400 * 1400)
		end
		for _, e in pairs(Enemy.units) do
			local ed = defs[e.defID]
			if ed and (frame - e.last < 30 * (ed.mobile and 60 or 600)) then
				if ed.interceptor then
					antis[#antis + 1] = { x = e.x, z = e.z, r = ed.mobile and 1600 or 2000 }
				end
				if not ours(e.x, e.z) then
					cands[#cands + 1] = { x = e.x, z = e.z, cost = ed.cost }
				end
			end
		end
		for _, u in ipairs(C.nukeSilo) do
			local ud = unitDef(u)
			if ud and not spGetUnitIsBeingBuilt(u) and stock(u, N.stockpile) > 0 and frame - (Engine.lastNuke or -99999) > 30 * N.every then
				local aoe = ud.weaponAoe or 640
				local x, z, v = Engine.strategic.nukeTarget(cands, aoe, antis, N.minValue)
				-- none of ours under the blast: anything of ours within 1.2 x its radius worth more than
				-- max(300, a tenth of the target) rules that target out (g69: our Supernova killed 57 of our
				-- own units spread around the fight; the army squad's centre alone wasn't enough)
				local safe = false
				for _ = 1, 6 do
					if not x then
						break
					end
					local mine = 0
					for _, o in ipairs(spGetUnitsInCylinder(x, z, aoe * 1.2)) do
						local od = spGetUnitTeam(o) == myTeam and unitDef(o)
						mine = mine + (od and od.cost or 0)
					end
					if mine <= max(300, v * 0.1) then
						safe = true
						break
					end
					local keep = {}
					for _, c in ipairs(cands) do
						if dist2(c.x, c.z, x, z) > (aoe * 1.5) ^ 2 then
							keep[#keep + 1] = c
						end
					end
					cands = keep
					x, z, v = Engine.strategic.nukeTarget(cands, aoe, antis, N.minValue)
				end
				if x and safe then
					order(u, CMD.ATTACK, { x, spGetGroundHeight(x, z), z })
					Engine.lastNuke = frame
					Engine.lastNukeAt = { x = x, z = z, r = ud.weaponAoe or 640, frame = frame }
					if owner[u] then
						log(owner[u], sformat("%s: nuke on %d metal of theirs at %d,%d (%d anti-nukes known)", ud.human, v, x, z, #antis))
					end
				end
			end
		end
	end
	if G.resurrect.on and #C.rezBot > 0 and Spring.GetFeatureResurrect then
		local army = Engine.anyArmy()
		local centres = { { Engine.homeX, Engine.homeZ } }
		if army and army.squad and army.squad.x then
			centres[#centres + 1] = { army.squad.x, army.squad.z }
		end
		local wrecks, seen = {}, {}
		for _, c in ipairs(centres) do
			if c[1] then
				for _, f in ipairs(Spring.GetFeaturesInCylinder(c[1], c[2], G.resurrect.radius) or {}) do
					local name = not seen[f] and Spring.GetFeatureResurrect(f)
					seen[f] = true
					local rd = name and name ~= "" and UnitDefNames[name]
					local fx, _, fz = Spring.GetFeaturePosition(f)
					if rd and fx and Engine.tm.threat(fx, fz) <= 0 then
						wrecks[#wrecks + 1] = { id = f, x = fx, z = fz, value = rd.metalCost or 0 }
					end
				end
			end
		end
		for _, u in ipairs(C.rezBot) do
			local st = getState(u)
			if not st.manual and (spGetUnitCommandCount(u) or 0) == 0 then
				local x, _, z = spGetUnitPosition(u)
				local w = x and Engine.strategic.rezTarget({ x = x, z = z }, wrecks)
				if w then
					order(u, CMD.RESURRECT, { w.id + Game.maxUnits })
					local rd = UnitDefNames[Spring.GetFeatureResurrect(w.id)]
					local sub = owner[u]
					setTask(u, "resurrect", "resurrecting " .. (rd and (rd.translatedHumanName or rd.humanName) or "a wreck"), true)
					if sub then
						log(sub, sformat("resurrecting %s (%d metal)", rd and (rd.translatedHumanName or rd.humanName) or "a wreck", w.value))
					end
					for i, o in ipairs(wrecks) do
						if o.id == w.id then
							table.remove(wrecks, i)
							break
						end
					end
				end
			end
		end
	end
end

function Engine.armyProduction(sub, fd, cap)
	if makesAircraft(fd) then
		return Engine.airProduction(sub, fd, cap)
	end
	local q = Engine.quotaPick(fd, cap)
	if q then
		return q, "army (" .. (defs[q].human or "quota") .. ", faction quota)"
	end
	-- no unit-count cap: metal limits production (a count cap only idled the lab while metal piled up)
	local defID = Engine.prod.pick(fd.options, sub.counts.cats or {}, max(econ.mInc, 0), Enemy.mix().kinds,
		{ cap = cap, combatOnly = true, category = Engine.raidNeed(sub) and "raider" or nil })
	if not defID then
		return nil, "nothing affordable"
	end
	return defID, "army"
end

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
	if sub.role == "economy" or sub.role == "army" then
		local c, why = Engine.answerConstructor(fd, facID, cap)
		if c then
			return c, why
		end
	end
	if sub.role == "economy" then
		-- a sub-commander that lost all its constructors gets a new one from us first
		for _, other in ipairs(subs) do
			if other ~= sub and other.counts.builders == 0 and #other.zones > 0 and not other.paused
				and (other.role == "defense" or other.role == "air" or other.role == "intelligence")
				and frame - (other.builderSent or -99999) > 30 * 60 then
				local options = buildableBy(fd, function(od)
					return od.builder and not od.commander
				end)
				tsort(options, function(a, b)
					return defs[a].cost < defs[b].cost
				end)
				if options[1] then
					getState(facID).handOff = other.id
					other.builderSent = frame
					return options[1], "constructor for " .. other.name
				end
			end
		end
		return Engine.economyProduction(sub, facID, fd, cap)
	elseif sub.role == "army" then
		return Engine.armyProduction(sub, fd, cap)
	elseif sub.role == "air" and counts.builders >= 1 and makesAircraft(fd) then
		return Engine.airForceProduction(sub, fd, cap)
	elseif counts.builders < 1 then
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
		-- Intelligence v2: cloaking spies for the spotter posts first (this factory or the T2 lab's hand-off),
		-- scouts fill in where no spy can be made
		if Engine.D.intel then
			local want = Engine.spottersWanted()
			if Engine.cloakSpies(sub) < want then
				local spies = buildableBy(fd, function(od)
					return Engine.isSpotter(od) and od.canCloak and od.cost <= cap * 1.5
				end)
				tsort(spies, function(a, b)
					return defs[a].cost < defs[b].cost
				end)
				if spies[1] then
					return spies[1], "spy (eyes for the cannons and bombers)"
				end
			end
			scoutCap = max(scoutCap, want)
		end
		if counts.scouts < scoutCap then
			local options = buildableBy(fd, function(od)
				return (od.scout or (od.air and not od.armed and not od.transport and not od.builder)) and od.cost <= cap
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
		-- fast hunters for enemy intel and economy: ground raiders, or gunships from an aircraft plant
		local airPlant = makesAircraft(fd)
		local options = buildableBy(fd, function(od)
			return od.combat and not od.aaOnly and not od.scout and (not od.air or airPlant) and od.cost <= cap
		end)
		tsort(options, function(a, b)
			return defs[a].speed > defs[b].speed
		end)
		if options[1] then
			return options[1], airPlant and "gunship" or "raider"
		end
		return nil, "nothing to build"
	end
	-- metal piling up: units are how it turns into map control
	local armyCap = p.army * (sub.role == "army" and 1.5 or 1) * (econ.mFrac > 0.8 and 2 or 1)
	if counts.combat >= armyCap then
		return nil, "at unit cap"
	end
	local wantAA = sub.role == "air" -- a ground factory of the Air Force makes mobile anti-air
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

-- Features for our own decision models (design/decision-models.md). They mirror what the data logger
-- records (testenv/LuaUI/Widgets/zz_datalog.lua): counts by kind, value, health, from what we can see.
function Decider.traits(d)
	return { name = d.name, human = d.human, kind = d.kind, cost = floor(d.cost + 0.5), range = floor(d.range), speed = floor(d.speed), health = floor(d.health), dps = floor(d.dps), air = d.air, aaOnly = d.aaOnly, tech = d.tech }
end

-- summary of { defID, hpFraction } entries
function Decider.group(list)
	local kinds, value, hp, air, dps, hpSum, rangeW = {}, 0, 0, 0, 0, 0, 0
	for _, e in ipairs(list) do
		local d = defs[e[1]]
		kinds[d.kind] = (kinds[d.kind] or 0) + 1
		value = value + d.cost
		hp = hp + e[2]
		if d.air then
			air = air + 1
		end
		dps = dps + d.dps
		hpSum = hpSum + e[2] * d.health
		rangeW = rangeW + d.range * d.cost
	end
	return {
		kinds = kinds, value = floor(value + 0.5), health = #list > 0 and floor(hp / #list * 100 + 0.5) or 0, count = #list, air = air,
		dps = floor(dps + 0.5), hp = floor(hpSum + 0.5), range = value > 0 and floor(rangeW / value + 0.5) or 0,
	}
end

local function hpFraction(u)
	local hp, maxHp = Spring.GetUnitHealth(u)
	return hp and maxHp and maxHp > 0 and hp / maxHp or 1
end

-- what our team fields and what we know the enemy fields (armed units and turrets)
function Decider.situation()
	local own, enemy = {}, {}
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local defID = Spring.GetUnitDefID(u)
		local d = defID and defs[defID]
		if d and ((d.mobile and d.armed and not d.builder and not d.commander) or d.staticDef) and not spGetUnitIsBeingBuilt(u) then
			own[#own + 1] = { defID, hpFraction(u) }
		end
	end
	for u, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if ((d.mobile and d.armed and not d.builder and not d.commander) or d.staticDef) and frame - e.last < Const.COMPOSITION_WINDOW then
			enemy[#enemy + 1] = { e.defID, spGetUnitPosition(u) and hpFraction(u) or 1 }
		end
	end
	return { own = Decider.group(own), enemy = Decider.group(enemy), metalIncome = floor(econ.mInc * 10 + 0.5) / 10 }
end

-- the candidate the model thinks most likely to pay for itself
function Decider.bestCandidate(answers)
	local best, bestP
	for name, a in pairs(answers or {}) do
		local p = type(a) == "table" and tonumber(a.noul)
		if p and UnitDefNames[name] and (not bestP or p > bestP) then
			best, bestP = UnitDefNames[name].id, p
		end
	end
	return best, bestP
end

function Decider.ready()
	local ai = WG.SubCommandersAI
	return ai and ai.deciderReady and ai.deciderReady() and ai.decideTask and ai or nil
end

-- Combat: will our army come out ahead in a fight at (x, z)? Cached per sub and 400-elmo cell for 10 s;
-- returns the probability, or nil while there's no answer (the rules decide meanwhile).
function Decider.fightVerdict(sub, x, z)
	local ai = Decider.ready()
	if not ai then
		return nil
	end
	sub.fightVerdicts = sub.fightVerdicts or {}
	local key = floor(x / 400) .. ":" .. floor(z / 400)
	local v = sub.fightVerdicts[key]
	if v and frame - v.frame < 30 * 10 then
		return v.p
	end
	if v and v.asking and frame - v.frame < 60 then
		return nil
	end
	local own, ownTurrets, enemy, enemyTurrets = {}, {}, {}, {}
	local oh, on, eh, en = 0, 0, 0, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.combat and not spGetUnitIsBeingBuilt(u) then
			own[#own + 1] = { Spring.GetUnitDefID(u), hpFraction(u) }
			local _, y = spGetUnitPosition(u)
			oh, on = oh + (y or 0), on + 1
		end
	end
	if #own == 0 then
		return nil
	end
	for _, u in ipairs(spGetUnitsInCylinder(x, z, 900, myTeam)) do
		local d = unitDef(u)
		if d and d.staticDef then
			ownTurrets[#ownTurrets + 1] = { Spring.GetUnitDefID(u), hpFraction(u) }
		end
	end
	for u, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if d.armed and dist2(x, z, e.x, e.z) < 1100 * 1100 and (d.staticDef or frame - e.last < 30 * 20) then
			local entry = { e.defID, spGetUnitPosition(u) and hpFraction(u) or 1 }
			if d.staticDef then
				enemyTurrets[#enemyTurrets + 1] = entry
			elseif d.mobile then
				enemy[#enemy + 1] = entry
			end
			eh, en = eh + spGetGroundHeight(e.x, e.z), en + 1
		end
	end
	local sx, _, sz = Spring.GetTeamStartPosition(myTeam)
	local enemyStart
	for _, st in ipairs(getEnemyStarts()) do
		local dd = sqrt(dist2(x, z, st.x, st.z))
		enemyStart = enemyStart and min(enemyStart, dd) or dd
	end
	local features = {
		minute = floor(frame / 1800),
		own = Decider.group(own), ownTurrets = Decider.group(ownTurrets),
		enemy = Decider.group(enemy), enemyTurrets = Decider.group(enemyTurrets),
		heightDiff = en > 0 and floor(oh / on - eh / en) or 0,
		ownStart = sx and sx > 0 and floor(sqrt(dist2(x, z, sx, sz))) or -1,
		enemyStart = enemyStart and floor(enemyStart) or -1,
	}
	sub.fightVerdicts[key] = { frame = frame, asking = true, p = v and v.p }
	ai.decideTask(sub.id, "fight", features, function(answers)
		local a = answers and answers.ahead
		local p = type(a) == "table" and tonumber(a.noul)
		sub.fightVerdicts[key] = { frame = frame, p = p }
	end)
	return v and v.p
end

-- Production by lookahead with the combat model: for each candidate, add a fixed metal budget of it to
-- our army and ask whether that army would come out ahead against the enemy army we have seen; build the
-- candidate with the best answer. (Asking "will this unit pay for itself?" picked the cheapest units and
-- lost games: design/decision-models.md, phase 5.)
function Decider.lookahead(sub, options, st, ai)
	local army, enemy = {}, {}
	local armyValue = 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local defID = Spring.GetUnitDefID(u)
		local d = defID and defs[defID]
		if d and d.mobile and d.armed and not d.builder and not d.commander and not spGetUnitIsBeingBuilt(u) then
			army[#army + 1] = { defID, hpFraction(u) }
			armyValue = armyValue + d.cost
		end
	end
	for u, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		if d.mobile and d.armed and not d.builder and not d.commander and frame - e.last < Const.COMPOSITION_WINDOW then
			enemy[#enemy + 1] = { e.defID, spGetUnitPosition(u) and hpFraction(u) or 1 }
		end
	end
	if #enemy == 0 then
		return false -- nothing to measure against yet: the rules decide
	end
	local budget = max(600, armyValue * 0.25)
	local starts = getEnemyStarts()
	local sx, _, sz = Spring.GetTeamStartPosition(myTeam)
	local half = (starts[1] and sx and sx > 0) and floor(sqrt(dist2(sx, sz, starts[1].x, starts[1].z)) / 2) or -1
	local enemyGroup = Decider.group(enemy)
	local empty = Decider.group({})
	local results, pending = {}, min(#options, 6)
	for i = 1, pending do
		local o = options[i]
		local trial = {}
		for j = 1, #army do
			trial[j] = army[j]
		end
		for _ = 1, max(1, floor(budget / max(defs[o].cost, 1))) do
			trial[#trial + 1] = { o, 1 }
		end
		local features = { minute = floor(frame / 1800), own = Decider.group(trial), ownTurrets = empty, enemy = enemyGroup, enemyTurrets = empty, heightDiff = 0, ownStart = half, enemyStart = half }
		ai.decideTask(sub.id, "fight", features, function(answers)
			local a = answers and answers.ahead
			results[o] = type(a) == "table" and tonumber(a.noul) or nil
			pending = pending - 1
			if pending == 0 then
				st.asking = nil
				local best, bestP
				for defID, p in pairs(results) do
					if not bestP or p > bestP then
						best, bestP = defID, p
					end
				end
				if best then
					st.pick, st.pickFrame = best, frame
				else
					st.askFailed = frame
				end
			end
		end)
	end
	return true
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
		return od.combat and od.cost <= cap and (sub.role ~= "air" or od.aaOnly)
	end)
	if #options < 2 then
		return false
	end
	tsort(options, function(a, b)
		return defs[a].cost > defs[b].cost
	end)
	local sent = ai.decideTask and Decider.lookahead(sub, options, st, ai)
	if not sent then
		return false
	end
	st.asking = frame
	return nil
end

function Decider.describeTurret(d)
	local hints = {}
	if d.aaOnly then
		hints[#hints + 1] = "shoots aircraft only, good against bombers and gunships"
	else
		if d.cost < 150 then
			hints[#hints + 1] = "cheap and quick to build, good against raiders and light units"
		end
		if d.dps / max(d.cost, 1) > 0.5 and d.cost >= 200 then
			hints[#hints + 1] = "high damage, good against armored and heavy units"
		end
		if d.range >= 650 then
			hints[#hints + 1] = "long range, good against skirmishers and artillery"
		end
	end
	return sformat("%s (%s): range %d, damage per second %d, health %d, cost %d metal%s", d.human, d.name, d.range, d.dps, d.health, d.metal, #hints > 0 and ("; " .. tconcat(hints, "; ")) or "")
end

-- Defense: ask which turret type fits the enemy, every 45 s; pickDefense uses sub.turretPick
function Decider.refreshTurrets(sub)
	local ai = WG.SubCommandersAI
	if sub.role ~= "defense" or sub.focus or not (ai and ai.deciderReady and ai.deciderReady()) then
		return
	end
	if sub.turretAsked and frame - sub.turretAsked < 30 * 45 then
		return
	end
	local builder
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d and d.builder then
			builder = d
			break
		end
	end
	if not builder then
		return
	end
	local cap = costCap(sub, 1.5)
	local options = buildableBy(builder, function(od)
		return od.staticDef and not od.aaOnly and od.cost <= cap
	end)
	if #options < 2 then
		return
	end
	local candidates = {}
	for i = 1, min(#options, 8) do
		candidates[i] = Decider.traits(defs[options[i]])
	end
	-- where it would stand: the front edge of the main zone
	local zone = largestZone(sub)
	local place
	if zone then
		local cx, cz = Zone.center(zone)
		local ex, ez = enemyDirectionRef(cx, cz)
		local fx, fz = Zone.edgeToward(zone, ex, ez, 160)
		local near = 0
		for _, u in ipairs(spGetUnitsInCylinder(fx, fz, 600, myTeam)) do
			local d = unitDef(u)
			near = near + ((d and d.staticDef) and 1 or 0)
		end
		local nearest
		for _, e in pairs(Enemy.units) do
			if frame - e.last < 30 * 60 then
				local dd = sqrt(dist2(fx, fz, e.x, e.z))
				nearest = nearest and min(nearest, dd) or dd
			end
		end
		local sx, _, sz = Spring.GetTeamStartPosition(myTeam)
		local es
		for _, st in ipairs(getEnemyStarts()) do
			local dd = sqrt(dist2(fx, fz, st.x, st.z))
			es = es and min(es, dd) or dd
		end
		place = { turretsNear = near, ownStart = sx and sx > 0 and floor(sqrt(dist2(fx, fz, sx, sz))) or -1, enemyStart = es and floor(es) or -1, nearestEnemy = nearest and nearest < 3000 and floor(nearest) or -1 }
	end
	sub.turretAsked = frame
	ai.decideTask(sub.id, "turret", { minute = floor(frame / 1800), situation = Decider.situation(), place = place, candidates = candidates }, function(answers)
		local choice = Decider.bestCandidate(answers)
		if choice then
			local defID = choice
			if not (sub.turretPick and sub.turretPick.defID == defID) then
				log(sub, "turrets: " .. defs[defID].human .. " (decision model)")
			end
			sub.turretPick = { defID = defID, frame = frame }
		end
	end)
end

local function thinkFactory(sub, facID, fd, st)
	if spGetUnitIsBeingBuilt(facID) then
		return
	end
	-- one queued behind the one being built: no idle gap between units while the next think comes round
	if (spGetFactoryCommandCount(facID) or 0) > 1 then
		return
	end
	local defID, why = pickProduction(sub, facID, fd)
	if not defID then
		st.factoryNote = why
		return
	end
	if why == "army" or why == "anti-air" then
		local pick = Decider.production(sub, facID, fd, st)
		-- still asking: the rules build this one, the model's answer goes to the next (it waited up to 2 s
		-- a unit, and answers over the file transport come late)
		if pick then
			defID, why = pick, "decision model"
		end
	end
	if not canSpend(sub, defs[defID]) then
		st.factoryNote = "waiting for resources"
		return
	end
	order(facID, -defID, {})
	if st.openingPending then
		st.openStep, st.openingPending = (st.openStep or 1) + 1, nil
	end
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

local Tactics = {} -- commander safety, army counter-push and rally point

-- Counter-push: a clearly stronger army with nothing to defend goes for the nearest known enemy
-- structure few turrets guard (extractors, radar, expansions), and comes home when that changes.
function Tactics.updatePush(sub)
	if sub.role ~= "army" or not sub.armyX or sub.paused or not Engine.auto(sub).push then
		sub.pushTarget = nil
		return
	end
	local power = sub.counts.power
	local near = Enemy.powerNear(sub.armyX, sub.armyZ, 1800)
	-- only a real attack on the base calls a push off (the team plan's measure, scaled to our army):
	-- raiders are the response squad's and the turrets' job
	local baseAttacked = Engine.team.plan.base
	if baseAttacked or power < 2000 or power < 1.5 * near then
		if sub.pushTarget then
			log(sub, "push called off: " .. (baseAttacked and "the base needs us" or "not strong enough here"))
		end
		sub.pushTarget = nil
		return
	end
	local t = sub.pushTarget
	if t and Enemy.units[t.id] then
		return
	end
	local best, bestD
	for u, e in pairs(Enemy.units) do
		local ed = defs[e.defID]
		if not ed.mobile and not ed.staticDef and frame - e.last < 30 * 600 then
			local dd = dist2(sub.armyX, sub.armyZ, e.x, e.z)
			if dd < 4500 * 4500 and (not bestD or dd < bestD) then
				local guard = 0
				for _, o in pairs(Enemy.units) do
					if defs[o.defID].staticDef and dist2(o.x, o.z, e.x, e.z) < 700 * 700 then
						guard = guard + defs[o.defID].cost
					end
				end
				if guard * 2 < power then
					best, bestD = { id = u, x = e.x, z = e.z, name = ed.human }, dd
				end
			end
		end
	end
	-- the combat model has the last word on a push, when it has answered
	if best then
		local p = Decider.fightVerdict(sub, best.x, best.z)
		if p ~= nil and p < 0.6 then
			best = nil
		end
	end
	if best and not (t and t.id == best.id) then
		log(sub, sformat("pushing: %s at %d,%d (we are clearly stronger)", best.name, best.x, best.z))
	end
	sub.pushTarget = best
end

-- army rally point: the safe edge of our side toward the enemy (threat map), or the edge of a zone the
-- player drew; never where known enemy weapons reach more than ours (artillery outranges turrets)
function Tactics.rallyPoint(sub)
	local hx, hz = Engine.homeX, Engine.homeZ
	if not hx then
		return nil
	end
	local rx, rz
	local zone = not sub.autoZones and largestZone(sub)
	if zone then
		local cx, cz = Zone.center(zone)
		local ex, ez = enemyDirectionRef(cx, cz)
		rx, rz = Zone.edgeToward(zone, ex, ez, 250)
	else
		rx, rz = Engine.squads.rally(hx, hz, Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2)
		-- raids keep coming from one side: wait on that approach, at the base's edge
		local ax, az = Engine.approachDir()
		if ax then
			rx, rz = (rx + hx + ax * 1100) * 0.5, (rz + hz + az * 1100) * 0.5
		end
		-- forward firebases (doctrine.firebase): the army waits just behind the furthest one that has two
		-- turrets standing; it pushes from there and falls back onto it
		if Engine.D.firebase.on and Engine.enemyX then
			local ex, ez = Engine.enemyX - hx, Engine.enemyZ - hz
			local best
			for _, b in ipairs(Engine.firebases) do
				local have = Engine.firebaseHave(b)
				local turrets = (have.light or 0) + (have.heavy or 0) + (have.long or 0)
				local fwd = (b.x - hx) * ex + (b.z - hz) * ez
				if turrets >= 2 and (not best or fwd > best.fwd) then
					best = { x = b.x, z = b.z, fwd = fwd }
				end
			end
			if best then
				local len = max(sqrt(ex * ex + ez * ez), 1)
				rx, rz = best.x - ex / len * 200, best.z - ez / len * 200
			end
		end
	end
	local tm = Engine.tm
	if tm.threat(rx, rz) > tm.influence(rx, rz) then
		local sx, sz = tm.safePoint(rx, rz, hx, hz)
		if sx then
			rx, rz = sx, sz
		end
	end
	return clampToMap(rx, rz)
end

-- our turrets' value around (x, z): they fight on our side when the army defends there
local function turretSupport(x, z, r)
	local v = 0
	for _, u in ipairs(spGetUnitsInCylinder(x, z, r)) do
		local ud = unitDef(u)
		if ud and ud.staticDef and not ud.aaOnly and spGetUnitTeam(u) == myTeam and not spGetUnitIsBeingBuilt(u) then
			v = v + ud.cost
		end
	end
	return v
end

-- full autonomy: what the army goes for on its own, among what it beats (doctrine.engage.attack):
-- their factories and economy (what wins games) and their armed groups (threat map memory)
Const.ATTACK_PREFER = { artillery = 4, factory = 3, extractor = 1.5, generator = 1.2, constructor = 1, radar = 1, structure = 1, army = 0.6 }

function Tactics.attackTarget(sub, sq)
	local cands = Engine.raidCandidates(true)
	for _, g in ipairs(Engine.tm.groups(frame, 8)) do
		cands[#cands + 1] = { id = "group:" .. floor(g.x / 512) .. ":" .. floor(g.z / 512), x = g.x, z = g.z, value = g.power, kind = "army", name = sformat("%d metal", g.power) }
	end
	local t = Engine.squads.pickTarget(sq, cands, frame, { prefer = Const.ATTACK_PREFER })
	if t then
		return { id = t.id, x = t.x, z = t.z, name = "enemy " .. t.kind .. " (" .. t.name .. ")" }
	end
end

local ACTION_TEXT = {
	engage = "engaging %s (%.1fx their strength)",
	regroup = "regrouping before %s (%.1fx)",
	hold = "holding: %s is too strong here (%.1fx)",
	fallback = "falling back from %s (%.1fx)",
}

-- raids: is this an Army with Raids on (the default)?
function Engine.raiding(sub)
	-- raids pause while the base is under attack (the team plan): every unit is needed at home
	return sub.role == "army" and sub.raids ~= false and not Engine.team.plan.base
end

-- what a raid can go for: enemy structures we know (not their defences) and constructors seen lately
-- withBase: the army's attack (not raids or air strikes) also gets their start as "their base" when no
-- factory of theirs is known
function Engine.raidCandidates(withBase)
	local list = {}
	for u, e in pairs(Enemy.units) do
		local d = defs[e.defID]
		local age = frame - e.last
		local kind
		if not d.mobile then
			-- factories stay targets until seen gone (doctrine.engage.finish): late in a game we often hadn't
			-- seen their base in 10 minutes, and a 115k army had nothing there to go for (timed out vs medium)
			local F = Engine.D.engage.finish
			if (age < 30 * 600 or (F and d.factory)) and not d.staticDef then
				-- their long-range cannons and nuke silos: what the army and the strikes go for first
				kind = ((d.lrpc or d.nukeSilo) and "artillery") or (d.mex > 0 and "extractor") or (d.energy > 0 and "generator") or (d.factory and "factory") or (d.intelStructure and "radar") or "structure"
			end
		elseif d.builder and not d.commander and age < 30 * 20 then
			kind = "constructor"
		end
		if kind then
			list[#list + 1] = { id = u, x = e.x, z = e.z, value = max(d.cost, 30), kind = kind, name = d.human }
		end
	end
	-- no factory of theirs known: their start position stands for their base (doctrine.engage.finish)
	local F = Engine.D.engage.finish
	if withBase and F and Engine.enemyX then
		local haveFactory = false
		for _, c in ipairs(list) do
			haveFactory = haveFactory or c.kind == "factory"
		end
		if not haveFactory then
			list[#list + 1] = { id = "theirbase", x = Engine.enemyX, z = Engine.enemyZ, value = F.baseValue, kind = "factory", name = "their base" }
		end
	end
	return list
end

-- scouting: the nearest metal spot on the enemy's side that nobody of ours has seen lately
function Engine.explorePoint(x, z)
	local spots = metalSpots()
	if not spots or not Engine.homeX then
		return nil
	end
	Engine.visited = Engine.visited or {}
	local ex, ez = Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2
	-- their base first, while we know none of their factories: that's what an attack needs to find
	local knowFactory = false
	for _, e in pairs(Enemy.units) do
		knowFactory = knowFactory or defs[e.defID].factory
	end
	if not knowFactory then
		for _, st in ipairs(getEnemyStarts()) do
			if frame - (Engine.visited.base or -99999) > Engine.D.raid.revisit and not Spring.IsPosInLos(st.x, 0, st.z, myAlly) then
				if dist2(x, z, st.x, st.z) < 600 * 600 then
					Engine.visited.base = frame
				else
					return st, "base"
				end
			end
		end
	end
	local best, bestD
	for i, sp in ipairs(spots) do
		if dist2(sp.x, sp.z, ex, ez) < dist2(sp.x, sp.z, Engine.homeX, Engine.homeZ) and frame - (Engine.visited[i] or -99999) > Engine.D.raid.revisit
			and not Spring.IsPosInLos(sp.x, 0, sp.z, myAlly) then
			local dd = dist2(x, z, sp.x, sp.z)
			if not bestD or dd < bestD then
				best, bestD = i, dd
			end
		end
	end
	return best and spots[best], best
end

-- the raid squad, once per combat pass: who's in it, where it goes, and when it comes home
function Tactics.raid(sub)
	if not Engine.raiding(sub) then
		sub.raidOrder, sub.raidSquad = nil, nil
		for u in pairs(sub.units) do
			if ustate[u] then
				ustate[u].raid = nil
			end
		end
		return
	end
	local R = Engine.D.raid
	local raiders = {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if st then
			st.raid = nil
		end
		local cloaker = Engine.D.cloak and Engine.D.cloak.raid and d and d.canCloak and d.armed and d.mobile and not d.builder and not d.commander
		if d and (cloaker or Engine.micro.raids(Engine.prod.category(d), Engine.armyStyleNow)) and not spGetUnitIsBeingBuilt(u) and not (st and (st.retreating or st.manual)) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				raiders[#raiders + 1] = { id = u, x = x, z = z, cost = d.cost }
			end
		end
	end
	local members, power = {}, 0
	local raidMax = R.max * (Engine.micro.style(Engine.armyStyleNow).raidMax or 1)
	for _, m in ipairs(raiders) do
		if power + m.cost <= raidMax then
			members[#members + 1] = m
			power = power + m.cost
		end
	end
	if power < R.min then
		-- not enough to go out yet: they stay with the army
		sub.raidOrder, sub.raidSquad = nil, nil
		return
	end
	for _, m in ipairs(members) do
		getState(m.id).raid = true
	end
	local S = Engine.squads
	local rs = S.summarize(members)
	sub.raidSquad = rs
	-- scouting: spots our raid has seen
	local spots = metalSpots()
	if spots then
		Engine.visited = Engine.visited or {}
		for i, sp in ipairs(spots) do
			if dist2(rs.x, rs.z, sp.x, sp.z) < 500 * 500 then
				Engine.visited[i] = frame
			end
		end
	end
	local prev = sub.raidOrder
	local action, tx, tz, name, id
	if prev and prev.action ~= "retreat" and S.ratio(rs, rs.x, rs.z, frame) < Engine.D.engage.hold then
		action, tx, tz, name, id = "retreat", sub.rallyX or Engine.homeX, sub.rallyZ or Engine.homeZ, "home", "home"
	elseif prev and prev.action == "retreat" and dist2(rs.x, rs.z, prev.x, prev.z) > 600 * 600 then
		return -- still on the way home
	else
		local t = S.pickTarget(rs, Engine.raidCandidates(), frame, { need = R.need, prefer = R.prefer })
		if t then
			action, tx, tz, name, id = "raid", t.x, t.z, "enemy " .. t.kind .. " (" .. t.name .. ")", t.id
		else
			local sp, i = Engine.explorePoint(rs.x, rs.z)
			if sp then
				action, tx, tz, name, id = "explore", sp.x, sp.z, i == "base" and "their base" or "metal spot", "spot:" .. i
			end
		end
	end
	if not action then
		sub.raidOrder = nil
		return
	end
	if prev and prev.id == id and prev.action == action and frame - prev.frame < R.reroute then
		return
	end
	local route = Engine.path.route(rs.x, rs.z, tx, tz, { avoid = 8 })
	sub.raidOrder = { action = action, id = id, x = tx, z = tz, route = route, frame = frame, seq = ((prev and prev.seq) or 0) + 1 }
	if not prev or prev.id ~= id or prev.action ~= action then
		log(sub, sformat("raid: %s %s at %d,%d", action == "raid" and "going for" or (action == "explore" and "scouting" or "pulling back"), name, tx, tz))
	end
end

-- the Air Force (sc_air.lua), each combat pass: one order per wing (fighters, gunships, strike), read by
-- each plane in Tactics.airUnit
function Tactics.air(sub)
	if sub.role ~= "air" or not Engine.homeX then
		return
	end
	local A, P, tm = Engine.air, Engine.D.air, Engine.tm
	local hx, hz = Engine.homeX, Engine.homeZ
	local wings = { fighter = { power = 0, n = 0, x = 0, z = 0 }, gunship = { power = 0, n = 0, x = 0, z = 0 }, bomber = { power = 0, n = 0, x = 0, z = 0 } }
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local c = A.class(d)
		local st = ustate[u]
		if wings[c] and not spGetUnitIsBeingBuilt(u) and not (st and (st.airRepair or st.manual)) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				local w = wings[c]
				w.power, w.n, w.x, w.z = w.power + d.cost, w.n + 1, w.x + x, w.z + z
			end
		end
	end
	for _, w in pairs(wings) do
		if w.n > 0 then
			w.x, w.z = w.x / w.n, w.z / w.n
		end
	end
	local function aaAt(x, z)
		return tm.enemyPower(x, z, P.aaRadius, frame, { air = true, aaOnly = true })
	end
	local prevs = sub.airOrders or {}
	local orders = {}
	local function set(key, o)
		local p = prevs[key]
		if p and p.action == o.action and p.id == o.id then
			o.seq, o.frame, o.route = p.seq, p.frame, p.route
		else
			o.seq, o.frame = ((p and p.seq) or 0) + 1, frame
			if o.action ~= "cover" and o.action ~= "home" then
				log(sub, sformat("%s: %s at %d,%d", key, o.text, o.x, o.z))
			end
		end
		orders[key] = o
	end
	-- the army's centre: what the fighters cover besides home
	local army = Engine.anyArmy()
	local ax, az = hx, hz
	if army and army.squad and army.squad.x then
		ax, az = army.squad.x, army.squad.z
	end
	-- cover areas: zones the player (or strategist) drew for the Air Force, and open "cover" requests
	-- (an ally's base, an area another sub-commander asked air cover for): fighters intercept their
	-- aircraft there, gunships hunt raiders there, idle fighters patrol the first one
	local covers = {}
	if not sub.autoZones then
		for _, zone in ipairs(sub.zones) do
			local cx, cz = Zone.center(zone)
			covers[#covers + 1] = { x = cx, z = cz, r = max(800, sqrt(Zone.area(zone) / pi)) }
		end
	end
	for _, r in ipairs(Engine.team.open("cover")) do
		if r.x then
			covers[#covers + 1] = { x = r.x, z = r.z, r = r.radius or 1200 }
		end
	end
	local function inCover(x, z, extra)
		for _, c in ipairs(covers) do
			if dist2(x, z, c.x, c.z) <= (c.r + (extra or 0)) ^ 2 then
				return true
			end
		end
		return false
	end
	sub.coverAreas = covers
	-- gunships: the biggest raiding party near home or in a cover area they beat, out of their anti-air
	local gw = wings.gunship
	local hunt
	if gw.n > 0 then
		local groups = {}
		for _, g in ipairs(tm.groups(frame, 10)) do
			if g.static < g.power * 0.3 and (g.lastSeenSec or 0) < 20 and (sqrt(dist2(g.x, g.z, hx, hz)) < P.huntRange or Engine.inBase(g.x, g.z) or inCover(g.x, g.z)) then
				groups[#groups + 1] = { x = g.x, z = g.z, power = g.power - g.static }
			end
		end
		hunt = A.hunt(groups, aaAt, gw.power)
		if hunt then
			set("gunship", { action = "hunt", id = "hunt:" .. floor(hunt.x / 512) .. ":" .. floor(hunt.z / 512), x = hunt.x, z = hunt.z, power = gw.power, text = sformat("hunting a raiding party (%d metal)", hunt.power) })
		end
	end
	-- strike: bombers, and gunships with nothing to hunt
	local sw = { power = wings.bomber.power, n = wings.bomber.n, x = wings.bomber.x * wings.bomber.n, z = wings.bomber.z * wings.bomber.n }
	if not hunt and gw.n > 0 then
		sw.power, sw.n, sw.x, sw.z = sw.power + gw.power, sw.n + gw.n, sw.x + gw.x * gw.n, sw.z + gw.z * gw.n
	end
	sub.strikeWithGunships = not hunt
	if sw.n > 0 then
		sw.x, sw.z = sw.x / sw.n, sw.z / sw.n
	end
	local prev = prevs.strike
	local strike
	if sw.n > 0 and (sw.power >= P.strikeMin or (prev and prev.action == "strike")) then
		if prev and prev.action == "strike" and sw.power >= prev.power * 0.5 and Enemy.units[prev.id] and frame - prev.frame < P.reroute * 3 then
			strike = prev
		elseif not (prev and prev.action == "strike" and sw.power < prev.power * 0.5) and sw.power >= P.strikeMin then
			local cands = Engine.raidCandidates()
			for u, e in pairs(Enemy.units) do
				local ed = defs[e.defID]
				if ed and ed.aaOnly and frame - e.last < 30 * 120 then
					cands[#cands + 1] = { id = u, x = e.x, z = e.z, value = max(ed.cost, 30), kind = "anti-air", name = ed.human, aa = true }
				end
			end
			local t = A.strike(cands, aaAt, sw)
			if t then
				strike = { action = "strike", id = t.id, x = t.x, z = t.z, power = sw.power, text = sformat("strike on %s %s", t.aa and "their anti-air," or ("enemy " .. t.kind), t.name or "") }
			end
		end
	end
	if strike then
		set("strike", strike)
		if not orders.strike.route then
			orders.strike.route = Engine.path.route(sw.x, sw.z, strike.x, strike.z, { layer = "air", avoid = 8 })
		end
	else
		local sx, sz = tm.safePoint(hx, hz, hx, hz, "air")
		set("strike", { action = "home", id = "home", x = sx or hx, z = sz or hz, text = "home" })
	end
	if not hunt then
		orders.gunship = nil
	end
	-- fighters: enemy aircraft near home or the army first, else escort a strike, else cover the army
	local fw = wings.fighter
	if fw.n > 0 then
		local best, bestD
		for u, e in pairs(Enemy.units) do
			local ed = defs[e.defID]
			if ed and ed.air and frame - e.last < 30 * 10 then
				local dd = min(sqrt(dist2(e.x, e.z, hx, hz)), sqrt(dist2(e.x, e.z, ax, az)))
				if inCover(e.x, e.z, P.coverRange * 0.5) then
					dd = 0 -- over an area we were asked to cover: first
				end
				if dd < P.coverRange and (not bestD or dd < bestD) then
					best, bestD = { id = u, x = e.x, z = e.z, name = ed.human }, dd
				end
			end
		end
		if best then
			set("fighter", { action = "intercept", id = "air:" .. floor(best.x / 512) .. ":" .. floor(best.z / 512), x = best.x, z = best.z, text = "intercepting " .. best.name })
		elseif strike then
			set("fighter", { action = "escort", id = "escort:" .. tostring(strike.id), x = strike.x, z = strike.z, text = "escorting the strike" })
		elseif covers[1] then
			set("fighter", { action = "cover", id = "cover:area", x = covers[1].x, z = covers[1].z, text = "covering the area we were asked to" })
		else
			set("fighter", { action = "cover", id = "cover", x = (hx + ax) * 0.5, z = (hz + az) * 0.5, text = "covering the base and army" })
		end
	end
	sub.airOrders = orders
end

-- one plane of the Air Force: home to repair when hurt, scouts look at the enemy's side, the others follow
-- their wing's order (Tactics.air)
function Tactics.airUnit(sub, unitID, d, st)
	local x, _, z = spGetUnitPosition(unitID)
	if not x or not Engine.homeX then
		return
	end
	local P = Engine.D.air
	local busy = (spGetUnitCommandCount(unitID) or 0) > 0
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	local f = (hp and maxHp and maxHp > 0) and hp / maxHp or 1
	if st.airRepair and f > 0.9 then
		st.airRepair = nil
	elseif not st.airRepair and f < P.retreat then
		st.airRepair = true
		local sx, sz = Engine.tm.safePoint(Engine.homeX, Engine.homeZ, Engine.homeX, Engine.homeZ, "air")
		order(unitID, CMD.MOVE, { sx or Engine.homeX, 0, sz or Engine.homeZ })
		st.airSeq = nil
		setTask(unitID, "repair", "flying home to repair", true)
		return
	end
	if st.airRepair then
		return
	end
	local class = Engine.air.class(d)
	if class == "scout" then
		if not busy then
			local sp = Engine.explorePoint(x, z)
			if sp then
				local route = Engine.path.route(x, z, sp.x, sp.z, { layer = "air", avoid = 8 })
				for i, w in ipairs(route) do
					order(unitID, CMD.MOVE, { w.x, 0, w.z }, i > 1 and { "shift" } or nil)
				end
				setTask(unitID, "scout", "scouting the enemy's side", true)
			end
		end
		return
	end
	local key = (class == "gunship" and sub.strikeWithGunships) and "strike" or (class == "bomber" and "strike" or class)
	local o = sub.airOrders and sub.airOrders[key]
	if not o then
		return
	end
	if st.airSeq == o.seq and busy then
		return
	end
	st.airSeq = o.seq
	if o.action == "cover" then
		order(unitID, CMD.PATROL, { o.x, spGetGroundHeight(o.x, o.z), o.z })
		setTask(unitID, "cover", "covering the base and army", true)
		return
	end
	if o.action == "home" then
		order(unitID, CMD.MOVE, { o.x, 0, o.z })
		setTask(unitID, "home", "waiting at home", true)
		return
	end
	local route = o.route or { { x = o.x, z = o.z } }
	for i = 1, #route - 1 do
		order(unitID, CMD.MOVE, { route[i].x, 0, route[i].z }, i > 1 and { "shift" } or nil)
	end
	local last = route[#route]
	if class == "bomber" and o.action == "strike" then
		-- bombers drop only on what they're told to: a fight-move flies over undefended structures without
		-- a bomb (lab: two minutes over solar collectors, nothing hit). Area attack, as players bomb
		order(unitID, CMD.AREA_ATTACK, { last.x, spGetGroundHeight(last.x, last.z), last.z, P.bombRadius }, #route > 1 and { "shift" } or nil)
	else
		order(unitID, CMD.FIGHT, { last.x, spGetGroundHeight(last.x, last.z), last.z }, #route > 1 and { "shift" } or nil)
	end
	setTask(unitID, o.action, o.text or o.action, true)
end

-- air raids (doctrine.airRaid): the Army's bombers and gunships gather at home as one wing, then strike
-- what the enemy left without anti-air (extractors, generators, constructors, factories), and come home
-- when the wing is down to half
function Tactics.airRaid(sub)
	if sub.role ~= "army" or not Engine.homeX then
		return
	end
	local A = Engine.D.airRaid
	local wing, power, sx, sz = {}, 0, 0, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if st then
			st.airRaid = nil
		end
		if d and d.air and d.combat and not d.aaOnly and not spGetUnitIsBeingBuilt(u) and not (st and (st.retreating or st.manual)) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				wing[#wing + 1] = u
				power, sx, sz = power + d.cost, sx + x, sz + z
			end
		end
	end
	local prev = sub.airOrder
	if #wing == 0 or (power < A.min and not (prev and prev.action == "strike")) then
		sub.airOrder = nil
		return
	end
	for _, u in ipairs(wing) do
		getState(u).airRaid = true
	end
	local cx, cz = sx / #wing, sz / #wing
	local action, tx, tz, id, name
	if prev and prev.action == "strike" then
		if power < prev.power * 0.5 then
			action, id, name = "home", "home", "the wing took losses"
		elseif Enemy.units[prev.id] and frame - prev.frame < A.reroute * 3 then
			return
		end
	end
	if not action and power >= A.min then
		local best, bestScore
		for _, t in ipairs(Engine.raidCandidates()) do
			local aa = Engine.tm.enemyPower(t.x, t.z, A.aaRadius, frame, { air = true, aaOnly = true })
			if power >= A.need * aa then
				local score = t.value / (1 + aa / 100) / (1 + sqrt(dist2(cx, cz, t.x, t.z)) / 3000)
				if not bestScore or score > bestScore then
					best, bestScore = t, score
				end
			end
		end
		if best then
			action, tx, tz, id, name = "strike", best.x, best.z, best.id, "enemy " .. best.kind .. " (" .. best.name .. ")"
		end
	end
	if not action then
		action, id, name = "home", "home", "nothing safe to hit"
	end
	if action == "home" then
		tx, tz = Engine.tm.safePoint(Engine.homeX, Engine.homeZ, Engine.homeX, Engine.homeZ)
		tx, tz = tx or Engine.homeX, tz or Engine.homeZ
	end
	if prev and prev.id == id and prev.action == action then
		return
	end
	sub.airOrder = { action = action, id = id, x = tx, z = tz, frame = frame, power = power, seq = ((prev and prev.seq) or 0) + 1 }
	log(sub, action == "strike" and sformat("air raid: %d planes going for %s at %d,%d", #wing, name, tx, tz) or ("air wing home: " .. name))
end

-- the response squad (doctrine.responders): the Army's fastest units, up to a share of its power, wait at
-- the centre of the base and intercept intruders anywhere in it (factories and the commander first); the
-- main army keeps the front
function Tactics.responders(sub)
	sub.responseOrder, sub.respSquad = nil, nil
	if sub.role ~= "army" or not Engine.homeX then
		return
	end
	local R = Engine.D.responders
	local cands = {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if st then
			st.responder = nil
		end
		if d and d.combat and not d.aaOnly and not d.air and (d.speed or 0) >= R.speed and not spGetUnitIsBeingBuilt(u)
			and not (st and (st.retreating or st.manual or st.raid)) then
			local x, _, z = spGetUnitPosition(u)
			-- from anywhere, not only units at home: v29 (only home units) won battles but lost expansions
			-- (extractors at 20 min 25.5 -> 16.9): the army waits outside the base, so no squad formed
			if x then
				cands[#cands + 1] = { id = u, x = x, z = z, cost = d.cost, speed = d.speed }
			end
		end
	end
	tsort(cands, function(a, b)
		return a.speed > b.speed
	end)
	local limit = R.share * (sub.counts.power or 0) * (Engine.team.plan.phase == "defend" and Engine.D.team.defendResponders or 1)
	local members, power = {}, 0
	for _, m in ipairs(cands) do
		if power + m.cost <= limit then
			members[#members + 1] = m
			power = power + m.cost
		end
	end
	if power < R.min then
		return
	end
	for _, m in ipairs(members) do
		getState(m.id).responder = true
	end
	local S = Engine.squads
	local rs = S.summarize(members)
	sub.respSquad = rs
	local best, bestD
	for _, list in ipairs({ sub.threats, baseThreats }) do
		for _, t in ipairs(list) do
			if not t.air and Engine.inBase(t.x, t.z) then
				local dd = sqrt(dist2(rs.x, rs.z, t.x, t.z)) - (Engine.nearVital(t.x, t.z) and 2500 or 0)
				if not bestD or dd < bestD then
					best, bestD = t, dd
				end
			end
		end
	end
	if best then
		local action, ratio = S.decide(rs, best.x, best.z, frame, { home = true, support = turretSupport(best.x, best.z, 700) })
		if action == "engage" then
			if sub.lastResponse ~= best.id then
				sub.lastResponse = best.id
				log(sub, sformat("response squad: intercepting a raid at %d,%d (%.1fx)", best.x, best.z, ratio))
			end
			sub.responseOrder = { action = "engage", id = best.id, x = best.x, z = best.z, ratio = ratio }
			return
		end
	end
	-- waiting: the centre of the base, out of known enemy reach
	local hx, hz = Engine.homeX, Engine.homeZ
	local sx, sz = Engine.tm.safePoint(hx, hz, hx, hz)
	sub.responseOrder = { action = "wait", x = sx or hx, z = sz or hz }
end

-- the team's plan and requests (sc_team.lua), once per combat pass: the phase from the game's state, and
-- the requests sub-commanders post for each other
function Engine.refreshTeam()
	local team = Engine.team
	team.expire(frame)
	local E = Engine.D.economy
	local enemyArmy, inBase = 0, 0
	for _, g in ipairs(Engine.tm.groups(frame, 8)) do
		local mobile = g.power - g.static
		enemyArmy = max(enemyArmy, mobile)
		if Engine.homeX and Engine.inBase(g.x, g.z) then
			inBase = inBase + mobile
		end
	end
	local income = max(econ.mInc, 0)
	local prev = team.plan.phase
	Engine.enemyArmy = enemyArmy -- the strongest known enemy group (metal): firebases scale their creep by it
	local plan = team.phase({
		minute = Engine.minute(), income = income, armyPower = Engine.armyValue or 0, enemyArmy = enemyArmy,
		baseUnderAttack = inBase, techLab = Engine.haveTechLab(), frame = frame,
		techReady = income >= E.t2Income or (frame >= 30 * 60 * E.t2Minute and income >= E.t2MinIncome),
	})
	if plan.phase ~= prev then
		for _, sub in ipairs(subs) do
			log(sub, sformat("team plan: %s (%s)", plan.phase, plan.why))
		end
	end
	-- requests: an area whose intruders outgun our firepower there asks for help
	for _, sub in ipairs(subs) do
		if sub.role ~= "army" and #sub.threats > 0 then
			local t = sub.threats[1]
			local theirs = Engine.tm.enemyPower(t.x, t.z, 700, frame)
			local ours = Engine.tm.influence(t.x, t.z)
			-- their aircraft over a sub-commander's area: it asks the Air Force for cover there
			if t.air and sub.role ~= "air" then
				team.post({ kind = "cover", from = sub.id, x = t.x, z = t.z, radius = 1200, note = sub.name .. " has enemy aircraft overhead" }, frame)
			end
			if theirs > ours and not t.air then
				team.post({ kind = "defend", from = sub.id, x = t.x, z = t.z, need = floor(theirs - ours), note = sub.name .. " is outgunned" }, frame)
			end
		end
		-- a defending sub-commander without constructors asks for one (after the opening); with a big
		-- economy for a tier 2 one (harder turrets, doctrine.escalation)
		if (sub.role == "defense" or sub.role == "air") and not sub.paused then
			local X = Engine.D.escalation
			local t2 = (sub.role == "defense" and X.t2DefenseIncome) or Engine.D.air.t2Income
			if sub.counts.builders == 0 and Engine.minute() >= 4 then
				team.post({ kind = "constructor", from = sub.id, need = 1, note = sub.name .. " has no constructors" }, frame)
			elseif income >= t2 and not Engine.hasT2Builder(sub) then
				team.post({ kind = "constructor", from = sub.id, tier = 2, need = 1, note = sub.name .. " wants tier 2 defences" }, frame)
			end
		end
		-- an army a known enemy army outweighs asks for combat production
		if sub.role == "army" and enemyArmy > (sub.counts.power or 0) * Engine.D.team.defendRatio then
			team.post({ kind = "production", from = sub.id, need = floor(enemyArmy - (sub.counts.power or 0)), note = "their army outweighs " .. sub.name }, frame)
		end
	end
end

-- the army's style (sc_micro.lua): the player's or strategist's choice, or with `auto` from the team plan
-- and what both sides field (held doctrine.micro.auto.hold frames)
function Engine.refreshStyle()
	local want, why = Engine.armyStyle, "chosen"
	if want == "auto" then
		local power, static = 0, 0
		for _, g in ipairs(Engine.tm.groups(frame, 10)) do
			power, static = power + g.power, static + g.static
		end
		local k = Enemy.mix().kinds
		local mobile = 0
		for kind, n in pairs(k) do
			if kind ~= "turret" and kind ~= "anti-air turret" then
				mobile = mobile + n
			end
		end
		local army = Engine.anyArmy()
		local cp = army and army.counts.catPower or {}
		local ourPower = army and army.counts.power or 0
		want, why = Engine.micro.auto({
			phase = Engine.team.plan.phase,
			enemyStatic = power > 0 and static / power or 0,
			enemyFront = mobile > 0 and ((k.heavy or 0) + (k.assault or 0) + (k["hover assault"] or 0)) / mobile or 0,
			ourRanged = ourPower > 0 and ((cp.skirmisher or 0) + (cp.artillery or 0)) / ourPower or 0,
		})
		if want ~= Engine.armyStyleNow and frame - Engine.armyStyleSince < Engine.D.micro.auto.hold and want ~= "hold" then
			return
		end
	end
	if want ~= Engine.armyStyleNow then
		Engine.armyStyleNow, Engine.armyStyleSince = want, frame
		for _, s in ipairs(subs) do
			if s.role == "army" then
				log(s, sformat("army style: %s (%s)", Engine.micro.style(want).label, why))
			end
		end
	end
end

function Engine.setArmyStyle(name)
	if name ~= "auto" and not Engine.D.micro.styles[name] then
		return false
	end
	Engine.armyStyle = name
	Engine.armyStyleSince = -99999
	Engine.refreshStyle()
	return true
end

-- one unit of the Army in a fight, by its kind's doctrine under the army style (sc_micro.lua): siege
-- units shoot structures in range first, ranged units keep their range from what they outrange. Returns
-- true when it gave the unit an order.
-- kiting (sc_micro.lua kite): a unit that outranges the nearest enemy and lets it come within its kite
-- distance backs off to where it fights from. Returns true when it took the unit this pass.
function Tactics.kite(unitID, d, st, x, z, rule)
	rule = rule or Engine.micro.rule(d.kind, Engine.armyStyleNow)
	local range = d.range or 0
	if not rule.kite or range <= 0 then
		return false
	end
	local e = Spring.GetUnitNearestEnemy(unitID, range, true)
	local ex, _, ez
	if e then
		ex, _, ez = spGetUnitPosition(e)
	end
	if not ex then
		return false
	end
	local ed = unitDef(e)
	local dd = sqrt(dist2(x, z, ex, ez))
	local back = Engine.micro.kite(rule, range, dd, ed and ed.range)
	if not back then
		return false
	end
	local dx, dz = x - ex, z - ez
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local tx, tz = clampToMap(x + dx / len * (back - dd), z + dz / len * (back - dd))
	order(unitID, CMD.MOVE, { tx, spGetGroundHeight(tx, tz), tz })
	st.kiteUntil, st.engaged = frame + 30, nil
	setTask(unitID, "kite", "keeping its range", true)
	return true
end

function Tactics.micro(unitID, d, st, x, z)
	if st.kiteUntil and frame < st.kiteUntil then
		return true
	end
	local rule = Engine.micro.rule(d.kind, Engine.armyStyleNow)
	local range = d.range or 0
	if rule.siege and range > 0 then
		local best, bestScore
		for _, u in ipairs(spGetUnitsInCylinder(x, z, range)) do
			if isEnemyUnit(u) then
				local ud = unitDef(u)
				if ud and not ud.mobile then
					-- turrets first (they shoot back), then what their economy runs on
					local score = ud.cost * (ud.staticDef and 3 or 1)
					if not bestScore or score > bestScore then
						best, bestScore = u, score
					end
				end
			end
		end
		if best then
			if st.sieging ~= best or (spGetUnitCommandCount(unitID) or 0) == 0 then
				order(unitID, CMD.ATTACK, { best })
				st.sieging, st.engaged = best, nil
				setTask(unitID, "siege", "shelling " .. (unitDef(best) and unitDef(best).human or "a structure"), true)
			end
			return true
		end
		st.sieging = nil
	end
	if Tactics.kite(unitID, d, st, x, z, rule) then
		return true
	end
	-- focus fire (sc_micro.lua): every unit in reach of the same enemies converges on the one worth most
	-- per hit point left, armed ones first
	local F = Engine.D.micro.focus
	if F.on and F.mode == "attack" and rule.focus ~= false and range > 0 and (not st.focusUntil or frame >= st.focusUntil or not isAlive(st.focus or -1)) then
		local cands = {}
		for _, u in ipairs(spGetUnitsInCylinder(x, z, range)) do
			if isEnemyUnit(u) then
				local ud = unitDef(u)
				local hp = Spring.GetUnitHealth(u)
				-- what it can hit: planes for anti-air, the ground for the rest (most ground guns can't aim up)
				if ud and hp and (ud.armed or ud.mex > 0 or ud.builder) and (ud.air == (d.aaOnly or false)) then
					cands[#cands + 1] = { id = u, hp = hp, cost = ud.cost, armed = ud.armed and not ud.aaOnly }
				end
			end
		end
		local t = Engine.micro.focusTarget(cands)
		if t then
			order(unitID, CMD.ATTACK, { t.id })
			st.focus, st.focusUntil, st.engaged = t.id, frame + F.every, nil
			setTask(unitID, "focus", "focus fire", true)
			return true
		end
		st.focus = nil
	elseif F.on and F.mode == "attack" and st.focus and frame < st.focusUntil then
		return true
	end
	return false
end

-- fire control (sc_micro.lua allocate), every doctrine.micro.focus.fireEvery frames: each army unit gets
-- a priority target with BAR's set-target command (unit_target_on_the_move: used when in range, kept
-- through move orders), so units keep fighting, rallying, kiting or falling back while they shoot it.
Engine.CMD_SET_TARGET = (GameCMD and GameCMD.UNIT_SET_TARGET) or 34923
Engine.CMD_WANT_CLOAK = (GameCMD and GameCMD.WANT_CLOAK) or 37382
Engine.CMD_CANCEL_TARGET = (GameCMD and GameCMD.UNIT_CANCEL_TARGET) or 34924

function Engine.fireControl(sub)
	if sub.role ~= "army" then
		return
	end
	local shooters, targets, seen = {}, {}, {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if d and d.combat and not d.air and (d.range or 0) > 0 and not spGetUnitIsBeingBuilt(u) and not (st and (st.manual or st.sieging)) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				shooters[#shooters + 1] = { id = u, x = x, z = z, range = d.range, dps = (d.aaOnly and d.airDps or d.groundDps) or 0, aa = d.aaOnly or false }
				for _, e in ipairs(spGetUnitsInCylinder(x, z, d.range + 100)) do
					if not seen[e] and isEnemyUnit(e) then
						seen[e] = true
						local ud = unitDef(e)
						local hp = Spring.GetUnitHealth(e)
						local ex, _, ez = spGetUnitPosition(e)
						if ud and hp and ex and (ud.armed or ud.mex > 0 or ud.builder) then
							targets[#targets + 1] = { id = e, x = ex, z = ez, hp = hp, cost = ud.cost, armed = ud.armed and not ud.aaOnly,
								air = ud.air or false, radius = Spring.GetUnitRadius(e) or 0 }
						end
					end
				end
			end
		end
	end
	if #targets == 0 then
		return
	end
	local plan = Engine.micro.allocate(shooters, targets)
	for _, s in ipairs(shooters) do
		local t = plan[s.id]
		-- what the gadget holds (a stop order clears it): reorder only what differs
		local cur = Spring.GetUnitRulesParam(s.id, "unitTargetID")
		if t and cur ~= t then
			order(s.id, Engine.CMD_SET_TARGET, { t })
		elseif not t and cur and cur > 0 then
			order(s.id, Engine.CMD_CANCEL_TARGET, {})
		end
	end
end

-- dodging (sc_micro.lua dodge), every doctrine.micro.dodge.every frames: enemy shells and slow
-- unguided missiles in the air over an army, where they will land, and the units that step out
Engine.projWeapon = {} -- weaponDefID -> { r = blast radius } for those worth dodging, false otherwise

function Engine.dodge(sub)
	if sub.role ~= "army" or not Spring.GetProjectilesInRectangle then
		return
	end
	local G = Engine.D.micro.dodge
	local units, x1, z1, x2, z2 = {}, nil, nil, nil, nil
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if d and d.mobile and not d.air and (d.speed or 0) > 0 and not spGetUnitIsBeingBuilt(u) and not (st and st.manual)
			and not (st and st.dodgeUntil and frame < st.dodgeUntil) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				units[#units + 1] = { id = u, x = x, z = z, speed = d.speed, radius = Spring.GetUnitRadius(u) or 0 }
				x1, z1 = min(x1 or x, x), min(z1 or z, z)
				x2, z2 = max(x2 or x, x), max(z2 or z, z)
			end
		end
	end
	if #units == 0 then
		return
	end
	local pad = 400
	local impacts = {}
	for _, p in ipairs(Spring.GetProjectilesInRectangle(x1 - pad, z1 - pad, x2 + pad, z2 + pad, false, true) or {}) do
		local wdID = Spring.GetProjectileDefID(p)
		local w = wdID and Engine.projWeapon[wdID]
		if wdID and w == nil then
			local wd = WeaponDefs[wdID]
			local r = wd and (wd.damageAreaOfEffect or 0) or 0
			w = (wd and r >= G.minBlast and not wd.tracks and not wd.beamweapon) and { r = r, gravity = (wd.myGravity and wd.myGravity > 0) and wd.myGravity or nil } or false
			Engine.projWeapon[wdID] = w
		end
		local team = w and Spring.GetProjectileTeamID(p)
		if w and team and not Spring.AreTeamsAllied(team, myTeam) then
			local px, py, pz = Spring.GetProjectilePosition(p)
			local vx, vy, vz = Spring.GetProjectileVelocity(p)
			local hs = sqrt((vx or 0) ^ 2 + (vz or 0) ^ 2)
			if px and hs > 0 and hs <= G.maxSpeed then
				-- where the shell comes down: its own arc (shots at a unit lead it, so the unit's position
				-- isn't where it lands). Frames until it falls to the ground below where it would land.
				local g = w.gravity or (Game.gravity or 120) / 900
				local gy = spGetGroundHeight(px, pz)
				local disc = vy * vy + 2 * g * (py - gy)
				local fr = disc >= 0 and (vy + sqrt(disc)) / g or nil
				if fr and fr > 0 then
					local tx, tz = px + vx * fr, pz + vz * fr
					-- once more with the ground at that point
					gy = spGetGroundHeight(tx, tz)
					disc = vy * vy + 2 * g * (py - gy)
					fr = disc >= 0 and (vy + sqrt(disc)) / g or fr
					tx, tz = px + vx * fr, pz + vz * fr
					impacts[#impacts + 1] = { x = tx, z = tz, r = w.r, t = fr / 30 }
				end
			end
		end
	end
	if #impacts == 0 then
		return
	end
	for _, u in ipairs(units) do
		local near = {}
		for _, h in ipairs(impacts) do
			if dist2(u.x, u.z, h.x, h.z) < (h.r + u.radius + G.margin) ^ 2 then
				near[#near + 1] = h
			end
		end
		if #near > 0 then
			local dx, dz = Engine.micro.dodge(u, near)
			if dx then
				dx, dz = clampToMap(dx, dz)
				local t = 0
				for _, h in ipairs(near) do
					t = max(t, h.t)
				end
				order(u.id, CMD.MOVE, { dx, spGetGroundHeight(dx, dz), dz })
				local st = getState(u.id)
				st.dodgeUntil, st.engaged, st.kiteUntil = frame + floor(t * 30) + 10, nil, nil
				st.dodges = (st.dodges or 0) + 1
				sub.dodges = (sub.dodges or 0) + 1
				setTask(u.id, "dodge", "dodging incoming fire", true)
			end
		end
	end
end

-- the commander (sc_commander.lua), each combat pass: its mode, D-gun shots, and at the front following
-- the army. Returns true when it took the commander this pass.
function Tactics.commander(sub, unitID, d, st)
	local x, _, z = spGetUnitPosition(unitID)
	if not x or not Engine.homeX then
		return false
	end
	local C = Engine.com
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	local threatNear = Engine.tm.enemyPower(x, z, 900, frame, { mobileOnly = true })
	local mode = C.mode(Engine.comMode, Engine.comPersonality, {
		phase = Engine.team.plan.phase, threatNear = threatNear,
		health = (hp and maxHp and maxHp > 0) and hp / maxHp or 1, full = sub.autonomy == "full",
	})
	if mode ~= Engine.comModeNow then
		Engine.comModeNow = mode
		log(sub, "commander: " .. mode .. (Engine.comMode == "auto" and " (auto)" or ""))
	end
	-- the D-gun: the most valuable armed enemy in reach (any mode)
	if frame - (st.dgunFrame or -99999) > Engine.D.commander.dgunCooldown then
		local enemies = {}
		for _, u in ipairs(spGetUnitsInCylinder(x, z, Engine.D.commander.dgunRange)) do
			if isEnemyUnit(u) then
				local ud = unitDef(u)
				local ex, _, ez = spGetUnitPosition(u)
				if ud and ex then
					enemies[#enemies + 1] = { id = u, x = ex, z = ez, cost = ud.cost, armed = ud.armed and not ud.aaOnly }
				end
			end
		end
		local t = C.dgunTarget(enemies, { x, z }, econ.e, Engine.comPersonality)
		local dgun = CMD.MANUALFIRE or CMD.DGUN
		if t and dgun then
			order(unitID, dgun, { t.id })
			st.dgunFrame, st.comBusy = frame, frame + 45
			planned[unitID] = nil
			setTask(unitID, "dgun", "commander: D-gun", true)
			return true
		end
	end
	-- at the front: behind the army's main body, never past the personality's range from home
	if mode == "frontline" then
		local army
		for _, s in ipairs(subs) do
			if s.role == "army" and s.squad and s.squad.x then
				army = s
			end
		end
		if army then
			local sq = army.squad
			local dx, dz = Engine.homeX - sq.x, Engine.homeZ - sq.z
			local len = max(sqrt(dx * dx + dz * dz), 1)
			local fx, fz = sq.x + dx / len * 350, sq.z + dz / len * 350
			if C.inRange(fx, fz, { Engine.homeX, Engine.homeZ }, Engine.comPersonality) and dist2(x, z, fx, fz) > 300 * 300 then
				order(unitID, CMD.FIGHT, { fx, spGetGroundHeight(fx, fz), fz })
				st.comBusy = frame + 90
				planned[unitID] = nil
				setTask(unitID, "front", "commander: with the army", true)
				return true
			end
		end
	end
	-- defender: back into turret cover at home when it wandered off and enemies are near it or in the
	-- base (else it keeps building: pulling it home on every plan change fought its build jobs)
	if mode == "defender" and (threatNear > 0 or Engine.team.plan.base) and sqrt(dist2(x, z, Engine.homeX, Engine.homeZ)) > 1200 then
		local sx, sz = Engine.tm.safePoint(Engine.homeX, Engine.homeZ, Engine.homeX, Engine.homeZ)
		order(unitID, CMD.MOVE, { sx or Engine.homeX, spGetGroundHeight(sx or Engine.homeX, sz or Engine.homeZ), sz or Engine.homeZ })
		st.comBusy = frame + 60
		planned[unitID] = nil
		setTask(unitID, "home", "commander: back home to defend", true)
		return true
	end
	return false
end

-- the army as one squad (sc_squads.lua), once per combat pass: where its main body is, what it goes for,
-- and whether to engage, regroup, hold or fall back
function Tactics.squad(sub)
	if sub.role ~= "army" then
		return
	end
	local members = {}
	for u in pairs(sub.units) do
		local d = unitDef(u)
		local st = ustate[u]
		if d and d.combat and not d.aaOnly and not d.air and not spGetUnitIsBeingBuilt(u) and not (st and (st.retreating or st.manual or st.raid or st.responder)) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				members[#members + 1] = { id = u, x = x, z = z, cost = d.cost, range = d.range }
			end
		end
	end
	local S = Engine.squads
	local sq = S.summarize(members)
	sub.squad = sq
	sub.rallyX, sub.rallyZ = Tactics.rallyPoint(sub)
	if sq.power <= 0 then
		sub.squadOrder = nil
		return
	end
	local auto = Engine.auto(sub)
	-- an intruder: in our zones first, then (helping) anywhere in the base
	local target, targetD
	local function consider(list, helping)
		for _, t in ipairs(list) do
			-- helping elsewhere: not where our turrets and guards already outgun the intruders (unless a
			-- factory or the commander is in danger), nor raids in the base the response squad can handle
			local rsq = sub.respSquad
			local theirs = Engine.tm.enemyPower(t.x, t.z, 700, frame)
			local handled = rsq and Engine.inBase(t.x, t.z) and theirs < 0.8 * rsq.together
			-- pushing: a raid the main army outweighs many times is the response squad's and the turrets' job
			-- (v19's 200-unit army chased raiders at home through the whole push)
			-- (not just in a push: v23's whole army regrouped "before intruders (290.8x)")
			handled = handled or (rsq and theirs * Engine.D.escalation.overkill < sq.power)
			if not t.air and not handled and not (helping and not Engine.nearVital(t.x, t.z) and Engine.tm.influence(t.x, t.z) >= 1.5 * Engine.tm.enemyPower(t.x, t.z, 700, frame)) then
				local dd = sqrt(dist2(sq.x, sq.z, t.x, t.z))
				-- what they threaten counts more than how close they are: factories and the commander first
				if Engine.nearVital(t.x, t.z) then
					dd = dd - 2500
				end
				if dd < 4000 and (not targetD or dd < targetD) then
					target, targetD = { id = t.id, x = t.x, z = t.z, name = "intruders" }, dd
				end
			end
		end
	end
	-- an army out on an attack only turns back for what threatens a factory or the commander, or what
	-- our turrets and guards can't handle there
	-- intruders in our own area: always (v4 let an attacking army ignore them: raids wrecked the wind farms
	-- and energy collapsed); helping elsewhere is filtered (consider's second argument)
	-- pressing the advantage (doctrine.engage.dominance): an army this many times their known mobile army
	-- leaves intruders to the response squad and turrets (unless they threaten a factory or the
	-- commander) and goes for their side. Our army was 3-4x BARbarian's from minute 20 to 50 and spent it
	-- chasing their raiders at home while they took twice our extractors (fight samples v9, full view)
	local dom = Engine.D.engage.dominance
	local dominant = false
	if dom and (auto.attack or auto.push) and S.canAttack(sq) then
		local theirs = 0
		for _, g in ipairs(Engine.tm.groups(frame, 20)) do
			theirs = theirs + max(0, g.power - g.static)
		end
		dominant = sq.power >= dom * max(theirs, 1)
		-- and only with home safe (doctrine.engage.pressSafe): not while the team defends, nor while the
		-- intruders in our areas outweigh pressSafe x the response squad (Cortex lost its base and
		-- expansions to raids while its army pressed: 0 wins in 12)
		local ps = Engine.D.engage.pressSafe
		if dominant and ps and Engine.homeX then
			local intruders = Engine.tm.enemyPower(Engine.homeX, Engine.homeZ, ps.radius, frame, { mobileOnly = true })
			local resp = sub.respSquad and sub.respSquad.together or 0
			if Engine.team.plan.phase == "defend" or intruders > ps.share * max(resp, 1) then
				dominant = false
			end
		end
	end
	if dominant then
		for _, t in ipairs(sub.threats) do
			if not t.air and Engine.nearVital(t.x, t.z) then
				target = { id = t.id, x = t.x, z = t.z, name = "intruders at a factory or the commander" }
				break
			end
		end
		if not target then
			target = Tactics.attackTarget(sub, sq)
			if target then
				target.name = target.name .. " (pressing our advantage)"
			end
		end
	end
	if not target then
		consider(sub.threats)
	end
	if not target and auto.help then
		consider(baseThreats, true)
	end
	-- the team asks: a sub-commander's area outgunned (sc_team.lua defend requests)
	if not target and auto.help then
		local r, rd = Engine.team.nearest("defend", sq.x, sq.z)
		if r and rd < 5000 and Engine.inBase(r.x, r.z) then
			target = { id = "req:" .. r.id, x = r.x, z = r.z, name = "a call for help (" .. (r.note or "defend") .. ")" }
		end
	end
	-- their artillery outranges our turrets: dive it when it's within reach of home and we beat it there
	if not target and auto.help and Engine.homeX then
		for _, g in ipairs(Engine.tm.groups(frame, 6)) do
			if (g.ranged or 0) >= g.power * 0.4 and sqrt(dist2(g.x, g.z, Engine.homeX, Engine.homeZ)) < Engine.D.engage.chase + 800
				and S.decide(sq, g.x, g.z, frame, {}) == "engage" then
				target = { id = "arty:" .. floor(g.x / 512) .. ":" .. floor(g.z / 512), x = g.x, z = g.z, name = "their artillery" }
				break
			end
		end
	end
	-- pursue: intruders we drove off that are still near home and weaker than us, before they come back
	-- from another angle
	if not target and auto.help and Engine.homeX and Engine.D.engage.chase > 0 then
		local bestD
		for _, g in ipairs(Engine.tm.groups(frame, 6)) do
			local dh = sqrt(dist2(g.x, g.z, Engine.homeX, Engine.homeZ))
			if g.static < g.power * 0.3 and dh < Engine.D.engage.chase then
				local dd = dist2(sq.x, sq.z, g.x, g.z)
				if (not bestD or dd < bestD) and S.decide(sq, g.x, g.z, frame, {}) == "engage" then
					target, bestD = { id = "chase:" .. floor(g.x / 512) .. ":" .. floor(g.z / 512), x = g.x, z = g.z, name = "retreating intruders" }, dd
				end
			end
		end
	end
	local home = target and Engine.inBase(target.x, target.z)
	-- the team plan: no pushes or attacks while defending; a push plan lets a balanced army attack too
	local phase = Engine.team.plan.phase
	if Engine.micro.style(Engine.armyStyleNow).noAttack then
		phase = "defend" -- the hold style: no pushes or attacks either
	end
	if not target and auto.push and sub.pushTarget and phase ~= "defend" then
		local p = sub.pushTarget
		target = { id = p.id, x = p.x, z = p.z, name = p.name }
	end
	if not target and (auto.attack or (auto.push and phase == "push")) and phase ~= "defend" and S.canAttack(sq) then
		target = Tactics.attackTarget(sub, sq)
	end
	local prev = sub.squadOrder
	if not target then
		sub.squadOrder = nil
		Engine.holdLine(sub, members, nil)
		return
	end
	local engaged = prev and prev.id == target.id and prev.action == "engage"
	local action, ratio = S.decide(sq, target.x, target.z, frame, { home = home, engaged = engaged, support = turretSupport(target.x, target.z, 700) })
	-- outmatched with them already on us: holding means standing where they arrive (lab, retreat specs:
	-- half the army lost in the open at 0.1x); fall back instead (doctrine.engage.contactFallback, elmos
	-- from the squad's centre that count as on us)
	local CF = Engine.D.engage.contactFallback
	if CF and action == "hold" and ratio < CF.below and dist2(sq.x, sq.z, target.x, target.z) < CF.dist * CF.dist then
		action = "fallback"
	end
	sub.squadOrder = { action = action, id = target.id, x = target.x, z = target.z, ratio = ratio }
	-- engaging as a concave: each unit's place on an arc facing the enemy (sc_squads.lua arc)
	sub.arcSlots = (action == "engage" and Engine.D.engage.arc.on) and Engine.siegeSlots(members, target, S.arc(members, target.x, target.z)) or nil
	Engine.holdLine(sub, members, action ~= "engage" and target or nil)
	if not prev or prev.action ~= action or prev.id ~= target.id then
		log(sub, sformat(ACTION_TEXT[action], target.name, ratio))
	end
end

-- our static defences (ground) within r of (x, z): { x, z (value-weighted centre), value }, nil if none
function Engine.ourTurrets(x, z, r)
	local sx, sz, v = 0, 0, 0
	for _, u in ipairs(spGetUnitsInCylinder(x, z, r, myTeam)) do
		local ud = unitDef(u)
		if ud and ud.staticDef and not ud.aaOnly and not spGetUnitIsBeingBuilt(u) then
			local ux, _, uz = spGetUnitPosition(u)
			sx, sz, v = sx + ux * ud.cost, sz + uz * ud.cost, v + ud.cost
		end
	end
	return v > 0 and { x = sx / v, z = sz / v, value = v } or nil
end

-- assault with artillery (doctrine.engage.siege): against a target under their turrets, units that
-- outrange the turrets shell them from just outside their reach and the others wait there too, until
-- the turrets near the target are down to minPower; then the normal concave
function Engine.siegeSlots(members, target, slots)
	local G = Engine.D.engage.siege
	if not G or not G.on or not slots then
		return slots
	end
	local statics, power, reach = {}, 0, 0
	for _, e in pairs(Engine.tm.enemies) do
		local ed = Engine.tm.defOf(e)
		if e.static and ed and ed.armed and not ed.aaOnly and dist2(e.x, e.z, target.x, target.z) < (Engine.D.engage.radius + 400) ^ 2 then
			statics[#statics + 1] = { x = e.x, z = e.z, range = ed.range or 0 }
			power, reach = power + ed.cost, max(reach, ed.range or 0)
		end
	end
	if power < G.minPower then
		return slots
	end
	local outranging, total = 0, 0
	for _, m in ipairs(members) do
		total = total + m.cost
		if (m.range or 0) * 0.95 >= reach + G.margin then
			outranging = outranging + m.cost
		end
	end
	if total <= 0 or outranging < total * G.outrangeShare then
		return slots -- nothing to shell them with from outside: the plain concave
	end
	for _, m in ipairs(members) do
		local p = slots[m.id]
		if p then
			-- the turret nearest the slot, and how far inside its reach (plus margin) the slot is
			local near, nd
			for _, t in ipairs(statics) do
				local d = sqrt(dist2(p.x, p.z, t.x, t.z))
				if not nd or d - t.range < nd then
					near, nd = t, d - t.range
				end
			end
			local need = G.margin - nd -- > 0: inside reach + margin
			if near and need > 0 then
				local dx, dz = p.x - near.x, p.z - near.z
				local len = max(sqrt(dx * dx + dz * dz), 1)
				slots[m.id] = { x = p.x + dx / len * need, z = p.z + dz / len * need }
			end
		end
	end
	return slots
end

-- holding: the squad's places on a line across the rally point facing the threat it holds against (or
-- the enemy's side), so more of it can shoot when they come (sc_squads.lua arc around a point
-- doctrine.engage.holdLine elmos out in front); nil when off or nowhere to face
function Engine.holdLine(sub, members, threat)
	sub.holdSlots = nil
	local D = Engine.D.engage.holdLine
	local rx, rz = sub.rallyX, sub.rallyZ
	if not D or not rx then
		return
	end
	local fx, fz = (threat and threat.x) or Engine.enemyX, (threat and threat.z) or Engine.enemyZ
	if not fx then
		return
	end
	-- with our turrets near, the line stands just in front of them (doctrine.engage.turretLine): fights
	-- under our turrets traded best for players and BARbarian (pro-micro.md)
	local T = Engine.D.engage.turretLine
	local tur = T and Engine.ourTurrets(rx, rz, T.radius)
	if tur and tur.value >= T.minValue then
		rx, rz = tur.x, tur.z
		D = T.ahead
	end
	local dx, dz = fx - rx, fz - rz
	local len = max(sqrt(dx * dx + dz * dz), 1)
	local slots = Engine.squads.arc(members, rx + dx / len * D, rz + dz / len * D)
	-- not into the reach of what outranges a line (their turrets and artillery: lab, the line walked into
	-- standing artillery and lost 84% instead of 50%): such a place moves back toward the rally point
	local far = {}
	for _, e in pairs(Engine.tm.enemies) do
		local ed = Engine.tm.defOf(e)
		if ed and ed.armed and not ed.aaOnly and not ed.air and (e.static or (ed.range or 0) >= 600) and Engine.tm.weight(e, frame) > 0 then
			far[#far + 1] = { x = e.x, z = e.z, r = (ed.range or 0) + 80 }
		end
	end
	if #far > 0 then
		for id, p in pairs(slots) do
			for _ = 1, 8 do
				local inside = false
				for _, e in ipairs(far) do
					if dist2(p.x, p.z, e.x, e.z) < e.r * e.r then
						inside = true
						break
					end
				end
				if not inside then
					break
				end
				local bx, bz = sub.rallyX - p.x, sub.rallyZ - p.z
				local bl = sqrt(bx * bx + bz * bz)
				if bl < 50 then
					break
				end
				local step = min(120, bl)
				p = { x = p.x + bx / bl * step, z = p.z + bz / bl * step }
			end
			slots[id] = p
		end
	end
	sub.holdSlots = slots
end

local function thinkCombat(sub, unitID, d, st, threats)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return
	end
	-- stepping out of incoming fire (Engine.dodge): leave it to finish
	if st.dodgeUntil and frame < st.dodgeUntil then
		return
	end
	-- badly damaged units worth saving fall back out of reach (threat map), where constructors repair them
	local retreatAt = Engine.squads.retreatAt(d)
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	if hp and maxHp and maxHp > 0 and retreatAt then
		local f = hp / maxHp
		if st.retreating then
			if f > Engine.D.retreat.back or frame - st.retreating > Engine.D.retreat.maxFrames then
				st.retreating = nil
			else
				return
			end
		elseif f < retreatAt and Engine.tm.threat(x, z) > 0 then
			local rx, rz = Engine.tm.safePoint(x, z, Engine.homeX, Engine.homeZ)
			if not rx then
				local zone = largestZone(sub)
				if zone then
					rx, rz = Zone.center(zone)
				end
			end
			if rx and dist2(x, z, rx, rz) > 200 * 200 then
				order(unitID, CMD.MOVE, { rx, spGetGroundHeight(rx, rz), rz })
				st.retreating, st.engaged = frame, nil
				setTask(unitID, "retreat", "falling back to repair", true)
				return
			end
		end
	end
	local busy = (spGetUnitCommandCount(unitID) or 0) > 0
	-- the air wing strikes or flies home (Tactics.airRaid)
	local ao = sub.airOrder
	if st.airRaid and ao then
		if st.airSeq ~= ao.seq or not busy then
			if ao.action ~= "home" and d.kind == "bomber" then
				order(unitID, CMD.AREA_ATTACK, { ao.x, spGetGroundHeight(ao.x, ao.z), ao.z, Engine.D.air.bombRadius })
			else
				order(unitID, ao.action == "home" and CMD.MOVE or CMD.FIGHT, { ao.x, spGetGroundHeight(ao.x, ao.z), ao.z })
			end
			st.airSeq = ao.seq
			setTask(unitID, "airraid", ao.action == "strike" and "air raid" or "air wing: home", true)
		end
		return
	end
	-- raid squad members follow the raid's route (Tactics.raid)
	local ro = sub.raidOrder
	if st.raid and ro then
		if st.raidSeq ~= ro.seq or not busy then
			local route = ro.route or { { x = ro.x, z = ro.z } }
			for i = 1, #route - 1 do
				order(unitID, CMD.MOVE, { route[i].x, spGetGroundHeight(route[i].x, route[i].z), route[i].z }, i > 1 and { "shift" } or nil)
			end
			local last = route[#route]
			order(unitID, ro.action == "retreat" and CMD.MOVE or CMD.FIGHT, { last.x, spGetGroundHeight(last.x, last.z), last.z }, #route > 1 and { "shift" } or nil)
			st.raidSeq = ro.seq
			setTask(unitID, "raid", ro.action == "raid" and "raiding" or (ro.action == "explore" and "scouting" or "raid coming home"), true)
		end
		return
	end
	-- the response squad intercepts raids in the base, or waits at its centre (Tactics.responders)
	local rso = sub.responseOrder
	if st.responder and rso then
		if rso.action == "engage" then
			if st.engaged ~= rso.id or not busy or frame - (st.engagedFrame or 0) > 150 then
				order(unitID, CMD.FIGHT, { rso.x, spGetGroundHeight(rso.x, rso.z), rso.z })
				st.engaged, st.engagedFrame = rso.id, frame
				setTask(unitID, "respond", "intercepting a raid", true)
			end
		elseif dist2(x, z, rso.x, rso.z) > 350 * 350 and (not busy or (st.softUntil and frame > st.softUntil)) then
			local a = (unitID % 9) / 9 * 2 * pi
			local gx, gz = clampToMap(rso.x + cos(a) * 160, rso.z + sin(a) * 160)
			order(unitID, CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
			st.engaged = nil
			setTask(unitID, "respond", "response squad: waiting in the base", true)
		end
		return
	end
	-- cloaking units stay cloaked (doctrine.cloak, Armada): hidden until they fire or come close
	local CL = Engine.D.cloak
	if CL and CL.keepOn and d.canCloak and not st.cloakSet and canControl then
		order(unitID, Engine.CMD_WANT_CLOAK, { 1 })
		st.cloakSet = true
	end
	-- the army's anti-air covers it from behind (doctrine.engage.aaFollow, elmos behind the squad, away from
	-- its target): it chased aircraft and patrolled the army's zone, which reaches past the front, and died to
	-- ground units walking ahead of the army (a player's game). Hold position: it shoots what flies in range
	local aaBack = Engine.D.engage.aaFollow
	if aaBack and sub.role == "army" and d.aaOnly and d.mobile and not d.air then
		if not st.aaHold then
			order(unitID, CMD.MOVE_STATE, { 0 })
			st.aaHold = true
		end
		local so, sq = sub.squadOrder, sub.squad
		local cx, cz = sub.rallyX, sub.rallyZ
		if sq and sq.x then
			cx, cz = sq.x, sq.z
		end
		if cx then
			local tx, tz = (so and so.x) or Engine.enemyX, (so and so.z) or Engine.enemyZ
			if tx then
				local dx, dz = cx - tx, cz - tz
				local len = max(sqrt(dx * dx + dz * dz), 1)
				cx, cz = cx + dx / len * aaBack, cz + dz / len * aaBack
			end
			cx, cz = clampToMap(cx, cz)
			if dist2(x, z, cx, cz) > 220 * 220 and (not busy or frame - (st.aaFollowFrame or 0) > 90) then
				order(unitID, CMD.MOVE, { cx, spGetGroundHeight(cx, cz), cz })
				st.aaFollowFrame = frame
				setTask(unitID, "follow", "covering the army from behind", true)
			end
		end
		return
	end
	-- the army acts as one squad (Tactics.squad)
	if sub.role == "army" and not d.aaOnly and not d.air then
		-- roam: an idle unit goes for enemies it sees (BAR's default only answers what comes close), so a
		-- blob's back joins the fight its front is in
		if Engine.D.engage.roam and not st.roamSet then
			order(unitID, CMD.MOVE_STATE, { 2 })
			st.roamSet = true
		end
		local so, sq = sub.squadOrder, sub.squad
		if so and so.action == "engage" then
			if Tactics.micro(unitID, d, st, x, z) then
				return
			end
			local slot = sub.arcSlots and sub.arcSlots[unitID]
			local gx, gz = so.x, so.z
			if slot then
				gx, gz = clampToMap(slot.x, slot.z)
			end
			-- the march (doctrine.engage.march): while the main body is still far from the target, a unit more
			-- than `leash` ahead of it along the way waits there (each unit got its own FIGHT at its own speed:
			-- the fast ones arrived first and alone, a player saw the army strung out)
			local M = Engine.D.engage.march
			-- raiders are exempt: their speed is the point (with the leash the opening's Goblins and Blitzes
			-- waited for the slow units, and opening kills fell in three tests)
			if M and sq and sq.x and d.kind ~= "raider" and d.kind ~= "hover raider" then
				local dx, dz = so.x - sq.x, so.z - sq.z
				local len = max(sqrt(dx * dx + dz * dz), 1)
				if len > M.contact and dist2(x, z, so.x, so.z) > M.contact * M.contact then
					local ahead = ((x - sq.x) * dx + (z - sq.z) * dz) / len
					if ahead > M.leash then
						if st.marchWait ~= so.id or frame - (st.marchFrame or 0) > 90 then
							local wx, wz = clampToMap(sq.x + dx / len * M.leash * 0.5, sq.z + dz / len * M.leash * 0.5)
							order(unitID, CMD.MOVE, { wx, spGetGroundHeight(wx, wz), wz })
							st.marchWait, st.marchFrame, st.engaged = so.id, frame, nil
							setTask(unitID, "regroup", "waiting for the army", true)
						end
						return
					end
				end
			end
			st.marchWait = nil
			local moved = st.engageX and dist2(gx, gz, st.engageX, st.engageZ) > 150 * 150
			if st.engaged ~= so.id or not busy or moved or frame - (st.engagedFrame or 0) > 150 then
				order(unitID, CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
				st.engaged, st.engagedFrame, st.engageX, st.engageZ = so.id, frame, gx, gz
				setTask(unitID, "engage", slot and "engaging (concave)" or "engaging", true)
			end
			return
		end
		st.engaged = nil
		-- kiting while holding too (doctrine.micro.kiteHolding): enemies come to a holding squad, and its
		-- skirmishers stood still (lab: Janus lost 2.9 log2 to assault units it outranges 2x)
		if Engine.D.micro.kiteHolding and not (so and so.action == "fallback") then
			if st.kiteUntil and frame < st.kiteUntil then
				return
			end
			-- screened by our front line (2+ assault, heavy or raider units close by): stay and shoot over
			-- it (lab: kiting skirmishers left mixed armies' fronts alone, Cortex mirror 5.8 -> 3.8)
			local screen = 0
			local K = Engine.D.micro.kiteHolding
			for _, u in ipairs(spGetUnitsInCylinder(x, z, K.screenRadius, myTeam)) do
				local ud = u ~= unitID and unitDef(u)
				if ud and ud.mobile and not ud.air and (ud.kind == "assault" or ud.kind == "heavy" or ud.kind == "raider") then
					screen = screen + 1
				end
			end
			if screen < K.screen and Tactics.kite(unitID, d, st, x, z) then
				return
			end
		end
		if so and so.action == "regroup" and sq and sq.x then
			if dist2(x, z, sq.x, sq.z) > (Engine.D.engage.cohesion * 0.6) ^ 2 and (not busy or frame - (st.regroupFrame or 0) > 150) then
				order(unitID, CMD.MOVE, { sq.x, spGetGroundHeight(sq.x, sq.z), sq.z })
				st.regroupFrame = frame
				setTask(unitID, "regroup", "regrouping", true)
			end
			return
		end
		local rx, rz = sub.rallyX, sub.rallyZ
		-- artillery waits behind the rally point (sc_micro.lua: behind)
		local behind = rx and Engine.micro.rule(d.kind, Engine.armyStyleNow).behind
		if behind and Engine.homeX then
			local hdx, hdz = Engine.homeX - rx, Engine.homeZ - rz
			local hl = max(sqrt(hdx * hdx + hdz * hdz), 1)
			rx, rz = rx + hdx / hl * min(behind, hl), rz + hdz / hl * min(behind, hl)
		end
		-- falling back to our turrets when they're near (doctrine.engage.retreatToTurrets): the pursuers
		-- meet them there
		local RT = Engine.D.engage.retreatToTurrets
		if RT and so and so.action == "fallback" then
			local tur = Engine.ourTurrets(x, z, RT.radius)
			if tur and tur.value >= RT.minValue then
				local a = (unitID % 12) / 12 * 2 * pi
				rx, rz = clampToMap(tur.x + cos(a) * 120, tur.z + sin(a) * 120)
				if dist2(x, z, rx, rz) > 200 * 200 and (not busy or st.fallbackTo ~= floor(tur.x / 200) .. ":" .. floor(tur.z / 200)) then
					order(unitID, CMD.MOVE, { rx, spGetGroundHeight(rx, rz), rz })
					st.fallbackTo = floor(tur.x / 200) .. ":" .. floor(tur.z / 200)
					setTask(unitID, "rally", "falling back to our turrets", true)
				end
				return
			end
		end
		-- a fighting retreat: in reach of the enemy, each pass (1 s) step back toward the rally point what
		-- it covers in fallbackPace of the time, and stand and shoot the rest (fire control's set targets
		-- pick the pursuers), instead of running the whole way with its back turned (our retreats traded
		-- 0.15-0.37, strong players' about even: pro-micro.md)
		local pace = Engine.D.engage.fallbackPace
		local step = pace and max(40, (d.speed or 0) * pace * COMBAT_EVERY / 30)
		if step and so and so.action == "fallback" and rx and dist2(x, z, rx, rz) > (step + 260) ^ 2 and Engine.tm.threat(x, z) > 0 then
			local dx, dz = rx - x, rz - z
			local len = max(sqrt(dx * dx + dz * dz), 1)
			local gx, gz = clampToMap(x + dx / len * step, z + dz / len * step)
			order(unitID, CMD.MOVE, { gx, spGetGroundHeight(gx, gz), gz })
			setTask(unitID, "rally", "falling back, fighting", true)
			return
		end
		-- holding in a line facing them (Engine.holdLine), not a ring around the rally point
		local slot = not behind and not (so and so.action == "fallback") and sub.holdSlots and sub.holdSlots[unitID]
		if slot then
			local gx, gz = clampToMap(slot.x, slot.z)
			if dist2(x, z, gx, gz) > 100 * 100 and (not busy or (st.softUntil and frame > st.softUntil)) then
				order(unitID, CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
				setTask(unitID, "rally", "holding the line", true)
			end
			return
		end
		if rx and dist2(x, z, rx, rz) > 260 * 260 and (not busy or (st.softUntil and frame > st.softUntil) or (so and so.action == "fallback")) then
			local a = (unitID % 12) / 12 * 2 * pi
			local gx, gz = clampToMap(rx + cos(a) * 120, rz + sin(a) * 120)
			-- falling back: move without stopping to fight; otherwise fight-move
			order(unitID, (so and so.action == "fallback") and CMD.MOVE or CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
			setTask(unitID, "rally", (so and so.action == "fallback") and "falling back" or "gathering", true)
		end
		return
	end
	-- everyone else (guards, defense, anti-air): the nearest intruder in their zones
	local target, targetD
	for i = 1, #threats do
		local t = threats[i]
		-- anti-air doesn't chase aircraft into ground forces stronger than ours there (it can't shoot them)
		local aaSafe = not (d.aaOnly and d.mobile and Engine.D.engage.aaFollow) or Engine.tm.threat(t.x, t.z) <= Engine.tm.influence(t.x, t.z)
		if aaSafe and ((d.aaOnly and t.air) or (not d.aaOnly and (not t.air or d.air))) then
			local dd = dist2(x, z, t.x, t.z)
			if not targetD or dd < targetD then
				target, targetD = t, dd
			end
		end
	end
	if target then
		if st.engaged ~= target.id or not busy or frame - (st.engagedFrame or 0) > 150 then
			order(unitID, CMD.FIGHT, { target.x, spGetGroundHeight(target.x, target.z), target.z })
			st.engaged, st.engagedFrame = target.id, frame
			setTask(unitID, "engage", "engaging intruder", true)
		end
		return
	end
	st.engaged = nil
	-- the commander's escort: two of the economy's guards stay with it (losing it loses the game; v7
	-- lost 7 of 16 commanders once the guards left for the pickets)
	if sub.role == "economy" and Engine.escort(sub, unitID) then
		local com = Engine.commanderID
		if st.escorting ~= com or not busy then
			order(unitID, CMD.GUARD, { com })
			st.escorting = com
			setTask(unitID, "escort", "guarding the commander", true)
		end
		return
	end
	st.escorting = nil
	-- the economy's other guards screen the side approaches (pickets 2..n; the army holds the main front)
	local P = Engine.pickets
	if sub.role == "economy" and P and #P > 1 then
		local p = P[2 + (unitID % (#P - 1))]
		if dist2(x, z, p.x, p.z) > 350 * 350 and (not busy or (st.softUntil and frame > st.softUntil)) then
			local a = (unitID % 7) / 7 * 2 * pi
			local gx, gz = clampToMap(p.x + cos(a) * 150, p.z + sin(a) * 150)
			order(unitID, CMD.FIGHT, { gx, spGetGroundHeight(gx, gz), gz })
			setTask(unitID, "picket", "guarding a side approach", true)
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
	role = canonicalRole(role)
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
		autonomy = "balanced", -- light / balanced / full (sc_doctrine.lua)
		autoZones = true, -- no zones drawn: work where its role calls for (sc_autozones.lua)
	}
	sub.color = PALETTE[sub.colorIndex]
	subs[#subs + 1] = sub
	activeSub = sub
	log(sub, "created (" .. ROLE_INFO[role].label .. ")")
	Engine.updateAutoZones(sub)
	return sub
end

-- build priority: the posture's, but low while the player builds and metal is short
function Player.subPriority(sub)
	return Player.yield and 0 or POSTURE_INFO[sub.posture].priority
end

local function applyPriority(sub, unitID)
	local d = unitDef(unitID)
	if CMD_PRIORITY and d and (d.builder or d.factory or d.nano) and not d.commander then
		-- a unit the player took over works for the player: normal priority
		local st = ustate[unitID]
		order(unitID, CMD_PRIORITY, { (st and st.manual) and 1 or Player.subPriority(sub) })
	end
end

Player.restorePriority = applyPriority

-- re-apply when the priority a sub-commander should have changes (player started/stopped building)
function Player.refreshPriorities()
	for _, sub in ipairs(subs) do
		local want = Player.subPriority(sub)
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

-- for code above this point (economyProduction hands the T2 lab to the Army): calling the local there
-- reads an undefined global, crashed the widget and BAR removed it (v15-v17 games played without it)
Engine.addUnit = addUnit

local function autoZone(sub, unitIDs)
	if #sub.zones > 0 or sub.autoZones then
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

-- autonomy: how much a sub-commander does on its own (sc_doctrine.lua autonomy levels)
function Engine.setAutonomy(sub, level)
	if not Engine.D.autonomy[level] or level == "levels" or level == "labels" then
		return false
	end
	sub.autonomy = level
	log(sub, "autonomy: " .. Engine.D.autonomy.labels[level])
	return true
end

function Engine.fedByName(sub)
	if sub.role ~= "army" or sub.counts.factories > 0 or not Engine.D.production.feedArmy then
		return nil
	end
	for _, s in ipairs(subs) do
		if s.role == "economy" and s.counts.factories > 0 then
			return s.name .. "'s factory builds my units"
		end
	end
	return nil
end

-- for the report: true / false for armies, absent for other roles
function Engine.raidsField(sub)
	if sub.role ~= "army" then
		return nil
	end
	return Engine.raiding(sub)
end

-- factories and units the player took back stay theirs: never adopted again
Engine.released, Engine.builtByUs = {}, {}

function Engine.playerRelease(unitID)
	Engine.released[unitID] = true
	releaseUnit(unitID)
end

-- who adopts a factory our constructors built, when a sub-commander at full autonomy is involved: the
-- Army (it produces), else the builder's own sub-commander; nil = it stays the player's
function Engine.factoryAdopter(builderSub)
	local full = (builderSub and builderSub.autonomy == "full")
	local army
	for _, s in ipairs(subs) do
		if s.role == "army" and not s.paused and (not army or s.counts.factories < army.counts.factories) then
			army = s
		end
		full = full or (s.role == "army" and s.autonomy == "full")
	end
	if not full then
		return nil
	end
	return (army and army.autonomy == "full" and army) or (builderSub and builderSub.autonomy == "full" and builderSub) or nil
end

-- every 10 s at full autonomy: our factories that nobody owns (their sub-commander was deleted, or it was
-- finished before adoption) and that the player didn't release go back to work
function Engine.adoptFactories()
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d = unitDef(u)
		if d and d.factory and not owner[u] and not Engine.released[u] and Engine.builtByUs[u] then
			local adopter = Engine.factoryAdopter(nil)
			if adopter then
				addUnit(adopter, u, { takeOver = true })
				log(adopter, "took over the idle " .. d.human .. " (full autonomy)")
			end
		end
	end
end

-- the commander's mode (auto / builder / defender / frontline) or personality (careful / bold), team-wide.
-- Returns false for anything else.
function Engine.setCommander(what)
	local C = Engine.com
	local kind
	for _, m in ipairs(C.MODES) do
		if m == what then
			Engine.comMode, kind = what, "mode"
		end
	end
	for _, p in ipairs(C.PERSONALITIES) do
		if p == what then
			Engine.comPersonality, kind = what, "personality"
		end
	end
	if not kind then
		return false
	end
	local sub = Engine.commanderID and owner[Engine.commanderID]
	for _, s in ipairs(sub and { sub } or subs) do
		log(s, sformat("commander %s: %s", kind, what))
	end
	return true
end

-- Raids (armies, on by default): its fast units scout the enemy's side and hit what they beat
function Engine.setRaids(sub, on)
	sub.raids = on and true or false
	log(sub, on and "raids on: fast units scout and raid" or "raids off: all units stay with the army")
end

-- auto zones: recomputed from the base, the enemy's direction, exposed extractors and the army's rally
function Engine.updateAutoZones(sub)
	if not sub.autoZones or not Engine.homeX then
		return
	end
	local rally
	if sub.role == "army" and sub.rallyX then
		rally = { sub.rallyX, sub.rallyZ }
	end
	local ex, ez = Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2
	local ax, az = Engine.approachDir()
	if ax and sub.role == "defense" then
		ex, ez = Engine.homeX + ax * 2000, Engine.homeZ + az * 2000
	end
	if sub.role == "defense" and Engine.pickets and #Engine.pickets > 0 then
		local zones = {}
		for i, p in ipairs(Engine.pickets) do
			if i <= 4 then
				local x, z = clampToMap(p.x, p.z)
				zones[#zones + 1] = { kind = "circle", x = floor(x), z = floor(z), r = 600, auto = true }
			end
		end
		sub.zones = zones
		return
	end
	sub.zones = Engine.zones.forRole(sub.role, {
		home = { Engine.homeX, Engine.homeZ },
		enemy = { ex, ez },
		extractors = Engine.extractors,
		rally = rally,
	})
end

-- the player (or the strategist) draws a zone: from now on zones are theirs
function Engine.manualZones(sub)
	if sub.autoZones then
		sub.autoZones = false
		sub.zones = {}
	end
end

function Engine.useAutoZones(sub)
	sub.autoZones = true
	sub.zones = {}
	Engine.updateAutoZones(sub)
	log(sub, "zones: automatic (by role)")
end

local function setRole(sub, role)
	role = canonicalRole(role)
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
	Engine.updateAutoZones(sub)
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
	local c = { builders = 0, factories = 0, combat = 0, nanos = 0, statics = 0, total = 0, scouts = 0, intelUnits = 0, power = 0, cats = {}, catPower = {} }
	local spendM, spendE = 0, 0
	local sx, sz, sn = 0, 0, 0
	for u in pairs(sub.units) do
		local d = unitDef(u)
		if d then
			c.total = c.total + 1
			local cat = Engine.prod.category(d)
			if cat then
				c.cats[cat] = (c.cats[cat] or 0) + 1
				c.catPower[cat] = (c.catPower[cat] or 0) + d.cost
			end
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
	-- our order raced the player's and replaced it: put the player's back
	local pc = st.playerCmd
	if pc and frame - pc.frame >= 10 then
		st.playerCmd = nil
		local ours = false
		for _, f in pairs(st.expect) do
			ours = ours or f >= pc.frame - 20
		end
		local current = Spring.GetUnitCurrentCommand(unitID)
		if ours and current ~= pc.id then
			Spring.GiveOrderToUnit(unitID, pc.id, pc.params or {}, pc.opts or 0)
		end
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
		if st.task and st.task.kind == "build" and not st.task.started and frame - st.task.frame < 30 * (st.task.routed and 90 or 45) and st.task.x then
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
	if task.kind == "build" and not task.started and frame - task.frame > 30 * (task.routed and 90 or 45) then
		if task.x then
			badSpots[#badSpots + 1] = { x = task.x, z = task.z, untilFrame = frame + 30 * 120 }
		end
		planned[unitID] = nil
		log(owner[unitID], "gave up on " .. task.text .. " (couldn't start it)")
		return true
	end
	return st.softUntil ~= nil and frame >= st.softUntil
end

-- The commander: in BAR's default game mode its death loses the game. It falls back from
-- armed enemies close by, or when hurt, toward our turrets and away from the threat.

function Tactics.guardCommander(sub, unitID, st)
	if st.fleeing and frame - st.fleeing < 30 * 15 then
		return true
	end
	st.fleeing = nil
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return false
	end
	local power, tx, tz, n = 0, 0, 0, 0
	for _, u in ipairs(spGetUnitsInCylinder(x, z, 800)) do
		if isEnemyUnit(u) then
			local ud = unitDef(u) -- nil for radar blips: assume armed
			if not ud or (ud.armed and not ud.aaOnly) then
				local ex, _, ez = spGetUnitPosition(u)
				power, tx, tz, n = power + (ud and ud.cost or 60), tx + ex, tz + ez, n + 1
			end
		end
	end
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	local hurt = hp and maxHp and hp < maxHp * Engine.com.personality(Engine.comPersonality).retreat
	if n == 0 or (power < 100 and not hurt) then
		return false
	end
	tx, tz = tx / n, tz / n
	-- the nearest group of our turrets that is farther from the threat than we are, else straight away from it
	local bx, bz, bestD
	for _, u in ipairs(spGetUnitsInCylinder(x, z, 2500)) do
		local ud = unitDef(u)
		if ud and ud.staticDef and spGetUnitTeam(u) == myTeam then
			local sx, _, sz = spGetUnitPosition(u)
			if dist2(sx, sz, tx, tz) > dist2(x, z, tx, tz) + 200 * 200 then
				local dd = dist2(x, z, sx, sz)
				if not bestD or dd < bestD then
					bx, bz, bestD = sx, sz, dd
				end
			end
		end
	end
	-- out of known enemy reach toward home first (turrets now stand on the frontier pickets: the nearest
	-- ones can be at the edge, closer to the enemy)
	local sx, sz = Engine.tm.safePoint(x, z, Engine.homeX, Engine.homeZ)
	if sx and dist2(x, z, sx, sz) > 150 * 150 then
		bx, bz = sx, sz
	end
	if not bx then
		local dx, dz = x - tx, z - tz
		local len = max(sqrt(dx * dx + dz * dz), 1)
		bx, bz = clampToMap(x + dx / len * 700, z + dz / len * 700)
	end
	order(unitID, CMD.MOVE, { bx, spGetGroundHeight(bx, bz), bz })
	planned[unitID] = nil
	st.fleeing = frame
	setTask(unitID, "flee", "commander falling back from enemies", true)
	if frame - (sub.comFleeNoted or -99999) > 30 * 30 then
		sub.comFleeNoted = frame
		log(sub, "commander pulled back from enemies (losing it loses the game)")
	end
	return true
end

-- Constructors (BARbarian retreats them at 85% health): leave when enemy firepower reaches them that ours
-- doesn't cover, and enemies are close or they're getting hurt; fall back to the nearest safe point
-- toward home (threat map) and come back when it's clear.
function Tactics.builderSafety(sub, unitID, d, st)
	if st.fleeing and frame - st.fleeing < 30 * 10 then
		return true
	end
	st.fleeing = nil
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return false
	end
	local tm = Engine.tm
	local threat = tm.threat(x, z)
	if threat <= 0 or threat <= tm.influence(x, z) then
		return false
	end
	local hp, maxHp = Spring.GetUnitHealth(unitID)
	local hurt = hp and maxHp and hp < maxHp * Engine.D.retreat.builder
	if not hurt and tm.enemyPower(x, z, 700, frame) <= 0 then
		return false
	end
	local sx, sz = tm.safePoint(x, z, Engine.homeX, Engine.homeZ)
	if not sx then
		sx, sz = Engine.homeX, Engine.homeZ
	end
	if not sx or dist2(x, z, sx, sz) < 64 * 64 then
		return false
	end
	order(unitID, CMD.MOVE, { sx, spGetGroundHeight(sx, sz), sz })
	planned[unitID] = nil
	st.fleeing = frame
	setTask(unitID, "flee", "falling back from enemies", true)
	if frame - (sub.builderFleeNoted or -99999) > 30 * 30 then
		sub.builderFleeNoted = frame
		log(sub, "constructor pulled back from enemies")
	end
	return true
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
					if d.commander and ((combatPass and Tactics.guardCommander(sub, unitID, st)) or (st.fleeing and frame - st.fleeing < 30 * 15)) then
						-- the commander is getting out of danger
					elseif d.commander and ((combatPass and Tactics.commander(sub, unitID, d, st)) or (st.comBusy and frame < st.comBusy)) then
						-- the commander is D-gunning or at the front (sc_commander.lua)
					elseif not d.commander and ((combatPass and Tactics.builderSafety(sub, unitID, d, st)) or (st.fleeing and frame - st.fleeing < 30 * 10)) then
						-- a constructor is getting out of danger
					elseif budget > 0 and builderNeedsThink(unitID, st) then
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
				elseif d.rezBot and Engine.D.strategic.resurrect.on then
					-- Engine.strategicControl raises wrecks with it (it has a radar: Intel.thinkUnit kept it on
					-- a radar post, never idle, in smoke test 4)
				elseif d.combat or (d.mobile and not d.builder and not d.commander) then
					if combatPass then
						if sub.role == "air" and d.air then
							Tactics.airUnit(sub, unitID, d, st)
						elseif sub.role == "air" then
							thinkCombat(sub, unitID, d, st, sub.threats) -- its mobile anti-air
						elseif sub.role == "intelligence" then
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
		autonomy = sub.autonomy or "balanced",
		autoZones = sub.autoZones or false,
		raids = Engine.raidsField(sub),
		-- an army without a factory gets its units from the economy's (strong players run one lab)
		fedBy = Engine.fedByName(sub),
		raid = sub.raidOrder and { action = sub.raidOrder.action, target = { x = floor(sub.raidOrder.x), z = floor(sub.raidOrder.z) } } or nil,
		airForce = sub.airOrders and (function()
			local out = {}
			for k, o in pairs(sub.airOrders) do
				out[k] = { action = o.action, x = floor(o.x), z = floor(o.z), power = o.power and floor(o.power) or nil }
			end
			return out
		end)() or nil,
		airWing = sub.airOrder and { action = sub.airOrder.action, power = floor(sub.airOrder.power), target = { x = floor(sub.airOrder.x), z = floor(sub.airOrder.z) } } or nil,
		response = sub.responseOrder and { action = sub.responseOrder.action, power = sub.respSquad and floor(sub.respSquad.together) or 0 } or nil,
		squad = sub.squadOrder and { action = sub.squadOrder.action, ratio = floor(sub.squadOrder.ratio * 10) / 10, target = { x = floor(sub.squadOrder.x), z = floor(sub.squadOrder.z) } } or nil,
		dodges = sub.dodges, -- units that stepped out of incoming fire so far
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
		-- the threat map (remembered enemies, fading): their armed groups, strongest first, and the safe
		-- edge of our side toward them (the front)
		groups = Engine.tm.groups(frame, 5),
		front = Engine.homeX and Engine.enemyX and (function()
			local x, z = Engine.tm.front(Engine.homeX, Engine.homeZ, Engine.enemyX, Engine.enemyZ)
			return { x = floor(x), z = floor(z) }
		end)() or nil,
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
		elseif d.mobile or (d.factory and not spGetUnitIsBeingBuilt(u)) then
			rejected[#rejected + 1] = { id = u, reason = "only structures other than finished factories can be removed" }
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
		featureOf = function(unitID)
			return Engine.featureOf(unitID)
		end,
		killCredit = function(unitID, defID, x, z)
			return Engine.killCredit(unitID, defID, x, z)
		end,
		features = function()
			return Engine.features
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
				Engine.playerRelease(u)
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
		coverAlly = function(id)
			local sub = findSub(id)
			return sub and Engine.coverAlly(sub) or false
		end,
		coverArea = function(id, x, z, r)
			local sub = findSub(id)
			if sub and x and z then
				Engine.coverArea(sub, x, z, r)
				return true
			end
			return false
		end,
		allies = function()
			return Engine.allyBases()
		end,
		addZone = function(id, zone)
			local sub = findSub(id)
			if sub and zone and (zone.kind == "rect" or zone.kind == "circle") then
				Engine.manualZones(sub)
				sub.zones[#sub.zones + 1] = zone
				log(sub, "zone added")
			end
		end,
		setAutonomy = function(id, level)
			local sub = findSub(id)
			return sub and Engine.setAutonomy(sub, level) or false
		end,
		teamReport = function()
			return Engine.teamReport()
		end,
		tune = function(key, value, role)
			return Engine.tune(key, value, role)
		end,
		setCommander = function(what)
			return Engine.setCommander(what)
		end,
		-- rules learned from past games ({ key, generation, rules = { name = value } }; the bridge sends them)
		applyLearned = function(data)
			return Engine.applyLearned(data)
		end,
		setArmyStyle = function(name)
			return Engine.setArmyStyle(name)
		end,
		-- a request to the team (sc_team.lua): { kind = "defend"|"constructor"|"production", from, x, z, need, note }
		request = function(req)
			if type(req) ~= "table" or not req.kind then
				return nil
			end
			return Engine.team.post(req, frame)
		end,
		setRaids = function(id, on)
			local sub = findSub(id)
			if sub then
				Engine.setRaids(sub, on)
			end
		end,
		clearZones = function(id)
			local sub = findSub(id)
			if sub then
				Engine.useAutoZones(sub)
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

Const.HELP = {
	"Sub-Commanders: /luaui sc <command>",
	"  new [economy|defense|army|intelligence|air]   create one (becomes active)",
	"  cover [id] ally|here|clear   the Air Force covers our ally's base / the point under the mouse / auto",
	"  assign [id]      give selected units to the active (or given) sub-commander",
	"  release          take selected units back",
	"  zone [id]        drag on the map to add a zone (shift keeps drawing)",
	"  clearzones [id]  remove the drawn zones: back to automatic zones by role",
	"  role <role> [id] / posture <conserve|balanced|spend> [id]",
	"  autonomy <light|balanced|full> [id]   how much it does on its own",
	"  raids <on|off> [id]   an army's fast units scout and raid (on by default)",
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
		for _, l in ipairs(Const.HELP) do
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
		if verb == "role" or verb == "posture" or verb == "ai" or verb == "autonomy" or verb == "raids" then
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
				Engine.playerRelease(u)
			end
		elseif verb == "zone" then
			startZoneTool(sub)
		elseif verb == "clearzones" or verb == "autozones" then
			Engine.useAutoZones(sub)
		elseif verb == "raids" then
			Engine.setRaids(sub, words[2] ~= "off")
		elseif verb == "style" then
			if not Engine.setArmyStyle(words[2] or "") then
				spEcho("Sub-Commanders: style is " .. tconcat(Engine.D.micro.order, ", "))
			end
		elseif verb == "commander" then
			if not Engine.setCommander(words[2] or "") then
				spEcho("Sub-Commanders: commander is auto, builder, defender, frontline, careful or bold")
			end
		elseif verb == "autonomy" then
			if not Engine.setAutonomy(sub, words[2] or "") then
				spEcho("Sub-Commanders: autonomy is light, balanced or full")
			end
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
		elseif verb == "cover" then
			-- cover [id] ally | here | clear: what the Air Force covers besides the base and army
			local what = tonumber(words[2]) and words[3] or words[2]
			if what == "ally" then
				Engine.coverAlly(sub)
			elseif what == "clear" then
				sub.zones, sub.autoZones = {}, true
				Engine.updateAutoZones(sub)
				log(sub, "cover areas cleared")
			else
				local mx, my = Spring.GetMouseState()
				local _, pos = Spring.TraceScreenRay(mx, my, true)
				if pos then
					Engine.coverArea(sub, pos[1], pos[3], 1300)
				end
			end
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
					Engine.playerRelease(u)
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
	local AL = Engine.D.autonomy
	local row = {
		{ "Autonomy: " .. AL.labels[sub.autonomy or "balanced"], function(button)
			Engine.setAutonomy(sub, cycle(AL.levels, sub.autonomy or "balanced", button == 3 and -1 or 1))
		end, (sub.autonomy == "full") and { 0.55, 1, 0.6 } or nil },
	}
	if sub.role == "army" then
		row[2] = { Engine.raiding(sub) and "Raids: on" or "Raids: off", function()
			Engine.setRaids(sub, not Engine.raiding(sub))
		end, Engine.raiding(sub) and { 1, 0.75, 0.4 } or nil }
		local now = Engine.micro.style(Engine.armyStyleNow).label
		row[3] = { Engine.armyStyle == "auto" and ("Style: auto (" .. now .. ")") or ("Style: " .. now), function(button)
			Engine.setArmyStyle(cycle(Engine.D.micro.order, Engine.armyStyle, button == 3 and -1 or 1))
		end, Engine.armyStyle == "auto" and { 0.55, 1, 0.6 } or nil }
	end
	buttonRow(x1, x2, y, h, s, row, fs)
	y = y - h - 4 * s
	-- the sub-commander with the commander: its mode and personality (sc_commander.lua)
	if Engine.commanderID and owner[Engine.commanderID] == sub then
		local C = Engine.com
		local mode = Engine.comMode
		local label = mode == "auto" and ("Auto: " .. (Engine.comModeNow or "builder")) or mode
		buttonRow(x1, x2, y, h, s, {
			{ "Commander: " .. label, function(button)
				Engine.setCommander(cycle(C.MODES, mode, button == 3 and -1 or 1))
			end, mode == "auto" and { 0.55, 1, 0.6 } or nil },
			{ Engine.comPersonality == "bold" and "Bold" or "Careful", function()
				Engine.setCommander(Engine.comPersonality == "bold" and "careful" or "bold")
			end, Engine.comPersonality == "bold" and { 1, 0.6, 0.4 } or nil },
		}, fs)
		y = y - h - 4 * s
	end
	local drawing = zoneTool and zoneTool.sub == sub
	buttonRow(x1, x2, y, h, s, {
		{ drawing and "Drawing…" or "+ Zone", function()
			if drawing then
				zoneTool, zoneDrag = nil, nil
			else
				startZoneTool(sub)
			end
		end, drawing and sub.color or nil },
		{ sub.autoZones and "Zones: auto" or "Auto zones", function()
			Engine.useAutoZones(sub)
		end, sub.autoZones and { 0.6, 0.85, 1 } or nil },
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
			if not zone.auto then
				drawZone(zone, sub.color, isActive and 0.9 or 0.45, isActive and 3 or 2)
			elseif isActive then
				drawZone(zone, sub.color, 0.35, 1)
			end
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
		Engine.manualZones(sub)
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
	-- raised from a wreck by a resurrection bot: the feature's return
	local bd = unitDef(builderID)
	if bd and bd.rezBot and defs[unitDefID] then
		getState(unitID).raised = true
		local F = Engine.features.rez or { spent = 0, count = 0, raised = 0 }
		F.raised, F.count = (F.raised or 0) + defs[unitDefID].cost, F.count + 1
		Engine.features.rez = F
	end
	if defs[unitDefID] then
		Engine.noteBuilt(unitDefID)
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
		local bst = ustate[builderID]
		local target = bst and bst.rebuildFor and findSub(bst.rebuildFor)
		if target then
			bst.rebuildFor = nil
			addUnit(target, unitID)
			getState(unitID).graceUntil = math.huge
			log(target, d.human .. (bst.newFactory and " is being built for me" or " is being rebuilt for me"))
			bst.newFactory = nil
			return
		end
		-- full autonomy: factories our constructors build are put to work (the player can release them)
		local adopter = Engine.factoryAdopter(sub)
		if adopter then
			addUnit(adopter, unitID)
			getState(unitID).graceUntil = math.huge
			Engine.builtByUs[unitID] = true
			log(adopter, d.human .. " is being built: I'll produce with it (full autonomy; release it to keep it yours)")
			return
		end
		Engine.builtByUs[unitID] = true
		log(sub, d.human .. " stays yours: assign it to me if I should produce with it")
		return
	end
	-- built for another sub-commander that had no constructor left
	local fst = ustate[builderID]
	if fst and fst.handOff and d and (d.builder or (fst.handOffCombat and d.combat)) then
		local target = findSub(fst.handOff)
		fst.handOff, fst.handOffCombat = nil, nil
		if target then
			sub = target
			if d.builder then
				log(target, "received a constructor from " .. owner[builderID].name)
			end
		end
	end
	addUnit(sub, unitID)
	getState(unitID).graceUntil = math.huge
	if CMD_PRIORITY and d and (d.builder or d.nano) then
		getState(unitID).needsPriority = true
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == myTeam and defs[unitDefID] then
		Engine.featureSpend(unitID, defs[unitDefID])
	end
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
	if d and (d.factory or d.builder or d.antinuke or d.shieldGen or d.lrpc or d.junoSilo or d.nukeSilo) then
		log(sub, "new " .. d.human)
	end

end

-- metal spots where raiders killed our extractor lately (doctrine.turrets.harden): their cover needs more
-- than one cheap turret, and the economy waits for it before rebuilding there
Engine.raided = {}
function Engine.noteRaided(unitID, d)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return
	end
	for _, r in ipairs(Engine.raided) do
		if dist2(x, z, r.x, r.z) < 300 * 300 then
			r.frame, r.n = frame, r.n + 1
			return
		end
	end
	Engine.raided[#Engine.raided + 1] = { x = x, z = z, frame = frame, n = 1 }
end

-- the raided spot near (x, z) within memory, if any
function Engine.raidedAt(x, z)
	local H = Engine.D.turrets.harden
	if not H then
		return nil
	end
	for _, r in ipairs(Engine.raided) do
		if frame - r.frame < 30 * H.memory and dist2(x, z, r.x, r.z) < 400 * 400 then
			return r
		end
	end
end

-- our turrets near (x, z): count and metal
function Engine.turretsNear(x, z, r)
	local n, v = 0, 0
	for _, u in ipairs(spGetUnitsInCylinder(x, z, r)) do
		local ud = unitDef(u)
		if ud and ud.staticDef and not ud.aaOnly and spGetUnitTeam(u) == myTeam then
			n, v = n + 1, v + ud.cost
		end
	end
	for _, p in pairs(planned) do
		if defs[p.defID].staticDef and not defs[p.defID].aaOnly and dist2(p.x, p.z, x, z) < r * r then
			n, v = n + 1, v + defs[p.defID].cost
		end
	end
	return n, v
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID)
	if unitTeam == myTeam and defs[unitDefID] and defs[unitDefID].mex > 0 and not spGetUnitIsBeingBuilt(unitID) then
		Engine.noteRaided(unitID, defs[unitDefID])
	end
	local sub = owner[unitID]
	if sub then
		local d = defs[unitDefID]
		if d and (d.mobile or d.factory) and not spGetUnitIsBeingBuilt(unitID) then
			log(sub, "lost " .. d.human)
		end
		-- a plane shot down by something we never saw: their anti-air reaches here (the threat map remembers
		-- it, so strikes and routes keep out until it fades)
		if d and d.air and not spGetUnitIsBeingBuilt(unitID) and not (attackerID and Engine.tm.enemies[attackerID]) then
			local x, _, z = spGetUnitPosition(unitID)
			if x then
				Engine.tm.markAA(x, z, d.cost, frame)
				log(sub, sformat("%s shot down by unseen anti-air at %d,%d: keeping planes out of there", d.human, x, z))
			end
		end
		-- a factory the player gave us: the economy rebuilds it (see Jobs.rebuildFactory)
		if d and d.factory and not spGetUnitIsBeingBuilt(unitID) then
			local x, _, z = spGetUnitPosition(unitID)
			if x then
				sub.lostFactories = sub.lostFactories or {}
				tinsert(sub.lostFactories, { defID = unitDefID, x = x, z = z, facing = Spring.GetUnitBuildFacing(unitID) or 0, frame = frame })
				log(sub, d.human .. " destroyed: the economy will rebuild it when the area is clear")
			end
		end
		releaseUnit(unitID, true)
	end
	ustate[unitID] = nil
	if Enemy.units[unitID] then
		Enemy.units[unitID] = nil
		Enemy.known = Enemy.known - 1
	end
	Engine.tm.forget(unitID)
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
	if d and d.commander and st.fleeing and frame - st.fleeing < 30 * 15 then
		return
	end
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
	local eb = st.expectBuild
	local mine = ours and frame - ours <= 45
	if cmdID < 0 and eb and eb.id == cmdID and type(cmdParams) == "table" and cmdParams[3] and frame - eb.frame <= 300
		and abs(cmdParams[1] - eb.x) < 8 and abs(cmdParams[3] - eb.z) < 8 then
		mine = true
	end
	if mine then
		-- ours landed after a player's order (sent before we saw theirs) and replaced it: put theirs back
		-- (the test player's first lab was lost this way: our wind turbine order arrived 15 frames later)
		local pc = st.playerCmd
		local shift = type(cmdOpts) == "table" and cmdOpts.shift
		if st.manual and pc and frame - pc.frame <= 150 and not shift then
			Spring.GiveOrderToUnit(unitID, pc.id, pc.params or {}, pc.opts or 0)
		end
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
		-- remember it: an order of ours sent around the same time may land after it and replace it
		local shift = type(cmdOpts) == "table" and cmdOpts.shift
		if not shift then
			st.playerCmd = { id = cmdID, params = cmdParams, opts = type(cmdOpts) == "table" and cmdOpts.coded or 0, frame = frame }
		end
		-- reserve the player's spot right away, before any of our builders can take it
		if cmdID < 0 and defs[-cmdID] and type(cmdParams) == "table" and cmdParams[3] then
			Player.plans[#Player.plans + 1] = { defID = -cmdID, x = cmdParams[1], z = cmdParams[3], facing = cmdParams[4] or 0, builder = unitID }
		end
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
			Engine.tm.see(unitID, defID, x, z, frame)
		end
	end
end

-- radar contacts we can't identify yet still count in the threat map (as a typical armed unit)
function widget:UnitEnteredRadar(unitID, unitTeam)
	if unitTeam and Spring.AreTeamsAllied(unitTeam, myTeam) then
		return
	end
	local x, _, z = spGetUnitPosition(unitID)
	if x then
		Engine.tm.seeBlip(unitID, x, z, frame)
	end
end

-- forget enemies that died, and structures whose spot we can see empty
function Enemy.prune()
	local oldest, oldestFrame
	for u, e in pairs(Enemy.units) do
		if not defs[e.defID].mobile and Spring.IsPosInLos(e.x, 0, e.z, myAlly) and not spGetUnitPosition(u) then
			Enemy.units[u] = nil
			Enemy.known = Enemy.known - 1
			Engine.tm.forget(u)
		elseif not oldestFrame or e.last < oldestFrame then
			oldest, oldestFrame = u, e.last
		end
	end
	if Enemy.known > 1500 and oldest then
		Enemy.units[oldest] = nil
		Enemy.known = Enemy.known - 1
	end
end

-- The world model, 3 times a second: where the enemies we can see are now (the ones we can't keep their
-- last position and fade), our armed units and defences, and the threat / influence grids.
function Engine.refreshWorld(n)
	local tm = Engine.tm
	for u, e in pairs(tm.enemies) do
		if not e.static then
			local x, _, z = spGetUnitPosition(u)
			if x then
				e.x, e.z, e.last = x, z, n
			end
		end
	end
	local own, turrets, army = {}, 0, 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d, defID = unitDef(u)
		if d and d.armed and not d.builder and not spGetUnitIsBeingBuilt(u) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				own[#own + 1] = { defID = defID, x = x, z = z }
				if d.staticDef then
					turrets = turrets + d.cost
				elseif d.mobile then
					army = army + d.cost
				end
			end
		end
	end
	tm.update(n, own, true)
	Engine.turretValue, Engine.armyValue = turrets, army
	-- once a second: mark the big groups in sight as hordes (remembered longer, sc_threatmap)
	if n - (Engine.hordeFrame or -99) >= 30 then
		Engine.hordeFrame = n
		tm.groups(n, 8)
	end
	if n - (Engine.homeFrame or -9999) >= 300 then
		Engine.homeFrame = n
		Engine.refreshHome()
	end
end

-- home: the centre of our factories (else the commander, else our start); the enemy: where they come from
function Engine.refreshHome()
	local sx, sz, n, cx, cz = 0, 0, 0, nil, nil
	local extractors, vitals, generators = {}, {}, {}
	local factories, labDef = 0, nil
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d, defID = unitDef(u)
		if d and d.factory then
			factories = factories + 1
			labDef = labDef or defID
		end
		if d and (d.factory or d.commander) and not spGetUnitIsBeingBuilt(u) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				vitals[#vitals + 1] = { x = x, z = z, factory = d.factory }
			end
		end
		if d and (d.mex > 0 or d.energy > 0) and not spGetUnitIsBeingBuilt(u) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				local list = d.mex > 0 and extractors or generators
				list[#list + 1] = { x = x, z = z }
			end
		end
		if d and (d.factory or d.commander) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				if d.factory then
					sx, sz, n = sx + x, sz + z, n + 1
				else
					cx, cz = x, z
					Engine.commanderID = u
					Engine.applyFaction(d and d.name)
				end
			end
		end
	end
	if n > 0 then
		Engine.homeX, Engine.homeZ = sx / n, sz / n
	elseif cx and not Engine.homeX then
		Engine.homeX, Engine.homeZ = cx, cz
	elseif not Engine.homeX then
		local x, _, z = Spring.GetTeamStartPosition(myTeam)
		Engine.homeX, Engine.homeZ = x or MAP_X / 2, z or MAP_Z / 2
	end
	Engine.enemyX, Engine.enemyZ = enemyDirectionRef(Engine.homeX, Engine.homeZ)
	Engine.extractors, Engine.vitals = extractors, vitals
	Engine.farms = Engine.zones.clusters(generators, 450, 4)
	Engine.refreshTerritory()
	Engine.factoryCount, Engine.labDef = factories, labDef or Engine.labDef
end

function Engine.turretBudgetValue()
	-- the team defending: more turrets (they hold where a weaker army can't)
	local defend = Engine.team.plan.phase == "defend" and Engine.D.team.defendTurrets or 1
	return Engine.D.turrets.budget(Engine.minute(), Engine.armyValue or 0) * (Engine.D.turrets.scale or 1) * defend
end

-- the strategist tunes the fast loops' doctrine (sc_doctrine.lua D.tunable): team-wide, within bounds
-- role: the asking sub-commander's role (only the rule's owner may change it); nil = the player
function Engine.tune(key, value, role)
	local D = Engine.D
	local t = D.tunable[key]
	value = tonumber(value)
	if not t then
		return nil, "unknown rule '" .. tostring(key) .. "'"
	end
	if not value then
		return nil, "value must be a number"
	end
	if role and t[6] and role ~= t[6] then
		return nil, sformat("%s belongs to the %s sub-commander; tell them (or the player) instead", key, t[6])
	end
	Engine.tuned = Engine.tuned or {}
	local last = Engine.tuned[key]
	if role and last and frame - last < D.tuneEvery then
		return nil, sformat("%s was changed %ds ago; give it %ds to show its effect", key, (frame - last) / 30, D.tuneEvery / 30)
	end
	local old = t[1][t[2]]
	-- one step at a time: at most tuneStep of the current value (of the range when the value is near 0)
	if role then
		local step = max(abs(old), (t[4] - t[3]) * 0.2) * D.tuneStep
		value = max(old - step, min(old + step, value))
	end
	value = max(t[3], min(t[4], value))
	Engine.tuned[key] = frame
	t[1][t[2]] = value
	-- a lower factory cap also cancels factory builds that haven't started
	if key == "max_factories" then
		for builder, p in pairs(planned) do
			if defs[p.defID].factory and (Engine.factoryCount or 0) >= value then
				order(builder, CMD.STOP)
				planned[builder] = nil
			end
		end
	end
	Engine.tuneLog = Engine.tuneLog or {}
	tinsert(Engine.tuneLog, 1, { key = key, from = old, to = value, frame = frame })
	return value
end

-- learned rules (internal/learn): at game start the widget reads LuaUI/Config/sc_learned.json (written by
-- the bridge for real games, by the test runners for exploration games) and applies each rule within its
-- doctrine bounds. Under the BAR 31614+ widget sandbox only LuaUI/ is readable: that's why it lives there.
-- our faction's doctrine overlay (sc_doctrine.lua D.factions), once: from the team's side at start, or
-- from the commander's unit name when the side was random. Before learned rules (they tune on top).
function Engine.applyFaction(name)
	if Engine.faction or not name or name == "" then
		return
	end
	local key = ({ arm = "armada", cor = "cortex", leg = "legion" })[name:lower():sub(1, 3)]
	if not key then
		return
	end
	Engine.faction = key
	local n = 0
	for _, o in ipairs(Engine.D.factions[key] or {}) do
		local path, value = o[1], o[2]
		local t, last = Engine.D, nil
		for part in path:gmatch("[^%.]+") do
			if last then
				t = t and t[last]
			end
			last = part
		end
		if type(t) == "table" and last then
			t[last] = value
			n = n + 1
		end
	end
	spEcho(sformat("Sub-Commanders: %s doctrine (%d changes)", key, n))
end

function Engine.applyLearned(data)
	if not data then
		local text = VFS.LoadFile("LuaUI/Config/sc_learned.json", VFS.RAW)
		if not text or not Json then
			return
		end
		local ok
		ok, data = pcall(Json.decode, text)
		if not ok then
			data = nil
		end
	end
	if type(data) ~= "table" or type(data.rules) ~= "table" then
		spEcho("Sub-Commanders: learned rules are not valid")
		return
	end
	-- "rule" applies all game; "rule@opening" / "@mid" / "@late" only in that stage (Engine.learnedStage)
	local n, stages, base = 0, {}, {}
	for key, value in pairs(data.rules) do
		local name, stage = key:match("^([%w_]+)@(%a+)$")
		local t = Engine.D.tunable[name or key]
		if t and tonumber(value) then
			local v = max(t[3], min(t[4], tonumber(value)))
			if stage then
				stages[stage] = stages[stage] or {}
				stages[stage][name] = v
			else
				t[1][t[2]] = v
			end
			n = n + 1
		end
	end
	-- each staged rule's all-game value, to go back to outside its stage
	for _, rules in pairs(stages) do
		for name in pairs(rules) do
			local t = Engine.D.tunable[name]
			base[name] = t[1][t[2]]
		end
	end
	Engine.learned = { key = data.key, generation = data.generation, rules = n, stages = stages, base = base, stage = nil }
	spEcho(sformat("Sub-Commanders: %d learned rules (%s, generation %s)", n, tostring(data.key), tostring(data.generation)))
end

-- learned rules for one stage of the game (opening < 10 min, mid 10-25, late 25+): strong players
-- play the stages differently, and a rule that pays in one can cost in another (make compare's verdicts)
function Engine.learnedStage()
	local L = Engine.learned
	if not L or not L.stages or not next(L.stages) then
		return
	end
	local m = Engine.minute()
	local stage = (m < 10 and "opening") or (m < 25 and "mid") or "late"
	if stage == L.stage then
		return
	end
	L.stage = stage
	for name, v in pairs(L.base) do
		local t = Engine.D.tunable[name]
		local sv = L.stages[stage] and L.stages[stage][name]
		t[1][t[2]] = sv or v
	end
end

function Engine.rules()
	local out = {}
	for key, t in pairs(Engine.D.tunable) do
		out[key] = t[1][t[2]]
	end
	return out
end

-- what got built lately (units and structures we started): Engine.built ring, summarized
function Engine.noteBuilt(defID)
	Engine.built = Engine.built or {}
	tinsert(Engine.built, { defID = defID, frame = frame })
	if #Engine.built > 300 then
		tremove(Engine.built, 1)
	end
end

function Engine.builtSince(frames)
	local structures, units = {}, {}
	for _, b in ipairs(Engine.built or {}) do
		if frame - b.frame <= frames then
			local d = defs[b.defID]
			local list = d.mobile and units or structures
			list[d.human] = (list[d.human] or 0) + 1
		end
	end
	return structures, units
end

-- things the rules are doing that a good player wouldn't (for the strategist and the panel)
function Engine.audit()
	local out = {}
	local labs = Engine.factoryCount or 0
	local nanos = Engine.nanoCount()
	if labs > 1 and not Engine.labsSaturated() then
		out[#out + 1] = sformat("%d factories but only %d construction turrets: scale one lab with turrets before adding labs (cap with tune_rules max_factories)", labs, nanos)
	end
	if labs > 1 and econ.mInc < Engine.D.economy.secondFactoryIncome then
		out[#out + 1] = sformat("%d factories on +%.0f metal/s: more labs than the income feeds", labs, econ.mInc)
	end
	if nanos < Engine.nanoTarget() - 1 then
		out[#out + 1] = sformat("%d construction turrets, income supports %d", nanos, Engine.nanoTarget())
	end
	if econ.mFrac > 0.9 then
		out[#out + 1] = "metal storage full: income is being wasted (more construction turrets, units, or spend posture)"
	end
	if econ.eFrac < 0.05 then
		out[#out + 1] = "energy empty: everything builds slower (more generators)"
	end
	local budget = Engine.turretBudgetValue()
	if (Engine.turretValue or 0) > budget * 1.2 then
		out[#out + 1] = sformat("turrets worth %d metal, budget %d: the metal belongs in the army", Engine.turretValue, budget)
	end
	local idle, raiders, combat = 0, 0, 0
	for _, sub in ipairs(subs) do
		for u in pairs(sub.units) do
			local d = unitDef(u)
			local st = ustate[u]
			if d and d.builder and not d.commander and st and st.task and st.task.kind == "idle" then
				idle = idle + 1
			end
		end
		if sub.role == "army" then
			raiders = raiders + ((sub.counts.cats or {}).raider or 0)
			combat = combat + sub.counts.combat
		end
	end
	if idle >= 2 then
		out[#out + 1] = sformat("%d constructors idle", idle)
	end
	if Engine.homeX and frame > 30 * 180 and not Engine.radarNearHome() then
		out[#out + 1] = "no radar covering the base: raids arrive unseen"
	end
	local blind = 0
	for _, p in ipairs(Engine.pickets or {}) do
		if not Intel.radarCovered(p.x, p.z, 0.9) then
			blind = blind + 1
		end
	end
	if frame > 30 * 360 and blind > 0 then
		out[#out + 1] = sformat("%d of %d approaches (pickets) have no radar: flanking raids arrive unseen", blind, #Engine.pickets)
	end
	if Engine.minute() > 8 and combat >= 8 and raiders > combat * 0.5 then
		out[#out + 1] = sformat("the army is %d%% raiders: cheap units feed their kills (raid_share)", floor(raiders / combat * 100))
	end
	return out
end

function Engine.teamReport()
	local structures, units = Engine.builtSince(30 * 180)
	return {
		rules = Engine.rules(),
		audit = Engine.audit(),
		builtLast3Min = { structures = structures, units = units },
		factories = Engine.factoryCount or 0,
		constructionTurrets = Engine.nanoCount(),
		constructionTurretTarget = Engine.nanoTarget(),
		turretValue = floor(Engine.turretValue or 0),
		turretBudget = floor(Engine.turretBudgetValue()),
		armyValue = floor(Engine.armyValue or 0),
		approach = Engine.approachText and Engine.approachText() or nil,
		-- the team's plan and what sub-commanders asked each other for (sc_team.lua)
		plan = { phase = Engine.team.plan.phase, why = Engine.team.plan.why },
		requests = (function()
			local out = {}
			for i, r in ipairs(Engine.team.open()) do
				out[i] = { kind = r.kind, from = r.from, x = r.x and floor(r.x), z = r.z and floor(r.z), need = r.need, note = r.note }
			end
			return out
		end)(),
		commander = { mode = Engine.comMode, now = Engine.comModeNow, personality = Engine.comPersonality },
		learned = Engine.learned, -- rules learned from past games (internal/learn), applied at game start
		armyStyle = { setting = Engine.armyStyle, now = Engine.armyStyleNow, desc = Engine.micro.style(Engine.armyStyleNow).desc },
		territory = Engine.pickets and {
			exposedFrontierCells = Engine.terr.exposed, -- our edge cells enemies can walk to (cliffs, water, map edge excluded)
			pickets = (function()
				local out = {}
				for i, p in ipairs(Engine.pickets) do
					out[i] = { x = floor(p.x), z = floor(p.z) }
				end
				return out
			end)(),
		} or nil,
	}
end

-- where intruders come from: the direction (8 sectors around home) of each new intruder in our areas,
-- fading by half every 5 minutes. The army waits on, and Defense builds toward, the busiest approach.
Const.SECTOR_NAMES = { "west", "north-west", "north", "north-east", "east", "south-east", "south", "south-west" }

function Engine.noteApproaches(threats)
	if not Engine.homeX then
		return
	end
	local A = Engine.approach
	if not A then
		A = { sectors = { 0, 0, 0, 0, 0, 0, 0, 0 }, seen = {}, frame = frame }
		Engine.approach = A
	end
	local f = 0.5 ^ ((frame - A.frame) / (30 * 300))
	for i = 1, 8 do
		A.sectors[i] = A.sectors[i] * f
	end
	A.frame = frame
	for _, t in ipairs(threats) do
		if not t.air and not A.seen[t.id] then
			A.seen[t.id] = frame
			local a = atan2(t.z - Engine.homeZ, t.x - Engine.homeX)
			local s = floor((a + pi) / (2 * pi) * 8 + 0.5) % 8 + 1
			A.sectors[s] = A.sectors[s] + 1
		end
	end
	for id, fr in pairs(A.seen) do
		if frame - fr > 30 * 600 then
			A.seen[id] = nil
		end
	end
end

-- the busiest approach (unit vector from home), when at least 3 intruders came that way lately
function Engine.approachDir()
	local A = Engine.approach
	if not A then
		return nil
	end
	local best, bestN = nil, 3
	for i = 1, 8 do
		if A.sectors[i] >= bestN then
			best, bestN = i, A.sectors[i]
		end
	end
	if not best then
		return nil
	end
	local a = (best - 1) / 8 * 2 * pi - pi
	return cos(a), sin(a), bestN, best
end

function Engine.approachText()
	local dx, dz, n, s = Engine.approachDir()
	if not dx then
		return nil
	end
	-- map z grows south: screen-north is -z
	return sformat("most intruders lately came from the %s of our base (%.0f)", Const.SECTOR_NAMES[s], n)
end

-- the two economy guards nearest the commander escort it (recomputed every combat pass)
function Engine.escort(sub, unitID)
	local com = Engine.commanderID
	if not com or not isAlive(com) then
		return false
	end
	if Engine.escortFrame ~= frame then
		Engine.escortFrame, Engine.escorts = frame, {}
		local cx, _, cz = spGetUnitPosition(com)
		local list = {}
		for u in pairs(sub.units) do
			local d = unitDef(u)
			local st = ustate[u]
			if d and d.combat and not d.aaOnly and not (st and (st.retreating or st.manual)) then
				local x, _, z = spGetUnitPosition(u)
				if x and cx then
					list[#list + 1] = { u = u, d = dist2(x, z, cx, cz) }
				end
			end
		end
		tsort(list, function(a, b)
			return a.d < b.d
		end)
		for i = 1, min(Engine.D.economy.escorts, #list) do
			Engine.escorts[list[i].u] = true
		end
	end
	return Engine.escorts[unitID] or false
end

-- is (x, z) close to something we can't afford to lose (a factory, the commander)?
function Engine.nearVital(x, z)
	for _, v in ipairs(Engine.vitals or {}) do
		if dist2(x, z, v.x, v.z) < 700 * 700 then
			return true
		end
	end
	return false
end

-- territory (sc_territory.lua): cells near our structures are ours; pickets are the frontier points worth
-- holding (facing the enemy, where intruders came from, what they protect). Defense zones sit on them and
-- the economy's guards screen the side ones, so raids can't simply walk around the army.
function Engine.refreshTerritory()
	if not Engine.homeX then
		return
	end
	local list = {}
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d = unitDef(u)
		if d and not d.mobile and not spGetUnitIsBeingBuilt(u) then
			local x, _, z = spGetUnitPosition(u)
			if x then
				list[#list + 1] = { x = x, z = z, value = d.cost }
			end
		end
	end
	-- the map's walls (steep slopes, deep water) once: they cut the frontier down to the real approaches
	if not Engine.terrainDone then
		Engine.terrainDone = true
		Engine.terr.terrain(function(x, z)
			return spGetGroundHeight(x, z) or 0
		end)
	end
	Engine.terr.update(list, { Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2 })
	local A = Engine.approach
	Engine.pickets = Engine.terr.pickets(5, { Engine.homeX, Engine.homeZ }, { Engine.enemyX or MAP_X / 2, Engine.enemyZ or MAP_Z / 2 }, A and A.sectors)
end

-- turrets have a budget (strong players put their metal into the army): metal of turrets we have plus
-- the one we'd add, against sc_doctrine's turrets.budget(minute, army value)
function Engine.turretBudget(extra, mult)
	local planned_ = 0
	for _, p in pairs(planned) do
		if defs[p.defID].staticDef and not defs[p.defID].aaOnly then
			planned_ = planned_ + defs[p.defID].cost
		end
	end
	return (Engine.turretValue or 0) + planned_ + (extra or 0) <= Engine.turretBudgetValue() * (mult or 1)
end

function Engine.minute()
	return frame / 1800
end

-- the sub-commander's autonomy settings (sc_doctrine.lua: light / balanced / full)
function Engine.auto(sub)
	return Engine.D.autonomy[sub.autonomy or "balanced"] or Engine.D.autonomy.balanced
end

-- is (x, z) in our base: near home, or inside a non-army sub-commander's zones
function Engine.inBase(x, z)
	if Engine.homeX and dist2(x, z, Engine.homeX, Engine.homeZ) < 1500 * 1500 then
		return true
	end
	for _, sub in ipairs(subs) do
		if sub.role ~= "army" and sub.role ~= "intelligence" then
			for _, zone in ipairs(sub.zones) do
				if Zone.contains(zone, x, z, 200) then
					return true
				end
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

function widget:GameFrame(n)
	frame = n
	if n - Engine.tm.builtFrame >= Engine.D.threat.every then
		Engine.refreshWorld(n)
	end
	if n % THINK_EVERY ~= 0 then
		return
	end
	local combatPass = n % COMBAT_EVERY == 0
	econUpdate()
	Player.refresh()
	if n % 60 == 0 then
		Player.refreshPriorities()
	end
	if n % 300 == 0 then
		Engine.adoptFactories()
		Enemy.prune()
		for _, sub in ipairs(subs) do
			Engine.updateAutoZones(sub)
		end
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
			Decider.refreshTurrets(sub)
			for _, t in ipairs(sub.threats) do
				baseThreats[#baseThreats + 1] = t
			end
		end
		Engine.noteApproaches(baseThreats)
		Engine.refreshTeam()
		Engine.refreshStyle()
		Engine.learnedStage()
	end
	if combatPass then
		for _, sub in ipairs(subs) do
			Tactics.updatePush(sub)
			Tactics.raid(sub)
			Tactics.airRaid(sub)
			Tactics.air(sub)
			Tactics.responders(sub)
			Tactics.squad(sub)
		end
	end
	local F = Engine.D.micro.focus
	if F.on and F.mode == "settarget" and n % (F.fireEvery or 15) == 0 then
		for _, sub in ipairs(subs) do
			Engine.fireControl(sub)
		end
	end
	if n % 60 == 30 then
		Engine.strategicControl()
	end
	local G = Engine.D.micro.dodge
	if G and G.on and n % (G.every or 6) == 0 then
		for _, sub in ipairs(subs) do
			Engine.dodge(sub)
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
		out[#out + 1] = { id = sub.id, name = sub.name, role = sub.role, posture = sub.posture, paused = sub.paused, zones = not sub.autoZones and sub.zones or {}, autoZones = sub.autoZones or false, autonomy = sub.autonomy, raids = sub.raids, colorIndex = sub.colorIndex, units = units, focus = focus, ai = sub.ai, directive = sub.directive }
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
		-- older saves have no flag: zones were drawn (or claimed) by then
		if s.autoZones ~= nil then
			sub.autoZones = s.autoZones
		else
			sub.autoZones = #sub.zones == 0
		end
		sub.autonomy = Engine.D.autonomy[s.autonomy or ""] and s.autonomy or "balanced"
		sub.raids = s.raids
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
	if game.armyStyle then
		Engine.setArmyStyle(game.armyStyle)
	end
	if game.commander then
		Engine.setCommander(game.commander.mode or "auto")
		Engine.setCommander(game.commander.personality or "careful")
	end
	activeSub = subs[1]
end

function widget:GetConfigData()
	local data = { panelX = panel.x, panelY = panel.y, collapsed = panel.collapsed }
	local f = spGetGameFrame()
	if f > 0 and #subs > 0 then
		data.game = { map = Game.mapName, team = myTeam, frame = f, time = os and os.time and os.time() or nil, subs = serialize(),
			commander = { mode = Engine.comMode, personality = Engine.comPersonality }, armyStyle = Engine.armyStyle }
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
	local _, _, _, _, side = Spring.GetTeamInfo(myTeam)
	Engine.applyFaction(side)
	Engine.applyLearned()
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
