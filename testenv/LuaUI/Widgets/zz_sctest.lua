-- Test harness for gui_subcommanders.lua (not shipped). Scenario comes from sctest_scenario.txt
function widget:GetInfo()
	return { name = "ZZ SubCommander Test", layer = 100, enabled = true }
end

-- BAR from test-31614 sandboxes user widgets: they read only under LuaUI/ and write only under
-- LuaUI/Config/ (and LuaUI/Widgets/). Inputs come from LuaUI/Config/ first, the write dir's root second;
-- output goes to the root where allowed, else LuaUI/Config/ (the scripts look in both).
local function loadInput(name)
	return VFS.LoadFile("LuaUI/Config/" .. name, VFS.RAW) or VFS.LoadFile(name, VFS.RAW)
end
local function openOutput(name)
	return io and io.open and (io.open(name, "w") or io.open("LuaUI/Config/" .. name, "w"))
end
local scenario = (loadInput("sctest_scenario.txt") or "eco"):gsub("%s+", "")
-- "SPEED LOCKSTEP" from run.sh: game speed override, and real time (1x) while the AI strategist thinks
local speedOverride, lockstep = (loadInput("sctest_speed.txt") or ""):match("^(%d*)%s*(%d*)")
speedOverride, lockstep = tonumber(speedOverride), lockstep == "1"
local myTeam = Spring.GetMyTeamID()
local startOffset -- frame our commander appeared (scenario time 0)
local SC
local ids = {}
local byName = {}
-- our faction's units the scripted player uses (lab, constructor, vehicle plant, T2 lab): Legion's,
-- Armada's or Cortex's by the commander's name prefix (legcom / armcom / corcom), set at game start
local U = { lab = "leglab", ck = "legck", vp = "legvp", alab = "legalab" }
local function setFaction()
	for _, u in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
		local name = UnitDefs[Spring.GetUnitDefID(u)].name
		if UnitDefs[Spring.GetUnitDefID(u)].customParams.iscommander then
			local p = name:sub(1, 3)
			U = { lab = p .. "lab", ck = p .. "ck", vp = p .. "vp", alab = p .. "alab" }
			return p
		end
	end
end
-- duels against BARbarian: our scripted player (duel = with the AI strategist, duelrules = rules only), or
-- the Sub-Commanders Autopilot widget playing the team (autopilot; run.sh enables it)
local isDuel = scenario == "duel" or scenario == "duelrules" or scenario == "autopilot"
-- duels last DUEL_MINUTES (run.sh writes sctest_minutes.txt; default 25)
local duelMinutes = tonumber((loadInput("sctest_minutes.txt") or ""):match("%d+")) or 25
local endFrame = (isDuel and 30 * 60 * duelMinutes) or (scenario == "vsai" and 30 * 60 * 9) or (scenario == "ai" and 30 * 60 * 4) or 30 * 60 * 6
local outFile = openOutput("sctest_out.txt")
local function out(...)
	local parts = { "[" .. Spring.GetGameFrame() .. "]" }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	local line = table.concat(parts, " ")
	if outFile then
		outFile:write(line .. "\n")
		outFile:flush()
	else
		Spring.Echo("[SCTEST] " .. line)
	end
end

local function report()
	local m, mS, _, mInc = Spring.GetTeamResources(myTeam, "metal")
	local e, eS, _, eInc = Spring.GetTeamResources(myTeam, "energy")
	out(string.format("t=%ds metal %.0f/%.0f +%.1f energy %.0f/%.0f +%.1f", Spring.GetGameFrame() / 30, m, mS, mInc, e, eS, eInc))
	local counts = {}
	for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
		local defID = Spring.GetUnitDefID(u)
		local n = defID and UnitDefs[defID].name or "?"
		counts[n] = (counts[n] or 0) + 1
	end
	local parts = {}
	for n, c in pairs(counts) do
		parts[#parts + 1] = n .. "=" .. c
	end
	table.sort(parts)
	out("units: " .. table.concat(parts, " "))
	for _, s in ipairs(SC.list()) do
		local tasks = {}
		for _, u in ipairs(s.units) do
			if u.task then
				tasks[#tasks + 1] = tostring(u.name) .. ":" .. u.task .. (u.manual and "(manual)" or "")
			end
		end
		out(string.format("  [%d] %s %s/%s B%d F%d C%d threats=%d spend=%.1f | %s", s.id, s.name, s.role, s.posture, s.counts.builders, s.counts.factories, s.counts.combat, s.threats, s.spendMetal, table.concat(tasks, ", ")))
		if s.ai then
			out("     ai status: " .. tostring(s.aiStatus) .. " | orders: " .. tostring(s.directive))
		end
		for i = math.min(#s.recent, scenario == "ai" and 8 or 4), 1, -1 do
			out("     " .. (s.recent[i].ai and "AI: " or "log: ") .. s.recent[i].text)
		end
	end
end

-- the player orders what they have selected (the widget ignores orders to unselected units)
-- (the order arrives a frame later, so the selection is cleared a few frames after)
local deselectAt
local function playerOrder(unitID, cmdID, params, opts)
	Spring.SelectUnitArray({ unitID })
	Spring.GiveOrderToUnit(unitID, cmdID, params, opts or {})
	deselectAt = Spring.GetGameFrame() + 30
end

local function give(n, name, team, x, z)
	Spring.SendCommands(string.format("give %d %s %d @%d,%d,%d", n, name, team, x, Spring.GetGroundHeight(x, z), z))
end

local cx, cz

-- analysis lines for cmd/gamereport (duels): "eco" every minute in the data logger's terms (zz_datalog.lua,
-- so our games compare with strong players' replays), and "lost" / "killed" for every unit that dies
local kinds = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)
local stall = { energy = 0, overflow = 0 } -- seconds with energy empty / metal full

local function ecoLine(n)
	local m = { mex = 0, gen = 0, factories = 0, builders = 0, army = 0, turrets = 0 }
	for _, u in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
		local d = kinds[Spring.GetUnitDefID(u) or -1]
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
			if d.mobile and d.armed and not d.builder and not d.commander then
				m.army = m.army + d.cost
			elseif d.staticDef then
				m.turrets = m.turrets + d.cost
			end
		end
	end
	local _, _, _, mInc = Spring.GetTeamResources(myTeam, "metal")
	local _, _, _, eInc = Spring.GetTeamResources(myTeam, "energy")
	out(string.format("eco minute=%d metalIncome=%.1f energyIncome=%.0f mex=%d generators=%d factories=%d builders=%d army=%.0f turrets=%.0f energyStalled=%d metalOverflow=%d",
		n / 1800, mInc or 0, eInc or 0, m.mex, m.gen, m.factories, m.builders, m.army, m.turrets, stall.energy, stall.overflow))
end

local function sampleStalls()
	local m, mS = Spring.GetTeamResources(myTeam, "metal")
	local e, eS = Spring.GetTeamResources(myTeam, "energy")
	if e and eS and eS > 0 and e < 0.03 * eS then
		stall.energy = stall.energy + 1
	end
	if m and mS and mS > 0 and m > 0.97 * mS then
		stall.overflow = stall.overflow + 1
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	if not isDuel or not startOffset then
		return
	end
	local d = kinds[unitDefID]
	-- enemies: every one that dies where we can see it (widgets rarely get the attacker of an enemy unit)
	local mine = unitTeam == myTeam
	if not d or (not mine and Spring.AreTeamsAllied(unitTeam, myTeam)) then
		return
	end
	local x, _, z = Spring.GetUnitPosition(unitID)
	out(string.format("%s minute=%d kind=%s name=%s cost=%d x=%d z=%d", mine and "lost" or "killed",
		(Spring.GetGameFrame() - startOffset) / 1800, ((d.kind or "?"):gsub(" ", "_")), UnitDefs[unitDefID].name, d.cost, x or -1, z or -1))
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == myTeam then
		local n = UnitDefs[unitDefID].name
		byName[n] = byName[n] or {}
		table.insert(byName[n], unitID)
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, playerID, fromSynced, fromLua)
	if scenario == "dbg" and unitID == ids.com then
		out(string.format("UnitCommand cmd=%s player=%s synced=%s lua=%s", tostring(cmdID), tostring(playerID), tostring(fromSynced), tostring(fromLua)))
	end
end

local function queueOf(u)
	local q = Spring.GetUnitCommands(u, 5) or {}
	local parts = {}
	for _, c in ipairs(q) do
		parts[#parts + 1] = c.id .. "@" .. math.floor(c.params[1] or 0) .. "," .. math.floor(c.params[3] or 0)
	end
	local x, _, z = Spring.GetUnitPosition(u)
	return string.format("pos=%d,%d queue=[%s]", x, z, table.concat(parts, " "))
end

--------------------------------------------------------------------------------
-- duel / duelrules: 1v1 against BARbarian with no cheats. The harness plays a
-- light-touch human who delegates: builds the first lab with the commander,
-- hands units and factories to sub-commanders and gives standing orders. duel
-- runs the AI strategist (test bridge on 17878), duelrules only the rule engine.
--------------------------------------------------------------------------------

local duelState = { stage = 0 }
local enemyX, enemyZ

local function towardEnemy(f, r)
	local dx, dz = enemyX - cx, enemyZ - cz
	local d = math.max(math.sqrt(dx * dx + dz * dz), 1)
	return { kind = "circle", x = cx + dx * f, z = cz + dz * f, r = r }, dx / d, dz / d
end

-- a spot for a building near (x, z), searching outward
local function findSpot(defName, x, z, facing)
	local defID = UnitDefNames[defName].id
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

local function facingFor(dx, dz)
	if math.abs(dx) > math.abs(dz) then
		return dx > 0 and 1 or 3
	end
	return dz > 0 and 0 or 2
end

local function playerBuild(builder, defName, fx, fz, dx, dz)
	local facing = facingFor(dx, dz)
	local x, z = findSpot(defName, fx, fz, facing)
	if x then
		playerOrder(builder, -UnitDefNames[defName].id, { x, Spring.GetGroundHeight(x, z), z, facing })
		out(string.format("player: %s builds %s at %d,%d", UnitDefs[Spring.GetUnitDefID(builder)].name, defName, x, z))
	end
end

local function ownedBy(subID, name)
	local list = {}
	for _, s in ipairs(SC.list()) do
		if s.id == subID then
			for _, u in ipairs(s.units) do
				if u.name == name then
					list[#list + 1] = u.id
				end
			end
		end
	end
	return list
end

local function teamStats(team)
	local n = Spring.GetTeamStatsHistory(team)
	local h = n and n > 0 and Spring.GetTeamStatsHistory(team, n)
	h = h and h[1]
	if not h then
		return "n/a"
	end
	return string.format("metalProduced=%.0f energyProduced=%.0f unitsProduced=%d unitsKilled=%d unitsDied=%d damageDealt=%.0f damageReceived=%.0f",
		h.metalProduced or 0, h.energyProduced or 0, h.unitsProduced or 0, h.unitsKilled or 0, h.unitsDied or 0, h.damageDealt or 0, h.damageReceived or 0)
end

local function armyValue(team)
	local v = 0
	for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
		local ud = UnitDefs[Spring.GetUnitDefID(u)]
		if ud and (ud.speed or 0) > 0 and #(ud.weapons or {}) > 0 and not ud.isBuilder then
			v = v + ud.metalCost
		end
	end
	return v
end

local function duelResult(why)
	if duelState.done then
		return
	end
	duelState.done = true
	pcall(report)
	out("RESULT " .. why .. string.format(" t=%ds", Spring.GetGameFrame() / 30))
	out("  us:    " .. teamStats(myTeam) .. string.format(" armyValue=%.0f", armyValue(myTeam)))
	out("  enemy: " .. teamStats(1))
	out("DONE")
	Spring.SendCommands("screenshot png", "quitforce")
end

-- what every duel logs and checks, whoever plays
local function duelWatch(n)
	if n % 30 == 0 then
		sampleStalls()
	end
	if n % (30 * 60) == 0 then
		out(string.format("value: army us=%.0f  units us=%d", armyValue(myTeam), #Spring.GetTeamUnits(myTeam)))
		if n > 0 then
			ecoLine(n)
		end
	end
	-- commanders can spawn a few frames in: only a team that had units can have lost them
	local count = #Spring.GetTeamUnits(myTeam)
	duelState.hadUnits = duelState.hadUnits or count > 0
	if duelState.hadUnits and count == 0 then
		duelResult("LOSS (no units left)")
	end
end

local function duel(n)
	if scenario == "autopilot" then
		if n == 12 then
			Spring.SendCommands("setmaxspeed 20", "setspeed 3")
			out("scenario autopilot")
		end
		duelWatch(n)
		return
	end
	local ai = scenario == "duel"
	if n == 12 then
		Spring.SendCommands("setmaxspeed 20", "setspeed 3")
		enemyX, _, enemyZ = Spring.GetTeamStartPosition(1)
		if not enemyX or enemyX <= 0 then
			-- not available to us: assume the mirrored position
			enemyX, enemyZ = Game.mapSizeX - cx, Game.mapSizeZ - cz
		end
		out(string.format("enemy start %d,%d  us %d,%d  ai=%s", enemyX, enemyZ, cx, cz, tostring(ai)))
		local com = Spring.GetTeamUnits(myTeam)[1]
		ids.com = com
		out("faction " .. (setFaction() or "?"))
		ids.eco = SC.create("economy")
		SC.assign(ids.eco, { com })
		SC.setAI(ids.eco, ai)
		SC.setDirective(ids.eco, "grow the economy: take every safe metal spot, keep energy ahead of spending")
		duelState.stage = -1
	end
	-- a normal opener: the commander takes the first extractors and generators (Economy does that),
	-- then the player has it build the lab
	if duelState.stage == -1 then
		local mex, gen = 0, 0
		for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
			local ud = UnitDefs[Spring.GetUnitDefID(u)]
			if not Spring.GetUnitIsBeingBuilt(u) then
				if (ud.extractsMetal or 0) > 0 then
					mex = mex + 1
				elseif (ud.speed or 0) == 0 and ((ud.windGenerator or 0) > 0 or (ud.energyMake or 0) > 0) then
					gen = gen + 1
				end
			end
		end
		if (mex >= 2 and gen >= 2) or n > 30 * 75 then
			duelState.stage = 0
			local _, dx, dz = towardEnemy(0.1, 0)
			playerBuild(ids.com, U.lab, cx + dx * 220, cz + dz * 220, dx, dz)
			out(string.format("player: opener done (%d extractors, %d generators), commander builds the lab", mex, gen))
		end
	elseif duelState.stage == 0 then
		local lab = (byName[U.lab] or {})[1]
		-- like a player who notices the lab never started: order it again, a bit elsewhere
		duelState.lab1Since = duelState.lab1Since or n
		if not lab and n - duelState.lab1Since > 30 * 60 then
			local started = false
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				started = started or (UnitDefs[Spring.GetUnitDefID(u)].name == U.lab)
			end
			if not started then
				duelState.lab1Tries = (duelState.lab1Tries or 0) + 1
				local _, dx, dz = towardEnemy(0.1, 0)
				local a = duelState.lab1Tries * 2.1
				playerBuild(ids.com, U.lab, cx + dx * 150 + math.cos(a) * 300, cz + dz * 150 + math.sin(a) * 300, dx, dz)
				out("player: first lab never started, ordered again")
			end
			duelState.lab1Since = n
		end
		if lab and not Spring.GetUnitIsBeingBuilt(lab) then
			duelState.stage = 1
			-- the first lab makes constructors for the economy
			SC.assign(ids.eco, { lab })
			out("player: first lab to Economy")
		end
	elseif duelState.stage == 1 then
		local cons = ownedBy(ids.eco, U.ck)
		if #cons >= 3 then
			-- like strong players: one lab until the economy carries a second (the economy's lab builds the
			-- army's units meanwhile, and metal piling up gets another lab below)
			duelState.stage = 3
			local zone = towardEnemy(0.22, 1000)
			ids.def = SC.create("defense")
			SC.assign(ids.def, { cons[1] })
			SC.addZone(ids.def, zone)
			SC.setAI(ids.def, ai)
			SC.setDirective(ids.def, "hold the side of the base facing the enemy")
			ids.army = SC.create("army")
			SC.addZone(ids.army, (towardEnemy(0.35, 1100)))
			SC.setAI(ids.army, ai)
			SC.setDirective(ids.army, "control our half of the map; attack when we are clearly stronger")
			out("player: Defense and Army created (one lab: the economy's builds the army)")
		end
	elseif duelState.stage == 2 then
		local labs = byName[U.lab] or {}
		local lab2 = labs[2]
		-- like a player who notices the lab never started: order it again, a bit elsewhere
		duelState.lab2Since = duelState.lab2Since or n
		if not lab2 and n - duelState.lab2Since > 30 * 90 then
			local frames = 0
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				if UnitDefs[Spring.GetUnitDefID(u)].name == U.lab and Spring.GetUnitIsBeingBuilt(u) then
					frames = frames + 1
				end
			end
			if frames == 0 then
				local cons = ownedBy(ids.eco, U.ck)
				local _, dx, dz = towardEnemy(0.1, 0)
				if cons[1] then
					duelState.lab2Tries = (duelState.lab2Tries or 0) + 1
					local a = duelState.lab2Tries * 2.1
					playerBuild(cons[1], U.lab, cx + dx * 300 + math.cos(a) * 450, cz + dz * 300 + math.sin(a) * 450, dx, dz)
					out("player: second lab never started, ordered again")
				end
			end
			duelState.lab2Since = n
		end
		if lab2 and not Spring.GetUnitIsBeingBuilt(lab2) then
			duelState.stage = 3
			ids.army = SC.create("army")
			SC.assign(ids.army, { lab2 })
			SC.clearZones(ids.army)
			SC.addZone(ids.army, (towardEnemy(0.35, 1100)))
			SC.setAI(ids.army, ai)
			SC.setDirective(ids.army, "control our half of the map; attack when we are clearly stronger")
			out("player: second lab to Army")
		end
	elseif duelState.stage == 3 and n >= 30 * 60 * 4 then
		-- recon early (radar net, scouts): raids that arrive unseen cost the most
		local cons = ownedBy(ids.eco, U.ck)
		if #cons >= 3 then
			duelState.stage = 4
			ids.intel = SC.create("intelligence")
			SC.assign(ids.intel, { cons[1] })
			SC.addZone(ids.intel, (towardEnemy(0.3, 1500)))
			SC.setAI(ids.intel, ai)
			SC.setDirective(ids.intel, "watch the approaches to our base and take out enemy radar")
			out("player: Intelligence created")
		end
	elseif duelState.stage == 4 and n >= 30 * 60 * 5 then
		local cons = ownedBy(ids.eco, U.ck)
		if #cons >= 3 then
			duelState.stage = 5
			SC.assign(ids.def, { cons[1] })
			out("player: second constructor to Defense")
		end
	elseif duelState.stage == 5 and n >= 30 * 60 * 7 then
		local cons = ownedBy(ids.eco, U.ck)
		if #cons >= 3 then
			duelState.stage = 6
			ids.aa = SC.create("airdefense")
			SC.assign(ids.aa, { cons[1] })
			SC.setAI(ids.aa, ai)
			SC.setDirective(ids.aa, "keep the base and the economy safe from air")
			out("player: Air Defense created")
		end
	elseif duelState.stage == 6 and n >= 30 * 60 * 10 then
		-- the air force: fighters over the base and army, gunships on raids, bombers on their economy
		local cons = ownedBy(ids.eco, U.ck)
		if #cons >= 3 then
			duelState.stage = 7
			ids.air = SC.create("air")
			SC.assign(ids.air, { cons[1] })
			SC.setAI(ids.air, ai)
			SC.setDirective(ids.air, "own the sky, hunt their raids, and bomb their economy where their anti-air is weak")
			out("player: Air Force created")
		end
	end
	-- like a real player answering "need a factory": another lab for the Army when metal keeps piling up
	if duelState.stage >= 3 and n % 30 == 0 then
		local m, mS = Spring.GetTeamResources(myTeam, "metal")
		duelState.overflow = (m > mS * 0.8) and (duelState.overflow or 0) + 1 or 0
		local labs = #(byName[U.lab] or {}) + #(byName[U.vp] or {})
		if duelState.overflow >= 60 and labs < 5 and not duelState.labOrdered then
			local cons = ownedBy(ids.eco, U.ck)
			if #cons >= 2 then
				local _, dx, dz = towardEnemy(0.1, 0)
				local a = labs * 1.3
				-- the second factory a vehicle plant (strong players field about half vehicles)
				local kind = #(byName[U.vp] or {}) == 0 and U.vp or U.lab
				playerBuild(cons[1], kind, cx + dx * 250 + math.cos(a) * 500, cz + dz * 250 + math.sin(a) * 500, dx, dz)
				duelState.labOrdered, duelState.labCount, duelState.overflow = n, labs, 0
				duelState.labKind = kind
				out("player: metal piling up, another factory ordered (" .. kind .. ")")
			end
		end
	end
	-- like a player who techs up once the economy carries it (BARbarian goes tier 2 around minute 25):
	-- the T2 lab at minute 18 with 25+ metal/s, to the Economy (T2 constructors, then it goes to the Army)
	if duelState.stage >= 3 and not duelState.t2Assigned and n >= 30 * 60 * 18 and n % 30 == 0 then
		local t2 = (byName[U.alab] or {})[1]
		if t2 and not Spring.GetUnitIsBeingBuilt(t2) then
			SC.assign(ids.eco, { t2 })
			duelState.t2Assigned = true
			out("player: tier 2 lab to Economy")
		elseif not duelState.t2Ordered or (n - duelState.t2Ordered > 30 * 150 and not t2) then
			local _, _, _, mInc = Spring.GetTeamResources(myTeam, "metal")
			local cons = ownedBy(ids.eco, U.ck)
			local building = false
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				building = building or (UnitDefs[Spring.GetUnitDefID(u)].name == U.alab)
			end
			if (mInc or 0) >= 25 and cons[1] and not building then
				local _, dx, dz = towardEnemy(0.1, 0)
				duelState.t2Tries = (duelState.t2Tries or 0) + 1
				local a = duelState.t2Tries * 2.1
				playerBuild(cons[1], U.alab, cx - dx * 700 + math.cos(a) * 250, cz - dz * 700 + math.sin(a) * 250, dx, dz)
				duelState.t2Ordered = n
				out("player: tier 2 lab ordered")
			end
		end
	end
	if duelState.labOrdered then
		local labs = byName[duelState.labKind or U.lab] or {}
		local newest = labs[#labs]
		local total = #(byName[U.lab] or {}) + #(byName[U.vp] or {})
		if total > duelState.labCount and newest and not Spring.GetUnitIsBeingBuilt(newest) then
			SC.assign(ids.army, { newest })
			duelState.labOrdered = nil
			out("player: new lab to Army")
		elseif n - duelState.labOrdered > 30 * 120 then
			duelState.labOrdered = nil
		end
	end
	duelWatch(n)
end

function widget:GameOver(winners)
	if scenario == "spectate" or scenario == "replay" then
		out("RESULT GAMEOVER winners=" .. table.concat(winners or {}, ","))
		out("DONE")
		Spring.SendCommands("quitforce")
		return
	end
	local won = false
	for _, a in ipairs(winners or {}) do
		if a == Spring.GetMyAllyTeamID() then
			won = true
		end
	end
	duelResult(won and "WIN" or "LOSS")
end

--------------------------------------------------------------------------------
-- battle: one engagement in isolation (testenv/battle-lab: micro, targeting, movement). Each side gets an
-- army mid-map (cheats); ours goes to an Army sub-commander at full autonomy, BARbarian runs its own;
-- full vision to count both. Ends when one side is down to 10% of its metal or at the time limit, with
-- a BATTLE line (and the usual RESULT for the runners).
-- Spec: sctest_battle.txt (LuaUI/Config/ first), lines "us <unit> <n>", "them <unit> <n>",
-- "distance <elmos>", "seconds <n>", "attack 1" (their units fight-move at ours: we defend; without it
-- they stand, and we decide whether to attack). A unit line may end in "<dx> <dz>": an offset from that
-- side's centre (to lay out a base: turrets, anti-air, an economy). "role air": ours go to an Air Force
-- sub-commander (default: an Army).
--------------------------------------------------------------------------------

local battle = { us = {}, them = {}, distance = 700, seconds = 120, attack = 0, role = "army", name = "default" }

local function battleSpec()
	local text = loadInput("sctest_battle.txt") or "us legkark 6\nus legbar 4\nus leggob 6\nthem armham 8\nthem armrock 4\nthem armpw 6\n"
	for line in text:gmatch("[^\n]+") do
		local side, name, n, rest = line:match("^%s*(%a+)%s+([%w_]+)%s+(%d+)(.*)$")
		if side == "us" or side == "them" then
			local dx, dz = (rest or ""):match("^%s+(-?%d+)%s+(-?%d+)")
			battle[side][#battle[side] + 1] = { name = name, n = tonumber(n), dx = tonumber(dx) or 0, dz = tonumber(dz) or 0 }
		end
		battle.role = line:match("^%s*role%s+(%a+)") or battle.role
		battle.name = line:match("^#%s*(%S+)") or battle.name
		local k, v = line:match("^%s*(%a+)%s+(%d+)%s*$")
		if k == "distance" or k == "seconds" or k == "attack" then
			battle[k] = tonumber(v)
		end
	end
end

local function battleValue(ids)
	local v = 0
	for u in pairs(ids) do
		if Spring.ValidUnitID(u) and not Spring.GetUnitIsDead(u) then
			local d = kinds[Spring.GetUnitDefID(u)]
			v = v + (d and d.cost or 0)
		end
	end
	return v
end

local function battleFrame(n)
	local mx, mz = Game.mapSizeX / 2, Game.mapSizeZ / 2
	local half = battle.distance / 2
	if n == 12 then
		battleSpec()
		Spring.SendCommands("cheat 1", "globallos")
		if battle.attack > 0 then
			Spring.SendCommands("godmode 3") -- order their units too (attack)
		end
		out(string.format("scenario battle: %d vs %d unit types, %d elmos apart, %d s", #battle.us, #battle.them, battle.distance, battle.seconds))
	elseif not battle.given and n > 12 and Spring.IsCheatingEnabled() then
		-- give once cheats are on: "cheat 1" goes through the server and took 14 frames in a busy sandbox,
		-- and gives before it were refused (the battle ran without armies)
		battle.given = n
		for _, u in ipairs(battle.us) do
			if UnitDefNames[u.name] then
				give(u.n, u.name, myTeam, mx - half + u.dx, mz + u.dz)
			else
				out("HARNESS ERROR battle: no unit " .. u.name)
			end
		end
		for _, u in ipairs(battle.them) do
			if UnitDefNames[u.name] then
				give(u.n, u.name, 1, mx + half + u.dx, mz + u.dz)
			else
				out("HARNESS ERROR battle: no unit " .. u.name)
			end
		end
	elseif not battle.given and n > 12 + 30 * 20 then
		out(string.format("BATTLE spec=%s result=VOID seconds=0 us_start=0 us_left=0 them_start=0 them_left=0", battle.name))
		out("HARNESS ERROR battle: cheats never came on, no armies given")
		out("RESULT TIMEOUT t=0s")
		out("DONE")
		Spring.SendCommands("quitforce")
	elseif battle.given and not battle.start and n >= battle.given + 25 and (n % 15 == 0 or n >= battle.given + 300) then
		-- the give goes through the server too: start once both armies are there (a busy sandbox took over
		-- 25 frames), giving up after 10 s (the battle is then dropped as without armies)
		battle.ours, battle.theirs = {}, {}
		local list = {}
		-- what was given: both sides' units around the battle, not the commanders at the start positions
		local function given(team, x)
			local found = {}
			for _, u in ipairs(Spring.GetUnitsInCylinder(x, mz, 1500)) do
				local ud = UnitDefs[Spring.GetUnitDefID(u) or -1]
				if Spring.GetUnitTeam(u) == team and ud and not (ud.customParams and ud.customParams.iscommander) then
					found[#found + 1] = u
				end
			end
			return found
		end
		for _, u in ipairs(given(myTeam, mx - half)) do
			battle.ours[u] = true
			list[#list + 1] = u
		end
		local theirs = 0
		for _, u in ipairs(given(1, mx + half)) do
			battle.theirs[u] = true
			theirs = theirs + 1
		end
		local wantUs, wantThem = 0, 0
		for _, u in ipairs(battle.us) do
			wantUs = wantUs + (UnitDefNames[u.name] and u.n or 0)
		end
		for _, u in ipairs(battle.them) do
			wantThem = wantThem + (UnitDefNames[u.name] and u.n or 0)
		end
		if (#list < wantUs or theirs < wantThem) and n < battle.given + 300 then
			return -- not all there yet
		end
		battle.start = n
		battle.usStart, battle.themStart = battleValue(battle.ours), battleValue(battle.theirs)
		if battle.attack > 0 then
			local ordered = 0
			for u in pairs(battle.theirs) do
				if Spring.GiveOrderToUnit(u, CMD.FIGHT, { mx - half, Spring.GetGroundHeight(mx - half, mz), mz }, 0) then
					ordered = ordered + 1
				end
			end
			out(string.format("battle: they attack (%d units ordered)", ordered))
		end
		local SC = WG.SubCommanders
		ids.army = SC.create(battle.role)
		SC.assign(ids.army, list)
		SC.setAutonomy(ids.army, "full")
		if SC.setRaids then
			SC.setRaids(ids.army, false)
		end
		-- the army's area: both sides (we decide whether to attack), or with `attack` our half only (we
		-- defend: they come to us; a zone over their side made them intruders from the start and our army
		-- went at them before they pushed)
		if battle.attack > 0 then
			SC.addZone(ids.army, { kind = "circle", x = mx - half, z = mz, r = half + 200 })
		else
			SC.addZone(ids.army, { kind = "circle", x = mx, z = mz, r = battle.distance })
		end
		out(string.format("battle: us %.0f metal (%d units), them %.0f metal", battle.usStart, #list, battle.themStart))
	elseif battle.start and n % 15 == 0 then
		local us, them = battleValue(battle.ours), battleValue(battle.theirs)
		local t = (n - battle.start) / 30
		local over = us <= 0.1 * battle.usStart or them <= 0.1 * battle.themStart or t >= battle.seconds
		if n % 300 == 0 or over then
			local s = WG.SubCommanders and WG.SubCommanders.get(ids.army)
			-- how many of ours hold a set target (fire control) right now
			-- and how far ours are from their side's centre (on average), with their current orders
			local targeted, alive, far, cmds = 0, 0, 0, {}
			for u in pairs(battle.ours) do
				if Spring.ValidUnitID(u) and not Spring.GetUnitIsDead(u) then
					alive = alive + 1
					if (Spring.GetUnitRulesParam(u, "unitTargetID") or 0) > 0 then
						targeted = targeted + 1
					end
					local x, _, z = Spring.GetUnitPosition(u)
					far = far + math.sqrt((x - (mx + half)) ^ 2 + (z - mz) ^ 2)
					local c = Spring.GetUnitCommands(u, 1)
					local id = c and c[1] and c[1].id or 0
					cmds[id] = (cmds[id] or 0) + 1
				end
			end
			local cl = {}
			for id, k in pairs(cmds) do
				cl[#cl + 1] = (CMD[id] or tostring(id)) .. "x" .. k
			end
			table.sort(cl)
			out(string.format("battle t=%ds us=%.0f them=%.0f targeted=%d/%d dist=%.0f cmds=%s | %s", t, us, them, targeted, alive,
				alive > 0 and far / alive or 0, table.concat(cl, ","), s and (s.status or "") or ""))
		end
		if over and not duelState.done then
			local result = (them <= 0.1 * battle.themStart and us > 0.1 * battle.usStart and "WIN")
				or (us <= 0.1 * battle.usStart and them > 0.1 * battle.themStart and "LOSS") or "DRAW"
			out(string.format("BATTLE spec=%s result=%s seconds=%d us_start=%.0f us_left=%.0f them_start=%.0f them_left=%.0f", battle.name, result, t,
				battle.usStart, us, battle.themStart, them))
			duelState.done = true
			out("RESULT " .. (result == "DRAW" and "TIMEOUT" or result) .. string.format(" t=%ds", t))
			out("  us:    " .. teamStats(myTeam))
			out("DONE")
			Spring.SendCommands("quitforce")
		end
	end
end

local function gameFrame(n)
	if scenario == "battle" then
		battleFrame(n)
		return
	end
	if scenario == "replay" then
		-- a recorded game (testenv/replays.sh): full view, fast, quit at the end
		if n == 12 then
			Spring.SendCommands("specfullview 1", "setmaxspeed 40", "setspeed " .. (speedOverride or 20))
			out("scenario replay")
		elseif n % (30 * 60) == 0 then
			out(string.format("t=%dmin", n / 1800))
		end
		return
	end
	if scenario == "spectate" then
		-- BARbarian vs BARbarian for the data logger: full view, fast, 25 minutes at most
		if n == 12 then
			Spring.SendCommands("specfullview 1")
			if not speedOverride then
				Spring.SendCommands("setmaxspeed 20", "setspeed 15")
			end
			out("scenario spectate")
		elseif n % (30 * 60) == 0 then
			out(string.format("t=%dmin", n / 1800))
		elseif n >= 30 * 60 * 25 then
			out("RESULT TIMEOUT")
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	SC = WG.SubCommanders or SC
	if not SC then
		if n == 30 then
			out("ERROR: WG.SubCommanders missing")
		end
		return
	end
	if scenario == "ui" then
		if n == 20 then
			local com = Spring.GetTeamUnits(myTeam)[1]
			cx, _, cz = Spring.GetUnitPosition(com)
			cz = cz or 0
			Spring.SetCameraTarget(cx, 0, cz, 0)
			Spring.SendCommands("setmaxspeed 20", "setspeed 8")
			Spring.SendCommands("cheat 1")
		elseif n == 45 then
			give(1, U.lab, myTeam, cx - 400, cz - 250)
			give(2, U.ck, myTeam, cx + 150, cz + 100)
		elseif n == 150 then
			out("have", #(byName[U.lab] or {}), "lab", #(byName[U.ck] or {}), "ck")
			local com = Spring.GetTeamUnits(myTeam)
			Spring.SendCommands("luaui sc new army")
			Spring.SelectUnitArray(byName[U.lab] or {})
		elseif n == 152 then
			Spring.SendCommands("luaui sc assign")
			Spring.SelectUnitArray(byName[U.ck] or {})
			Spring.SendCommands("luaui sc new airdefense")
		elseif n == 154 then
			Spring.SendCommands("luaui sc assign", "luaui sc posture conserve", "luaui sc role defense")
		elseif n == 156 then
			-- focus army factory on the unit type of a selected unit def: select nothing => automatic, so pick legcen via API
			WG.SubCommanders.setFocus(1, { "legcen" })
			Spring.SendCommands("luaui sc list", "luaui sc select 1")
		elseif n == 30 * 40 then
			for _, s in ipairs(SC.list()) do
				out(string.format("[%d] %s role=%s posture=%s units=%d zones=%d focus=%s", s.id, s.name, s.role, s.posture, #s.units, #s.zones, s.focus and table.concat(s.focus, ",") or "auto"))
				for i = math.min(#s.recent, 6), 1, -1 do
					out("     log: " .. s.recent[i].text)
				end
			end
			out("selected", #Spring.GetSelectedUnits())
			Spring.SendCommands("screenshot png")
		elseif n == 30 * 41 then
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "dbg" then
		if n == 10 then
			ids.com = Spring.GetTeamUnits(myTeam)[1]
			out("myPlayer", Spring.GetMyPlayerID())
		end
		if n % 150 == 0 and ids.com then
			out("com", queueOf(ids.com))
		end
		if n == 30 * 60 then
			playerOrder(ids.com, CMD.MOVE, { cx + 500, Spring.GetGroundHeight(cx + 500, cz + 300), cz + 300 })
			out("player move order")
		end
		if n == 30 * 62 or n == 30 * 75 then
			report()
		end
		if n == 30 * 90 then
			report()
			out("DONE")
			Spring.SendCommands("quitforce")
		end
	end
	if n == 10 then
		local com = Spring.GetTeamUnits(myTeam)[1]
		local x, _, z = Spring.GetUnitPosition(com)
		cx, cz = x, z
		Spring.SetCameraTarget(x, 0, z, 0)
		out("scenario", scenario, "commander", com, x, z)
		Spring.SendCommands("setmaxspeed 20", "setspeed 8")
		if scenario == "ui" or scenario == "factory" or scenario == "lanes" then
			-- commander stays with the player
		elseif scenario == "eco" or scenario == "dbg" then
			ids.eco = SC.create("economy")
			SC.assign(ids.eco, { com })
		elseif scenario == "multi" or scenario == "vsai" or scenario == "ai" then
			Spring.SendCommands("cheat 1")
			ids.eco = SC.create("economy")
			SC.assign(ids.eco, { com })
		end
	end
	if scenario == "lanes" then
		if n == 20 then
			local com = Spring.GetTeamUnits(myTeam)[1]
			cx, _, cz = Spring.GetUnitPosition(com)
			Spring.SetCameraTarget(cx, 0, cz, 0)
			Spring.SendCommands("setmaxspeed 20", "setspeed 8", "cheat 1")
		elseif n == 45 then
			give(1, U.lab, myTeam, cx - 300, cz + 250)
			give(1, U.lab, myTeam, cx + 350, cz - 200)
			give(3, U.ck, myTeam, cx, cz + 120)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.setPosture(ids.eco, "spend")
			SC.addZone(ids.eco, { kind = "circle", x = cx, z = cz, r = 900 })
			SC.assign(ids.eco, byName[U.ck] or {})
		elseif n == 30 * 180 then
			-- every structure must stay out of each lab's exit lane (300 in front) and 64 ring
			local bad, total = 0, 0
			for _, lab in ipairs(byName[U.lab] or {}) do
				local lx, _, lz = Spring.GetUnitPosition(lab)
				local f = Spring.GetUnitBuildFacing(lab)
				local ld = UnitDefs[Spring.GetUnitDefID(lab)]
				local hx, hz = ld.xsize * 4, ld.zsize * 4
				if f == 1 or f == 3 then
					hx, hz = hz, hx
				end
				local rects = { { lx - hx - 64, lz - hz - 64, lx + hx + 64, lz + hz + 64 } }
				if f == 0 then
					rects[2] = { lx - hx, lz + hz, lx + hx, lz + hz + 300 }
				elseif f == 1 then
					rects[2] = { lx + hx, lz - hz, lx + hx + 300, lz + hz }
				elseif f == 2 then
					rects[2] = { lx - hx, lz - hz - 300, lx + hx, lz - hz }
				else
					rects[2] = { lx - hx - 300, lz - hz, lx - hx, lz + hz }
				end
				out(string.format("lab %d at %d,%d facing %d", lab, lx, lz, f))
				for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
					local ud = UnitDefs[Spring.GetUnitDefID(u)]
					if (ud.speed or 0) == 0 and not ud.isFactory and SC.ownerOf(u) then
						total = total + 1
						local x, _, z = Spring.GetUnitPosition(u)
						local uhx, uhz = ud.xsize * 4, ud.zsize * 4
						for _, r in ipairs(rects) do
							if x + uhx > r[1] and x - uhx < r[3] and z + uhz > r[2] and z - uhz < r[4] then
								bad = bad + 1
								out("  BLOCKING: " .. ud.name .. string.format(" at %d,%d", x, z))
							end
						end
					end
				end
			end
			out(string.format("structures checked=%d blocking=%d", total, bad))
			report()
			Spring.SendCommands("screenshot png")
		elseif n == 30 * 181 then
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "factory" then
		if n == 20 then
			local com = Spring.GetTeamUnits(myTeam)[1]
			cx, _, cz = Spring.GetUnitPosition(com)
			Spring.SetCameraTarget(cx, 0, cz, 0)
			Spring.SendCommands("setmaxspeed 20", "setspeed 8", "cheat 1")
		elseif n == 45 then
			give(1, U.ck, myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.army = SC.create("army")
			SC.setPosture(ids.army, "spend")
			SC.assign(ids.army, byName[U.ck] or {})
		elseif n == 30 * 40 then
			local labs = byName[U.lab] or {}
			out("after 40s: factories built by the army sub-commander = " .. #labs)
			-- the player takes the constructor and builds a lab with it
			local ck = (byName[U.ck] or {})[1]
			local x, z = cx - 450, cz - 300
			playerOrder(ck, -UnitDefNames[U.lab].id, { x, Spring.GetGroundHeight(x, z), z, 0 })
			out("player ordered the constructor to build a Bot Lab")
		elseif n == 30 * 110 then
			local labs = byName[U.lab] or {}
			local ck = (byName[U.ck] or {})[1]
			out(string.format("labs=%d lab owner=%s constructor owner=%s", #labs, tostring(labs[1] and SC.ownerOf(labs[1])), tostring(ck and SC.ownerOf(ck))))
			report()
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "ai" then
		if n == 12 then
			Spring.SendCommands("setspeed 3")
		elseif n == 40 then
			give(2, U.ck, myTeam, cx + 200, cz)
		elseif n == 90 then
			SC.setAI(ids.eco, true)
			SC.setDirective(ids.eco, "keep energy healthy and grab every metal spot east of the base")
			ids.def = SC.create("defense")
			SC.assign(ids.def, byName[U.ck] or {})
			SC.setAI(ids.def, true)
			SC.setDirective(ids.def, "the enemy starts south of us: protect the base from the south")
		elseif n == 30 * 120 then
			give(8, "armpw", 1, cx, cz + 900)
			out("spawned enemy raid south")
		end
	end
	if scenario == "vsai" then
		if n == 40 then
			give(2, U.ck, myTeam, cx + 200, cz)
			give(1, U.lab, myTeam, cx - 500, cz - 300)
			give(1, U.ck, myTeam, cx, cz + 200)
		elseif n == 90 then
			local ck, lab = byName[U.ck] or {}, byName[U.lab] or {}
			ids.def = SC.create("defense")
			SC.assign(ids.def, { ck[1], ck[2] })
			ids.army = SC.create("army")
			SC.assign(ids.army, { lab[1] })
			ids.aa = SC.create("airdefense")
			SC.assign(ids.aa, { ck[3] })
		end
	end
	if isDuel then
		duel(n)
	end
	if scenario == "intel" then
		-- Intelligence sub-commander with two constructors and a vehicle plant (scouts), no enemy
		if n == 20 then
			Spring.SendCommands("setmaxspeed 20", "setspeed 4", "cheat 1")
		elseif n == 40 then
			give(2, U.ck, myTeam, cx + 200, cz)
			give(1, U.vp, myTeam, cx - 450, cz + 300)
			give(4, "legwin", myTeam, cx + 400, cz + 400)
		elseif n == 150 then
			ids.intel = SC.create("intelligence")
			SC.addZone(ids.intel, { kind = "circle", x = cx, z = cz + 1200, r = 1300 })
			local units = {}
			for _, name in ipairs({ U.ck, U.vp }) do
				for _, u in ipairs(byName[name] or {}) do
					units[#units + 1] = u
				end
			end
			SC.assign(ids.intel, units)
			SC.setPosture(ids.intel, "spend")
		elseif n == 30 * 180 then
			local s = SC.get(ids.intel)
			local built = {}
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				if SC.ownerOf(u) == ids.intel then
					local n2 = UnitDefs[Spring.GetUnitDefID(u)].name
					built[n2] = (built[n2] or 0) + 1
				end
			end
			local parts = {}
			for k, v in pairs(built) do
				parts[#parts + 1] = k .. "=" .. v
			end
			table.sort(parts)
			out("intel owns: " .. table.concat(parts, " "))
			local tasks = {}
			for _, u in ipairs(s.units) do
				if u.task then
					tasks[#tasks + 1] = u.name .. ":" .. u.task
				end
			end
			out("intel tasks: " .. table.concat(tasks, ", "))
			for i = math.min(#s.recent, 10), 1, -1 do
				out("  log: " .. s.recent[i].text)
			end
			Spring.SendCommands("screenshot png")
		elseif n == 30 * 181 then
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "labtest" then
		-- the player orders one of Economy's constructors to build a lab: it must be left alone until done
		if n == 20 then
			Spring.SendCommands("setmaxspeed 20", "setspeed 3", "cheat 1")
		elseif n == 40 then
			give(3, U.ck, myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.assign(ids.eco, byName[U.ck] or {})
			SC.setPosture(ids.eco, "spend")
		elseif n == 30 * 20 then
			ids.ck = (byName[U.ck] or {})[2]
			playerBuild(ids.ck, U.lab, cx + 300, cz + 400, 0, 1)
		elseif n > 30 * 20 and n % 30 == 0 and n <= 30 * 100 then
			local st
			for _, u in ipairs(SC.get(ids.eco).units) do
				if u.id == ids.ck then
					st = (u.task or "-") .. (u.manual and " (manual)" or "")
				end
			end
			out(string.format("ck %s selected=%s owner=%s task=%s labs=%d", queueOf(ids.ck), tostring(Spring.IsUnitSelected(ids.ck)), tostring(SC.ownerOf(ids.ck)), tostring(st), #(byName[U.lab] or {})))
			if n % 300 == 0 then
				local q = Spring.GetUnitCommands(ids.ck, 1)
				local c = q and q[1]
				if c and c.id < 0 then
					local near = {}
					for _, u in ipairs(Spring.GetUnitsInCylinder(c.params[1], c.params[3], 200)) do
						local x, _, z = Spring.GetUnitPosition(u)
						near[#near + 1] = string.format("%s@%d,%d%s", UnitDefs[Spring.GetUnitDefID(u)].name, x, z, Spring.GetUnitIsBeingBuilt(u) and "(frame)" or "")
					end
					local defID = -c.id
					out("  at site: " .. table.concat(near, " ") .. " | test=" .. tostring(Spring.TestBuildOrder(defID, c.params[1], c.params[2], c.params[3], c.params[4] or 0)))
				end
			end
		elseif n == 30 * 101 then
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "coop" then
		-- the player builds in the Economy zone with the commander while the sub-commander works there too
		if n == 20 then
			Spring.SendCommands("setmaxspeed 20", "setspeed 4", "cheat 1")
		elseif n == 40 then
			give(3, U.ck, myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.addZone(ids.eco, { kind = "circle", x = cx, z = cz, r = 1000 })
			SC.assign(ids.eco, byName[U.ck] or {})
			SC.setPosture(ids.eco, "spend")
			-- the player's own plan: a block of wind turbines and two light turrets, queued with shift
			ids.com = Spring.GetTeamUnits(myTeam)[1]
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				if UnitDefs[Spring.GetUnitDefID(u)].name == "legcom" then
					ids.com = u
				end
			end
			duelState.playerPlan = {}
			local function plan(name, x, z)
				local defID = UnitDefNames[name].id
				local bx, by, bz = Spring.Pos2BuildPos(defID, x, Spring.GetGroundHeight(x, z), z, 0)
				if Spring.TestBuildOrder(defID, bx, by, bz, 0) > 0 then
					duelState.playerPlan[#duelState.playerPlan + 1] = { name = name, x = bx, z = bz }
				end
			end
			for i = 0, 2 do
				for j = 0, 2 do
					plan("legwin", cx - 420 + i * 40, cz + 260 + j * 40)
				end
			end
			plan("leglht", cx + 380, cz - 380)
			plan("leglht", cx - 380, cz - 380)
			Spring.SelectUnitArray({ ids.com })
			for k, p in ipairs(duelState.playerPlan) do
				Spring.GiveOrderToUnit(ids.com, -UnitDefNames[p.name].id, { p.x, Spring.GetGroundHeight(p.x, p.z), p.z, 0 }, k > 1 and { "shift" } or {})
			end
			deselectAt = n + 30
			out("player queued " .. #duelState.playerPlan .. " buildings with the commander")
		elseif n == 30 * 20 then
			local s = SC.get(ids.eco)
			out("playerActivity: " .. (s.playerActivity and Json.encode(s.playerActivity) or "none"))
		elseif n > 120 and n < 30 * 120 and n % 30 == 0 then
			-- how often the sub-commander's constructors help finish something (sampled every second)
			for _, u in ipairs(SC.get(ids.eco).units) do
				if u.task and u.task:find("help build") then
					duelState.helpTicks = (duelState.helpTicks or 0) + 1
				end
			end
		elseif n == 30 * 120 then
			-- 1. nothing of the sub-commander's sits on a spot the player queued
			local conflicts, built = 0, 0
			for _, p in ipairs(duelState.playerPlan) do
				local pd = UnitDefNames[p.name]
				local units = Spring.GetUnitsInRectangle(p.x - pd.xsize * 4, p.z - pd.zsize * 4, p.x + pd.xsize * 4, p.z + pd.zsize * 4)
				for _, u in ipairs(units) do
					local ud = UnitDefs[Spring.GetUnitDefID(u)]
					if (ud.speed or 0) == 0 then
						local ux, _, uz = Spring.GetUnitPosition(u)
						if ud.name == p.name and math.abs(ux - p.x) < 8 and math.abs(uz - p.z) < 8 then
							built = built + 1
						elseif SC.ownerOf(u) then
							conflicts = conflicts + 1
							out(string.format("  CONFLICT: %s at %d,%d on the player's %s spot", ud.name, ux, uz, p.name))
						end
					end
				end
			end
			-- 2. structures of the sub-commander on lanes (extractors, factories and big ones are exempt)
			local onLane, checked = 0, 0
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				local ud = UnitDefs[Spring.GetUnitDefID(u)]
				if (ud.speed or 0) == 0 and not ud.isFactory and (ud.extractsMetal or 0) == 0 and SC.ownerOf(u) then
					checked = checked + 1
					local x, _, z = Spring.GetUnitPosition(u)
					local hx, hz = ud.xsize * 4, ud.zsize * 4
					local lx, lz = math.floor(x / 320 + 0.5) * 320, math.floor(z / 320 + 0.5) * 320
					if math.abs(x - lx) < hx + 28 or math.abs(z - lz) < hz + 28 then
						onLane = onLane + 1
						out(string.format("  ON LANE: %s at %d,%d", ud.name, x, z))
					end
				end
			end
			local helped = duelState.helpTicks or 0
			out(string.format("coop: player plan %d, built %d, conflicts %d; sub structures %d, on lanes %d; help-build log lines %d", #duelState.playerPlan, built, conflicts, checked, onLane, helped))
			report()
			Spring.SendCommands("screenshot png")
		elseif n == 30 * 121 then
			out("DONE")
			Spring.SendCommands("quitforce")
		end
		return
	end
	if scenario == "multi" then
		if n == 40 then
			give(2, U.ck, myTeam, cx + 200, cz)
			give(1, U.lab, myTeam, cx - 500, cz - 300)
			give(1, U.ck, myTeam, cx, cz + 200)
		elseif n == 90 then
			local ck = byName[U.ck] or {}
			local lab = byName[U.lab] or {}
			out("given", #ck, U.ck, #lab, U.lab)
			ids.def = SC.create("defense")
			SC.addZone(ids.def, { kind = "rect", x1 = cx - 900, z1 = cz - 1500, x2 = cx + 900, z2 = cz - 600 })
			SC.assign(ids.def, { ck[1], ck[2] })
			ids.army = SC.create("army")
			SC.addZone(ids.army, { kind = "circle", x = cx, z = cz - 900, r = 900 })
			SC.assign(ids.army, { lab[1] })
			SC.setPosture(ids.army, "spend")
			ids.aa = SC.create("airdefense")
			SC.assign(ids.aa, { ck[3] })
		elseif n == 30 * 150 then
			-- enemy raid into the army zone
			give(6, "armpw", 1, cx + 300, cz - 1300)
			give(3, "armfig", 1, cx - 200, cz - 400)
			out("spawned enemy raid")
		elseif n == 30 * 200 then
			-- the "player" moves the commander away: sub-commander must back off
			local com = Spring.GetTeamUnits(myTeam)
			for _, u in ipairs(com) do
				if UnitDefs[Spring.GetUnitDefID(u)].name == "legcom" then
					ids.com = u
					playerOrder(u, CMD.MOVE, { cx + 500, Spring.GetGroundHeight(cx + 500, cz + 300), cz + 300 })
				end
			end
			out("player ordered commander to move")
		elseif n == 30 * 203 or n == 30 * 230 then
			for _, s in ipairs(SC.list()) do
				for _, u in ipairs(s.units) do
					if u.id == ids.com then
						out("commander manual=" .. tostring(u.manual) .. " task=" .. tostring(u.task))
					end
				end
			end
		elseif n == 30 * 240 then
			Spring.SendCommands("luaui disablewidget Sub-Commanders")
		elseif n == 30 * 242 then
			Spring.SendCommands("luaui enablewidget Sub-Commanders")
		elseif n == 30 * 245 then
			local l = WG.SubCommanders and WG.SubCommanders.list() or {}
			local parts = {}
			for _, s in ipairs(l) do
				parts[#parts + 1] = s.name .. ":" .. #s.units .. "u/" .. #s.zones .. "z"
			end
			out("after reload: " .. #l .. " subs " .. table.concat(parts, " "))
		end
	end
	if n % (30 * 30) == 0 then
		report()
	end
	if scenario == "multi" and n % 450 == 0 then
		for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
			if UnitDefs[Spring.GetUnitDefID(u)].name == "legcom" then
				local mm, mu, em, eu = Spring.GetUnitResources(u)
				out("  com " .. queueOf(u) .. string.format(" building=%s muse=%.2f", tostring((Spring.GetUnitIsBuilding(u))), mu or -1))
			end
		end
	end
	if isDuel and n == endFrame then
		duelResult("TIMEOUT")
		return
	end
	if n == endFrame - 30 then
		Spring.SendCommands("screenshot png")
	elseif n == endFrame then
		report()
		out("DONE")
		Spring.SendCommands("quitforce")
	end
end


-- lockstep: the game slows to real time while the strategist thinks (Update keeps running)
local lockPaused, lockChecked = false, 0
function widget:Update()
	if not lockstep or not WG.SubCommanders or Spring.GetGameFrame() < 30 then
		return
	end
	local now = os.clock()
	if now - lockChecked < 0.2 then
		return
	end
	lockChecked = now
	local thinking = false
	for _, s in ipairs(WG.SubCommanders.list()) do
		if s.ai and type(s.aiStatus) == "string" and s.aiStatus:find("^thinking") then
			thinking = true
		end
	end
	-- while the strategist thinks the game runs at real time, as it would in a real game; at full test
	-- speed otherwise (pausing instead stopped the game nearly all the time once reviews got frequent)
	if thinking and not lockPaused then
		Spring.SendCommands("setspeed 1")
		lockPaused = true
	elseif not thinking and lockPaused then
		Spring.SendCommands("setspeed " .. (speedOverride or 10))
		lockPaused = false
	end
end

function widget:GameFrame(n)
	if deselectAt and n >= deselectAt then
		deselectAt = nil
		Spring.SelectUnitArray({})
	end
	-- scenario time starts once our commander exists (it can spawn a moment after frame 0)
	if not startOffset then
		if #Spring.GetTeamUnits(myTeam) == 0 then
			return
		end
		startOffset = math.max(0, n - 9)
	end
	if speedOverride and n - startOffset == 30 then
		Spring.SendCommands("setmaxspeed " .. (speedOverride + 5), "setspeed " .. speedOverride)
	end
	local ok, err = pcall(gameFrame, n - startOffset)
	if not ok then
		out("HARNESS ERROR: " .. tostring(err))
	end
end
