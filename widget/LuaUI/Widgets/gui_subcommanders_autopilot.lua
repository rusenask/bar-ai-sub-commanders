-- Sub-Commanders Autopilot: plays a whole team through sub-commanders at full autonomy (design/engine.md).
-- It hands the commander to an Economy sub-commander (which builds the labs itself as income grows), then
-- creates Defense and Army (fed by the economy's lab until it has its own), Air Defense and Intelligence
-- as constructors become available. No zones: each works where its role calls for (auto zones). Any
-- faction.
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
local labDef, conDefs -- the faction's bot lab and the constructors it makes

local function say(text)
	Spring.Echo("[Autopilot] " .. text)
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
		SC.addZone(id, zone)
	end
	if SC.setAutonomy then
		SC.setAutonomy(id, "full")
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
	ids.def = newSub("defense", { cons[1] }, nil, "hold the side of the base facing the enemy")
	local armyUnits = combat
	for i = 2, #factories do
		armyUnits[#armyUnits + 1] = factories[i]
	end
	ids.army = newSub("army", armyUnits, nil, "control our half of the map; attack when we are clearly stronger")
	st.stage = 3
	st.startFrame = frame - 30 * 60 * 4
	say("took over the team: " .. (useAI and "AI strategist on" or "rules only"))
end

-- a status line every two minutes (the bot's log is the way to follow it: play/bot.log)
local function status(n)
	local _, _, _, mInc = Spring.GetTeamResources(myTeam, "metal")
	local _, _, _, eInc = Spring.GetTeamResources(myTeam, "energy")
	local parts = {}
	for _, s in ipairs(SC.list()) do
		parts[#parts + 1] = string.format("%s B%d F%d C%d", s.name, s.counts.builders, s.counts.factories, s.counts.combat)
	end
	say(string.format("%d:%02d metal +%.1f energy +%.0f units %d | %s", n / 1800, (n / 30) % 60, mInc or 0, eInc or 0,
		#Spring.GetTeamUnits(myTeam), table.concat(parts, ", ")))
end

local function step(n)
	local t = n - (st.startFrame or 0)
	local cons = ownedBy(ids.eco, conDefs)
	if st.stage == "opener" then
		-- the economy (full autonomy) builds the first lab itself; Defense and Army once constructors are out
		if #cons >= 3 or (t > 30 * 150 and #cons >= 1) then
			ids.def = newSub("defense", { cons[1] }, nil, "hold the side of the base facing the enemy")
			ids.army = newSub("army", {}, nil, "control our half of the map; attack when we are clearly stronger")
			st.stage = 3
		end
	elseif st.stage == 3 and t >= 30 * 60 * 4 and #cons >= 3 then
		SC.assign(ids.def, { cons[1] })
		st.stage = 4
	elseif st.stage == 4 and t >= 30 * 60 * 6 and #cons >= 3 then
		ids.aa = newSub("airdefense", { cons[1] }, nil, "keep the base and the economy safe from air")
		st.stage = 5
	elseif st.stage == 5 and t >= 30 * 60 * 8 and #cons >= 3 then
		ids.intel = newSub("intelligence", { cons[1] }, nil, "watch the approaches to our base and take out enemy radar")
		st.stage = 6
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
