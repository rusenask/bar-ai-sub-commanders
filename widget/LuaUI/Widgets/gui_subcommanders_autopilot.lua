-- Sub-Commanders Autopilot: plays a whole team through sub-commanders, like a player who delegates
-- everything. It builds the first lab with the commander, hands the commander and that lab to an Economy
-- sub-commander, then creates Defense, Army (with a second lab), Air Defense and Intelligence as
-- constructors become available, gives each a standing order, and orders more labs for the Army when metal
-- piles up. Any faction.
--
-- Uses: the bot player in a local game against sub-commanders (play/vs.sh), or handing your own team over
-- (enable it in the widget list; enabled mid-game it adopts what you have).
-- "/luaui autopilot ai" turns the AI strategist on for its sub-commanders, "/luaui autopilot rules" off.
-- The file autopilot.txt in the write dir ("ai" or "rules") sets the default.
function widget:GetInfo()
	return {
		name = "Sub-Commanders Autopilot",
		desc = "Plays the whole team through sub-commanders (needs Sub-Commanders)",
		author = "bar-ai-sub-commanders",
		layer = 10,
		enabled = false,
	}
end

local SC
local defs
local myTeam = Spring.GetMyTeamID()
local useAI = (VFS.LoadFile("autopilot.txt", VFS.RAW) or ""):find("ai") ~= nil
local ids = {}
local st = { stage = nil }
local home, enemy -- {x, z}
local labDef, conDefs -- the faction's bot lab and the constructors it makes
local labs = {} -- our finished labs, in order

local function say(text)
	Spring.Echo("[Autopilot] " .. text)
end

-- a circle zone a fraction of the way from home toward the enemy, and the unit direction
local function towardEnemy(f, r)
	local dx, dz = enemy.x - home.x, enemy.z - home.z
	local d = math.max(math.sqrt(dx * dx + dz * dz), 1)
	return { kind = "circle", x = home.x + dx * f, z = home.z + dz * f, r = r }, dx / d, dz / d
end

local function facingFor(dx, dz)
	if math.abs(dx) > math.abs(dz) then
		return dx > 0 and 1 or 3
	end
	return dz > 0 and 0 or 2
end

-- a spot for a building near (x, z), searching outward
local function findSpot(defID, x, z, facing)
	for ring = 0, 12 do
		for k = 0, math.max(ring * 6, 1) - 1 do
			local a = k / math.max(ring * 6, 1) * 2 * math.pi
			local px, pz = x + math.cos(a) * ring * 64, z + math.sin(a) * ring * 64
			local bx, by, bz = Spring.Pos2BuildPos(defID, px, Spring.GetGroundHeight(px, pz), pz, facing)
			if Spring.TestBuildOrder(defID, bx, by, bz, facing) > 0 then
				return bx, bz
			end
		end
	end
end

-- a build order counts as the player's (the sub-commander lets it finish, then resumes)
local function build(builder, defID, fx, fz, dx, dz)
	local facing = facingFor(dx, dz)
	local x, z = findSpot(defID, fx, fz, facing)
	if x then
		Spring.GiveOrderToUnit(builder, -defID, { x, Spring.GetGroundHeight(x, z), z, facing }, {})
		return true
	end
end

local function ownedBy(subID, defSet)
	local list = {}
	local sub = SC.get(subID)
	for _, u in ipairs(sub and sub.units or {}) do
		local defID = Spring.GetUnitDefID(u.id)
		if defID and defSet[defID] then
			list[#list + 1] = u.id
		end
	end
	return list
end

local function newSub(role, units, zone, directive)
	local id = SC.create(role)
	say(string.format("%s created with %d units: %s", role, units and #units or 0, directive))
	if units and #units > 0 then
		SC.assign(id, units)
	end
	if zone then
		SC.clearZones(id)
		SC.addZone(id, zone)
	end
	SC.setAI(id, useAI)
	SC.setDirective(id, directive)
	return id
end

-- the faction's bot lab (else any lab) from the commander's options, and the constructors it makes
local function learnFaction(com)
	local ud = UnitDefs[Spring.GetUnitDefID(com)]
	for _, opt in ipairs(ud.buildOptions or {}) do
		local d = defs[opt]
		if d and d.factory and (not labDef or UnitDefs[opt].name:find("lab$")) then
			labDef = opt
		end
	end
	conDefs = {}
	for _, opt in ipairs(labDef and UnitDefs[labDef].buildOptions or {}) do
		if defs[opt] and defs[opt].builder then
			conDefs[opt] = true
		end
	end
end

local function findEnemy()
	local best
	for _, t in ipairs(Spring.GetTeamList()) do
		if t ~= Spring.GetGaiaTeamID() and not Spring.AreTeamsAllied(t, myTeam) then
			local x, _, z = Spring.GetTeamStartPosition(t)
			if x and x > 0 then
				local d = (x - home.x) ^ 2 + (z - home.z) ^ 2
				if not best or d < best.d then
					best = { x = x, z = z, d = d }
				end
			end
		end
	end
	-- not visible to us: assume the mirrored position
	return best or { x = Game.mapSizeX - home.x, z = Game.mapSizeZ - home.z }
end

local function start(frame)
	local com
	for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
		local d = defs[Spring.GetUnitDefID(u)]
		if d and d.commander then
			com = u
		end
	end
	if not com then
		return
	end
	local x, _, z = Spring.GetUnitPosition(com)
	home = { x = x, z = z }
	enemy = findEnemy()
	learnFaction(com)
	if not labDef then
		say("no lab in the commander's build options: not starting")
		st.stage = "off"
		return
	end
	if frame < 30 * 60 and #SC.list() == 0 then
		ids.eco = newSub("economy", { com }, nil, "grow the economy: take every safe metal spot, keep energy ahead of spending")
		st.stage = "opener"
		say("playing the team: " .. (useAI and "AI strategist on" or "rules only"))
		return
	end
	-- enabled mid-game: take over what's there
	local cons, combat, factories = {}, {}, {}
	for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
		local d = defs[Spring.GetUnitDefID(u)]
		if d and not SC.ownerOf(u) and not Spring.GetUnitIsBeingBuilt(u) then
			if d.builder and not d.commander then
				cons[#cons + 1] = u
			elseif d.combat then
				combat[#combat + 1] = u
			elseif d.factory then
				factories[#factories + 1] = u
			end
		end
	end
	local ecoUnits = { com, factories[1] }
	for i = 2, #cons do
		ecoUnits[#ecoUnits + 1] = cons[i]
	end
	ids.eco = newSub("economy", ecoUnits, nil, "grow the economy: take every safe metal spot, keep energy ahead of spending")
	ids.def = newSub("defense", { cons[1] }, (towardEnemy(0.22, 1000)), "hold the side of the base facing the enemy")
	local armyUnits = combat
	for i = 2, #factories do
		armyUnits[#armyUnits + 1] = factories[i]
	end
	ids.army = newSub("army", armyUnits, (towardEnemy(0.35, 1100)), "control our half of the map; attack when we are clearly stronger")
	for i, f in ipairs(factories) do
		labs[i] = f
	end
	st.stage = 3
	st.startFrame = frame - 30 * 60 * 4
	say("took over the team: " .. (useAI and "AI strategist on" or "rules only"))
end

local function count(pred)
	local n = 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
		local d = defs[Spring.GetUnitDefID(u)]
		if d and not Spring.GetUnitIsBeingBuilt(u) and pred(d) then
			n = n + 1
		end
	end
	return n
end

local function labsBeingBuilt()
	local n = 0
	for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
		if Spring.GetUnitDefID(u) == labDef and Spring.GetUnitIsBeingBuilt(u) then
			n = n + 1
		end
	end
	return n
end

local function step(n)
	local t = n - (st.startFrame or 0)
	if st.stage == "opener" then
		-- the commander takes the first extractors and generators (Economy does that), then builds the lab
		local mex, gen = count(function(d) return d.mex > 0 end), count(function(d) return d.energy > 0 end)
		if (mex >= 2 and gen >= 2) or t > 30 * 75 then
			local _, dx, dz = towardEnemy(0.1, 0)
			local com
			for _, u in ipairs(SC.get(ids.eco).units) do
				local d = defs[Spring.GetUnitDefID(u.id) or -1]
				if d and d.commander then
					com = u.id
				end
			end
			if com and build(com, labDef, home.x + dx * 220, home.z + dz * 220, dx, dz) then
				say("opener done, the commander builds " .. (defs[labDef].human or UnitDefs[labDef].name))
				st.stage = 0
				st.since = n
			end
		end
	elseif st.stage == 0 then
		if labs[1] then
			SC.assign(ids.eco, { labs[1] })
			st.stage = 1
		elseif n - st.since > 30 * 120 and labsBeingBuilt() == 0 then
			st.stage = "opener" -- the lab never started: order it again
		end
	elseif st.stage == 1 then
		local cons = ownedBy(ids.eco, conDefs)
		if #cons >= 3 then
			local zone, dx, dz = towardEnemy(0.22, 1000)
			ids.def = newSub("defense", { cons[1] }, zone, "hold the side of the base facing the enemy")
			build(cons[2], labDef, home.x + dx * 380 - dz * 350, home.z + dz * 380 + dx * 350, dx, dz)
			say("second lab ordered for the Army")
			st.stage, st.since, st.tries = 2, n, 0
		end
	elseif st.stage == 2 then
		if labs[2] then
			ids.army = newSub("army", { labs[2] }, (towardEnemy(0.35, 1100)), "control our half of the map; attack when we are clearly stronger")
			st.stage = 3
		elseif n - st.since > 30 * 90 and labsBeingBuilt() == 0 then
			-- the second lab never started: order it again, a bit elsewhere
			local cons = ownedBy(ids.eco, conDefs)
			local _, dx, dz = towardEnemy(0.1, 0)
			if cons[1] then
				st.tries = st.tries + 1
				local a = st.tries * 2.1
				build(cons[1], labDef, home.x + dx * 300 + math.cos(a) * 450, home.z + dz * 300 + math.sin(a) * 450, dx, dz)
			end
			st.since = n
		end
	elseif st.stage == 3 and t >= 30 * 60 * 4 then
		local cons = ownedBy(ids.eco, conDefs)
		if #cons >= 3 then
			SC.assign(ids.def, { cons[1] })
			st.stage = 4
		end
	elseif st.stage == 4 and t >= 30 * 60 * 6 then
		local cons = ownedBy(ids.eco, conDefs)
		if #cons >= 3 then
			ids.aa = newSub("airdefense", { cons[1] }, nil, "keep the base and the economy safe from air")
			st.stage = 5
		end
	elseif st.stage == 5 and t >= 30 * 60 * 8 then
		local cons = ownedBy(ids.eco, conDefs)
		if #cons >= 3 then
			ids.intel = newSub("intelligence", { cons[1] }, (towardEnemy(0.3, 1500)), "watch the approaches to our base and take out enemy radar")
			st.stage = 6
		end
	end
	-- another lab for the Army when metal keeps piling up
	-- (frames can be skipped while the game runs fast: act when due, not on exact frames)
	if type(st.stage) == "number" and st.stage >= 3 and n >= (st.nextSecond or 0) then
		st.nextSecond = n + 30
		local m, mS = Spring.GetTeamResources(myTeam, "metal")
		st.overflow = (m > mS * 0.8) and (st.overflow or 0) + 1 or 0
		if st.overflow >= 60 and #labs < 5 and not st.labOrdered then
			local cons = ownedBy(ids.eco, conDefs)
			if #cons >= 2 then
				local _, dx, dz = towardEnemy(0.1, 0)
				local a = #labs * 1.3
				build(cons[1], labDef, home.x + dx * 250 + math.cos(a) * 500, home.z + dz * 250 + math.sin(a) * 500, dx, dz)
				say("metal piling up: another lab ordered for the Army")
				st.labOrdered, st.labCount, st.overflow = n, #labs, 0
			end
		end
	end
	if st.labOrdered then
		if #labs > st.labCount then
			SC.assign(ids.army, { labs[#labs] })
			st.labOrdered = nil
		elseif n - st.labOrdered > 30 * 120 then
			st.labOrdered = nil
		end
	end
end

-- a status line every two minutes (the bot's log is the way to follow it: play/bot.log)
local function status(n)
	local _, _, _, mInc = Spring.GetTeamResources(myTeam, "metal")
	local _, _, _, eInc = Spring.GetTeamResources(myTeam, "energy")
	local parts = {}
	for _, s in ipairs(SC.list()) do
		parts[#parts + 1] = string.format("%s B%d F%d C%d", s.name, s.counts.builders, s.counts.factories, s.counts.combat)
	end
	say(string.format("%d:%02d metal +%.1f energy +%.0f units %d labs %d | %s", n / 1800, (n / 30) % 60, mInc or 0, eInc or 0,
		#Spring.GetTeamUnits(myTeam), #labs, table.concat(parts, ", ")))
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == myTeam and labDef and unitDefID == labDef then
		labs[#labs + 1] = unitID
	end
end

function widget:UnitDestroyed(unitID)
	for i, u in ipairs(labs) do
		if u == unitID then
			table.remove(labs, i)
			if st.labCount and st.labCount > #labs then
				st.labCount = #labs
			end
			return
		end
	end
end

function widget:GameFrame(n)
	SC = WG.SubCommanders
	if not SC or st.stage == "off" then
		return
	end
	if Spring.GetSpectatingState() then
		return
	end
	if not st.stage then
		if n >= 10 then
			start(n)
		end
		return
	end
	step(n)
	if n >= (st.nextStatus or 30 * 120) then
		st.nextStatus = (math.floor(n / 3600) + 1) * 3600
		status(n)
	end
end

function widget:TextCommand(cmd)
	local arg = cmd:match("^autopilot%s+(%a+)")
	if not arg or not SC then
		return false
	end
	useAI = arg == "ai"
	for _, id in pairs(ids) do
		SC.setAI(id, useAI)
	end
	say(useAI and "AI strategist on" or "rules only")
	return true
end

function widget:Initialize()
	defs = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)
end
