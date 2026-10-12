-- Test harness for gui_subcommanders.lua (not shipped). Scenario comes from sctest_scenario.txt
function widget:GetInfo()
	return { name = "ZZ SubCommander Test", layer = 100, enabled = true }
end

local scenario = (VFS.LoadFile("sctest_scenario.txt", VFS.RAW) or "eco"):gsub("%s+", "")
local myTeam = Spring.GetMyTeamID()
local SC
local ids = {}
local byName = {}
local endFrame = (scenario == "vsai" and 30 * 60 * 9) or (scenario == "ai" and 30 * 60 * 4) or 30 * 60 * 6
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
		local n = UnitDefs[Spring.GetUnitDefID(u)].name
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
				tasks[#tasks + 1] = u.name .. ":" .. u.task .. (u.manual and "(manual)" or "")
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
			Spring.GiveOrderToUnit(ids.com, CMD.MOVE, { cx + 500, Spring.GetGroundHeight(cx + 500, cz + 300), cz + 300 }, {})
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
			Spring.GiveOrderToUnit(ck, -UnitDefNames.leglab.id, { x, Spring.GetGroundHeight(x, z), z, 0 }, {})
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
					Spring.GiveOrderToUnit(u, CMD.MOVE, { cx + 500, Spring.GetGroundHeight(cx + 500, cz + 300), cz + 300 }, {})
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
	if n == endFrame - 30 then
		Spring.SendCommands("screenshot png")
	elseif n == endFrame then
		report()
		out("DONE")
		Spring.SendCommands("quitforce")
	end
end

function widget:GameFrame(n)
	local ok, err = pcall(gameFrame, n)
	if not ok then
		out("HARNESS ERROR: " .. tostring(err))
	end
end
