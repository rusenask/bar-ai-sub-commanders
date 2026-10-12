-- Test harness for gui_subcommanders.lua (not shipped). Scenario comes from sctest_scenario.txt
function widget:GetInfo()
	return { name = "ZZ SubCommander Test", layer = 100, enabled = true }
end

local scenario = (VFS.LoadFile("sctest_scenario.txt", VFS.RAW) or "eco"):gsub("%s+", "")
local myTeam = Spring.GetMyTeamID()
local SC
local ids = {}
local byName = {}
local isDuel = scenario == "duel" or scenario == "duelrules"
local endFrame = (isDuel and 30 * 60 * 25) or (scenario == "vsai" and 30 * 60 * 9) or (scenario == "ai" and 30 * 60 * 4) or 30 * 60 * 6
local outFile = io and io.open and io.open("sctest_out.txt", "w")
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

local function duel(n)
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
		ids.eco = SC.create("economy")
		SC.assign(ids.eco, { com })
		SC.setAI(ids.eco, ai)
		SC.setDirective(ids.eco, "grow the economy: take every safe metal spot, keep energy ahead of spending")
		-- the player uses the commander for the first lab, then leaves it to Economy
		local _, dx, dz = towardEnemy(0.1, 0)
		playerBuild(com, "leglab", cx + dx * 220, cz + dz * 220, dx, dz)
	end
	if duelState.stage == 0 then
		local lab = (byName.leglab or {})[1]
		if lab and not Spring.GetUnitIsBeingBuilt(lab) then
			duelState.stage = 1
			-- the first lab makes constructors for the economy
			SC.assign(ids.eco, { lab })
			out("player: first lab to Economy")
		end
	elseif duelState.stage == 1 then
		local cons = ownedBy(ids.eco, "legck")
		if #cons >= 3 then
			duelState.stage = 2
			local zone, dx, dz = towardEnemy(0.22, 1000)
			ids.def = SC.create("defense")
			SC.assign(ids.def, { cons[1] })
			SC.clearZones(ids.def)
			SC.addZone(ids.def, zone)
			SC.setAI(ids.def, ai)
			SC.setDirective(ids.def, "hold the side of the base facing the enemy")
			-- second lab toward the front for the army
			playerBuild(cons[2], "leglab", cx + dx * 380 - dz * 350, cz + dz * 380 + dx * 350, dx, dz)
			duelState.lab2Builder = cons[2]
			out("player: Defense created, second lab ordered")
		end
	elseif duelState.stage == 2 then
		local labs = byName.leglab or {}
		local lab2 = labs[2]
		-- like a player who notices the lab never started: order it again, a bit elsewhere
		duelState.lab2Since = duelState.lab2Since or n
		if not lab2 and n - duelState.lab2Since > 30 * 90 then
			local frames = 0
			for _, u in ipairs(Spring.GetTeamUnits(myTeam)) do
				if UnitDefs[Spring.GetUnitDefID(u)].name == "leglab" and Spring.GetUnitIsBeingBuilt(u) then
					frames = frames + 1
				end
			end
			if frames == 0 then
				local cons = ownedBy(ids.eco, "legck")
				local _, dx, dz = towardEnemy(0.1, 0)
				if cons[1] then
					duelState.lab2Tries = (duelState.lab2Tries or 0) + 1
					local a = duelState.lab2Tries * 2.1
					playerBuild(cons[1], "leglab", cx + dx * 300 + math.cos(a) * 450, cz + dz * 300 + math.sin(a) * 450, dx, dz)
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
		local cons = ownedBy(ids.eco, "legck")
		if #cons >= 3 then
			duelState.stage = 4
			SC.assign(ids.def, { cons[1] })
			out("player: second constructor to Defense")
		end
	elseif duelState.stage == 4 and n >= 30 * 60 * 6 then
		local cons = ownedBy(ids.eco, "legck")
		if #cons >= 3 then
			duelState.stage = 5
			ids.aa = SC.create("airdefense")
			SC.assign(ids.aa, { cons[1] })
			SC.setAI(ids.aa, ai)
			SC.setDirective(ids.aa, "keep the base and the economy safe from air")
			out("player: Air Defense created")
		end
	elseif duelState.stage == 5 and n >= 30 * 60 * 8 then
		local cons = ownedBy(ids.eco, "legck")
		if #cons >= 3 then
			duelState.stage = 6
			ids.intel = SC.create("intelligence")
			SC.assign(ids.intel, { cons[1] })
			SC.clearZones(ids.intel)
			SC.addZone(ids.intel, (towardEnemy(0.3, 1500)))
			SC.setAI(ids.intel, ai)
			SC.setDirective(ids.intel, "watch the approaches to our base and take out enemy radar")
			out("player: Intelligence created")
		end
	end
	-- like a real player answering "need a factory": another lab for the Army when metal keeps piling up
	if duelState.stage >= 3 and n % 30 == 0 then
		local m, mS = Spring.GetTeamResources(myTeam, "metal")
		duelState.overflow = (m > mS * 0.8) and (duelState.overflow or 0) + 1 or 0
		local labs = #(byName.leglab or {})
		if duelState.overflow >= 60 and labs < 5 and not duelState.labOrdered then
			local cons = ownedBy(ids.eco, "legck")
			if #cons >= 2 then
				local _, dx, dz = towardEnemy(0.1, 0)
				local a = labs * 1.3
				playerBuild(cons[1], "leglab", cx + dx * 250 + math.cos(a) * 500, cz + dz * 250 + math.sin(a) * 500, dx, dz)
				duelState.labOrdered, duelState.labCount, duelState.overflow = n, labs, 0
				out("player: metal piling up, another lab ordered")
			end
		end
	end
	if duelState.labOrdered then
		local labs = byName.leglab or {}
		local newest = labs[#labs]
		if #labs > duelState.labCount and newest and not Spring.GetUnitIsBeingBuilt(newest) then
			SC.assign(ids.army, { newest })
			duelState.labOrdered = nil
			out("player: new lab to Army")
		elseif n - duelState.labOrdered > 30 * 120 then
			duelState.labOrdered = nil
		end
	end
	if n % (30 * 60) == 0 then
		out(string.format("value: army us=%.0f  units us=%d", armyValue(myTeam), #Spring.GetTeamUnits(myTeam)))
	end
	if #Spring.GetTeamUnits(myTeam) == 0 then
		duelResult("LOSS (no units left)")
	end
end

function widget:GameOver(winners)
	local won = false
	for _, a in ipairs(winners or {}) do
		if a == Spring.GetMyAllyTeamID() then
			won = true
		end
	end
	duelResult(won and "WIN" or "LOSS")
end

local function gameFrame(n)
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
			give(1, "leglab", myTeam, cx - 400, cz - 250)
			give(2, "legck", myTeam, cx + 150, cz + 100)
		elseif n == 150 then
			out("have", #(byName.leglab or {}), "lab", #(byName.legck or {}), "ck")
			local com = Spring.GetTeamUnits(myTeam)
			Spring.SendCommands("luaui sc new army")
			Spring.SelectUnitArray(byName.leglab or {})
		elseif n == 152 then
			Spring.SendCommands("luaui sc assign")
			Spring.SelectUnitArray(byName.legck or {})
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
			give(1, "leglab", myTeam, cx - 300, cz + 250)
			give(1, "leglab", myTeam, cx + 350, cz - 200)
			give(3, "legck", myTeam, cx, cz + 120)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.setPosture(ids.eco, "spend")
			SC.addZone(ids.eco, { kind = "circle", x = cx, z = cz, r = 900 })
			SC.assign(ids.eco, byName.legck or {})
		elseif n == 30 * 180 then
			-- every structure must stay out of each lab's exit lane (300 in front) and 64 ring
			local bad, total = 0, 0
			for _, lab in ipairs(byName.leglab or {}) do
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
			give(1, "legck", myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.army = SC.create("army")
			SC.setPosture(ids.army, "spend")
			SC.assign(ids.army, byName.legck or {})
		elseif n == 30 * 40 then
			local labs = byName.leglab or {}
			out("after 40s: factories built by the army sub-commander = " .. #labs)
			-- the player takes the constructor and builds a lab with it
			local ck = (byName.legck or {})[1]
			local x, z = cx - 450, cz - 300
			playerOrder(ck, -UnitDefNames.leglab.id, { x, Spring.GetGroundHeight(x, z), z, 0 })
			out("player ordered the constructor to build a Bot Lab")
		elseif n == 30 * 110 then
			local labs = byName.leglab or {}
			local ck = (byName.legck or {})[1]
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
			give(2, "legck", myTeam, cx + 200, cz)
		elseif n == 90 then
			SC.setAI(ids.eco, true)
			SC.setDirective(ids.eco, "keep energy healthy and grab every metal spot east of the base")
			ids.def = SC.create("defense")
			SC.assign(ids.def, byName.legck or {})
			SC.setAI(ids.def, true)
			SC.setDirective(ids.def, "the enemy starts south of us: protect the base from the south")
		elseif n == 30 * 120 then
			give(8, "armpw", 1, cx, cz + 900)
			out("spawned enemy raid south")
		end
	end
	if scenario == "vsai" then
		if n == 40 then
			give(2, "legck", myTeam, cx + 200, cz)
			give(1, "leglab", myTeam, cx - 500, cz - 300)
			give(1, "legck", myTeam, cx, cz + 200)
		elseif n == 90 then
			local ck, lab = byName.legck or {}, byName.leglab or {}
			ids.def = SC.create("defense")
			SC.assign(ids.def, { ck[1], ck[2] })
			ids.army = SC.create("army")
			SC.assign(ids.army, { lab[1] })
			ids.aa = SC.create("airdefense")
			SC.assign(ids.aa, { ck[3] })
		end
	end
	if scenario == "duel" or scenario == "duelrules" then
		duel(n)
	end
	if scenario == "intel" then
		-- Intelligence sub-commander with two constructors and a vehicle plant (scouts), no enemy
		if n == 20 then
			Spring.SendCommands("setmaxspeed 20", "setspeed 4", "cheat 1")
		elseif n == 40 then
			give(2, "legck", myTeam, cx + 200, cz)
			give(1, "legvp", myTeam, cx - 450, cz + 300)
			give(4, "legwin", myTeam, cx + 400, cz + 400)
		elseif n == 150 then
			ids.intel = SC.create("intelligence")
			SC.addZone(ids.intel, { kind = "circle", x = cx, z = cz + 1200, r = 1300 })
			local units = {}
			for _, name in ipairs({ "legck", "legvp" }) do
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
			give(3, "legck", myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.assign(ids.eco, byName.legck or {})
			SC.setPosture(ids.eco, "spend")
		elseif n == 30 * 20 then
			ids.ck = (byName.legck or {})[2]
			playerBuild(ids.ck, "leglab", cx + 300, cz + 400, 0, 1)
		elseif n > 30 * 20 and n % 30 == 0 and n <= 30 * 100 then
			local st
			for _, u in ipairs(SC.get(ids.eco).units) do
				if u.id == ids.ck then
					st = (u.task or "-") .. (u.manual and " (manual)" or "")
				end
			end
			out(string.format("ck %s selected=%s owner=%s task=%s labs=%d", queueOf(ids.ck), tostring(Spring.IsUnitSelected(ids.ck)), tostring(SC.ownerOf(ids.ck)), tostring(st), #(byName.leglab or {})))
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
			give(3, "legck", myTeam, cx + 200, cz)
		elseif n == 120 then
			ids.eco = SC.create("economy")
			SC.addZone(ids.eco, { kind = "circle", x = cx, z = cz, r = 1000 })
			SC.assign(ids.eco, byName.legck or {})
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
			give(2, "legck", myTeam, cx + 200, cz)
			give(1, "leglab", myTeam, cx - 500, cz - 300)
			give(1, "legck", myTeam, cx, cz + 200)
		elseif n == 90 then
			local ck = byName.legck or {}
			local lab = byName.leglab or {}
			out("given", #ck, "legck", #lab, "leglab")
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

function widget:GameFrame(n)
	if deselectAt and n >= deselectAt then
		deselectAt = nil
		Spring.SelectUnitArray({})
	end
	local ok, err = pcall(gameFrame, n)
	if not ok then
		out("HARNESS ERROR: " .. tostring(err))
	end
end
