--------------------------------------------------------------------------------
-- Sub-Commanders AI link
--
-- Connects the Sub-Commanders widget to scbridge (one JSON object per line over
-- sc_link.lua: TCP, or files in LuaUI/Config/scbridge/ where BAR takes sockets away). The bridge runs the LLM strategist through opencode; this
-- widget only reports state and applies the high-level actions it sends back.
--
--   widget -> bridge: hello, state (every 3 game seconds), result, gameover
--   bridge -> widget: action { id, sub, op, args }
--
-- Address: springsettings.cfg "SubCommandersBridge" (default 127.0.0.1:7878).
-- BAR from game version test-31614 takes sockets away from user widgets: the link then runs through files
-- in LuaUI/Config/scbridge/ (session.txt, <session>.w2b.jsonl, <session>.b2w.jsonl), which the bridge
-- watches with -game-files (internal/game/files.go; compose.yaml mounts the folder).
--------------------------------------------------------------------------------

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Sub-Commanders AI link",
		desc = "Lets an LLM strategist (scbridge + opencode) steer AI-enabled sub-commanders",
		author = "karolis",
		date = "2026-10-12",
		license = "GNU GPL, v2 or later",
		layer = 6,
		enabled = true,
	}
end

local PROTOCOL = 1
local STATE_EVERY = 90 -- frames

local address = Spring.GetConfigString("SubCommandersBridge", "127.0.0.1:7878")
-- the connection to the bridge (sc_link.lua, made in Initialize): TCP, or files where BAR takes sockets
-- away from widgets (test-31614+); springsettings.cfg SubCommandersBridgeFiles = 1 forces files
local link
local lastStateFrame = -STATE_EVERY
local announcedOffline = false

-- decision model behind the bridge (optional): requests waiting for an answer
local decider = { enabled = false, nextID = 0, pending = {} }

local ROLE_OK = { economy = true, defense = true, airdefense = true, army = true, intelligence = true, air = true }
local POSTURE_OK = { conserve = true, balanced = true, spend = true }

local function SC()
	return WG.SubCommanders
end

local function send(msg)
	return link ~= nil and link.send(msg)
end

local function linkStatus()
	return link and link.status() or "offline"
end

local function gameInfo()
	local myTeam = Spring.GetMyTeamID()
	local _, _, _, _, side = Spring.GetTeamInfo(myTeam, false)
	local name = Spring.GetPlayerInfo(Spring.GetMyPlayerID(), false)
	-- the enemies' factions and AIs: the bridge picks what was learned for this matchup (internal/learn)
	local enemies, ais = {}, {}
	local myAlly = Spring.GetMyAllyTeamID()
	for _, t in ipairs(Spring.GetTeamList() or {}) do
		local _, _, _, isAI, tside, ally = Spring.GetTeamInfo(t, false)
		if ally ~= myAlly and t ~= Spring.GetGaiaTeamID() then
			enemies[#enemies + 1] = tside
			if isAI then
				local _, aiName = Spring.GetAIInfo(t)
				ais[#ais + 1] = aiName or "AI"
			end
		end
	end
	return {
		enemies = enemies,
		ais = ais,
		protocol = PROTOCOL,
		map = Game.mapName,
		mapX = Game.mapSizeX,
		mapZ = Game.mapSizeZ,
		team = myTeam,
		faction = side,
		player = name,
		frame = Spring.GetGameFrame(),
		windMin = Game.windMin or 0,
		windMax = Game.windMax or 0,
		tidal = Game.tidal or 0,
	}
end

-- drop per-unit lists: composition/activity summaries are enough for the strategist
local function compactSubs(list)
	for _, s in ipairs(list) do
		s.unitCount = #s.units
		s.units = nil
	end
	return list
end

local function sendState()
	local sc = SC()
	if not sc then
		return
	end
	local _, _, paused = Spring.GetGameSpeed()
	send({
		type = "state",
		state = {
			frame = Spring.GetGameFrame(),
			paused = paused and true or false,
			economy = sc.economy(),
			subs = compactSubs(sc.list()),
			enemy = sc.enemyIntel and sc.enemyIntel() or nil,
			allies = sc.allies and sc.allies() or nil, -- our allies' bases { team, x, z } (cover_ally)
			team = sc.teamReport and sc.teamReport() or nil,
		},
	})
end

local function findSub(id)
	local sc = SC()
	return sc and sc.get(id)
end

-- ground heights on a grid over x1..x2, z1..z2 (cell centres, row by row from z1),
-- sent as one comma-separated string: much cheaper to encode than a JSON array
local function terrain(args)
	local x1, z1 = math.max(0, tonumber(args.x1) or 0), math.max(0, tonumber(args.z1) or 0)
	local x2, z2 = math.min(Game.mapSizeX, tonumber(args.x2) or Game.mapSizeX), math.min(Game.mapSizeZ, tonumber(args.z2) or Game.mapSizeZ)
	local cells = math.max(16, math.min(320, tonumber(args.cells) or 256))
	if x2 - x1 < 64 or z2 - z1 < 64 then
		return nil, "terrain area too small"
	end
	local step = math.max(x2 - x1, z2 - z1) / cells
	local w, h = math.ceil((x2 - x1) / step), math.ceil((z2 - z1) / step)
	local heights, n = {}, 0
	local ground = Spring.GetGroundHeight
	local floor = math.floor
	for j = 0, h - 1 do
		local z = math.min(z2, z1 + (j + 0.5) * step)
		for i = 0, w - 1 do
			n = n + 1
			heights[n] = floor(ground(math.min(x2, x1 + (i + 0.5) * step), z) + 0.5)
		end
	end
	return { x1 = x1, z1 = z1, x2 = x2, z2 = z2, w = w, h = h, step = step, heights = table.concat(heights, ",") }
end

-- returns data, error
local function apply(msg)
	local sc = SC()
	if not sc then
		return nil, "Sub-Commanders widget is not running"
	end
	local sub = findSub(msg.sub)
	if not sub then
		return nil, "no sub-commander with id " .. tostring(msg.sub)
	end
	local op, args = msg.op, msg.args or {}
	-- status/notes are allowed even with AI switched off so the strategist can say why it stopped
	if op == "status" then
		sc.setAIStatus(sub.id, args.text)
		return true
	elseif op == "note" then
		sc.noteAI(sub.id, args.text)
		return true
	end
	if not sub.ai then
		return nil, "the player switched the AI off for this sub-commander"
	end
	if op == "set_posture" then
		if not POSTURE_OK[args.posture] then
			return nil, "posture must be conserve, balanced or spend"
		end
		sc.setPosture(sub.id, args.posture)
	elseif op == "tune_rules" then
		if not sc.tune then
			return nil, "rule tuning isn't available in this widget version"
		end
		local v, err = sc.tune(args.key, args.value, sub.role)
		if not v then
			return nil, err
		end
		sc.noteAI(sub.id, string.format("tuned %s = %s", tostring(args.key), tostring(v)))
		return { key = args.key, value = v }
	elseif op == "set_raids" then
		if not sc.setRaids then
			return nil, "raids aren't available in this widget version"
		end
		sc.setRaids(sub.id, args.on and true or false)
	elseif op == "set_army_style" then
		if not (sc.setArmyStyle and sc.setArmyStyle(args.style)) then
			return nil, "style is auto, balanced, skirmish, siege, harass or hold"
		end
		sc.noteAI(sub.id, "army style: " .. tostring(args.style))
	elseif op == "set_commander" then
		if not (sc.setCommander and sc.setCommander(args.set)) then
			return nil, "set is a mode (auto, builder, defender, frontline) or a personality (careful, bold)"
		end
		sc.noteAI(sub.id, "commander: " .. tostring(args.set))
	elseif op == "request_help" then
		local kinds = { defend = true, constructor = true, production = true, cover = true }
		if not sc.request or not kinds[args.kind] then
			return nil, "kind is defend, constructor, production or cover (air cover from the Air Force)"
		end
		if (args.kind == "defend" or args.kind == "cover") and not (tonumber(args.x) and tonumber(args.z)) then
			return nil, args.kind .. " needs x and z"
		end
		sc.request({ kind = args.kind, from = sub.id, x = tonumber(args.x), z = tonumber(args.z), need = tonumber(args.need) or 0, note = args.note, ai = true })
		sc.noteAI(sub.id, "asked the team for " .. args.kind)
	elseif op == "cover_ally" then
		-- the Air Force covers our nearest ally's base
		if not (sc.coverAlly and sc.coverAlly(sub.id)) then
			return nil, "no ally to cover"
		end
	elseif op == "cover_area" then
		if not (sc.coverArea and tonumber(args.x) and tonumber(args.z) and sc.coverArea(sub.id, tonumber(args.x), tonumber(args.z), tonumber(args.radius))) then
			return nil, "cover_area needs x and z"
		end
	elseif op == "set_autonomy" then
		if not (sc.setAutonomy and sc.setAutonomy(sub.id, args.autonomy)) then
			return nil, "autonomy must be light, balanced or full"
		end
	elseif op == "set_role" then
		if not ROLE_OK[args.role] then
			return nil, "role must be economy, defense, army, intelligence or air (the Air Force: air attack and air defence)"
		end
		sc.setRole(sub.id, args.role)
	elseif op == "set_focus" then
		local names, unknown = {}, {}
		for _, n in ipairs(args.units or {}) do
			if UnitDefNames[n] then
				names[#names + 1] = n
			else
				unknown[#unknown + 1] = n
			end
		end
		if #unknown > 0 then
			return nil, "unknown unit names: " .. table.concat(unknown, ", ") .. " (use get_build_options)"
		end
		sc.setFocus(sub.id, names)
	elseif op == "add_zone" then
		local z = args.zone or {}
		local maxX, maxZ = Game.mapSizeX, Game.mapSizeZ
		local zone
		if z.kind == "circle" and tonumber(z.x) and tonumber(z.z) and tonumber(z.r) then
			zone = { kind = "circle", x = math.max(0, math.min(maxX, z.x)), z = math.max(0, math.min(maxZ, z.z)), r = math.max(200, math.min(3000, z.r)) }
		elseif z.kind == "rect" and tonumber(z.x1) and tonumber(z.z1) and tonumber(z.x2) and tonumber(z.z2) then
			local x1, x2 = math.min(z.x1, z.x2), math.max(z.x1, z.x2)
			local z1, z2 = math.min(z.z1, z.z2), math.max(z.z1, z.z2)
			if x2 - x1 < 200 or z2 - z1 < 200 then
				return nil, "rect zones must be at least 200x200"
			end
			zone = { kind = "rect", x1 = math.max(0, x1), z1 = math.max(0, z1), x2 = math.min(maxX, x2), z2 = math.min(maxZ, z2) }
		else
			return nil, "zone needs kind=circle with x,z,r or kind=rect with x1,z1,x2,z2"
		end
		sc.addZone(sub.id, zone)
	elseif op == "clear_zones" then
		sc.clearZones(sub.id)
	elseif op == "set_paused" then
		sc.setPaused(sub.id, args.paused and true or false)
	elseif op == "build_options" then
		return sc.buildOptions(sub.id)
	elseif op == "structures" then
		return sc.structures(sub.id, args.kind, args.blocking_only and true or false)
	elseif op == "remove_structures" then
		local ids = {}
		for _, u in ipairs(args.unit_ids or {}) do
			if tonumber(u) then
				ids[#ids + 1] = tonumber(u)
			end
		end
		return sc.removeStructures(sub.id, ids)
	elseif op == "map_view" then
		return sc.mapView(sub.id, args.view)
	elseif op == "terrain" then
		return terrain(args)
	elseif op == "tell_player" then
		sc.noteAI(sub.id, args.text)
		Spring.Echo("[" .. sub.name .. "] " .. tostring(args.text))
	else
		return nil, "unknown op " .. tostring(op)
	end
	return true
end

-- what the bridge sends: actions for sub-commanders, decision-model answers, learned rules, its config
local function onMessage(msg)
	if msg.type == "learned" then
		-- rules learned from past games of this matchup (internal/learn), for the whole team
		local sc = SC()
		if sc and sc.applyLearned and type(msg.args) == "table" then
			sc.applyLearned(msg.args)
		end
	elseif msg.type == "config" then
		decider.enabled = type(msg.args) == "table" and msg.args.decider == true
	elseif msg.type == "decision" then
		local cb = decider.pending[msg.id]
		decider.pending[msg.id] = nil
		if cb then
			cb.fn(msg.ok and msg.data or nil, msg.error)
		end
	elseif msg.type == "action" then
		local okApply, data, err = pcall(apply, msg)
		if not okApply then
			data, err = nil, tostring(data)
		end
		send({ type = "result", id = msg.id, ok = data ~= nil, data = data ~= true and data or nil, error = err })
	end
end

local function onConnect()
	announcedOffline = false
	Spring.Echo("Sub-Commanders AI: connected to the bridge (" .. link.transport() .. ")")
	sendState()
end

local function onDisconnect(reason)
	for id, cb in pairs(decider.pending) do
		decider.pending[id] = nil
		cb.fn(nil, "bridge disconnected")
	end
	decider.enabled = false
	Spring.Echo("Sub-Commanders AI: bridge disconnected (" .. tostring(reason) .. ")")
end

local function markOffline()
	local sc = SC()
	if not sc then
		return
	end
	for _, s in ipairs(sc.list()) do
		if s.ai and s.aiStatus ~= "bridge offline: run make up in bar-ai-sub-commanders" then
			sc.setAIStatus(s.id, "bridge offline: run make up in bar-ai-sub-commanders")
		end
	end
end

function widget:Update()
	link.update()
	if link.status() == "offline" and not announcedOffline then
		announcedOffline = true
		markOffline()
	end
end

function widget:GameFrame(n)
	if linkStatus() == "online" and n - lastStateFrame >= STATE_EVERY then
		lastStateFrame = n
		sendState()
	elseif linkStatus() ~= "online" and n % 300 == 0 then
		markOffline()
	end
end

function widget:GameOver(winners)
	-- what the bridge learns from: did we win, how long, the damage trade
	local won = false
	for _, a in ipairs(winners or {}) do
		won = won or a == Spring.GetMyAllyTeamID()
	end
	local summary = { won = won, minutes = Spring.GetGameFrame() / 1800 }
	local team = Spring.GetMyTeamID()
	local n = Spring.GetTeamStatsHistory(team)
	local stats = n and n > 0 and Spring.GetTeamStatsHistory(team, n)
	local last = stats and stats[#stats]
	if last then
		summary.dealt, summary.taken, summary.metal = last.damageDealt, last.damageReceived, last.metalProduced
	end
	send({ type = "gameover", args = summary })
end

function widget:Initialize()
	if Spring.GetSpectatingState() then
		widgetHandler:RemoveWidget()
		return
	end
	local files = not socket or Spring.GetConfigInt("SubCommandersBridgeFiles", 0) == 1
	link = VFS.Include("LuaUI/Include/sc_link.lua", nil, VFS.RAW_FIRST)({
		address = address,
		files = files,
		socket = socket,
		json = Json,
		mkdir = function(dir)
			Spring.CreateDir(dir)
		end,
		sessionID = function()
			return tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
		end,
		hello = function()
			return { type = "hello", game = gameInfo() }
		end,
		onConnect = onConnect,
		onMessage = onMessage,
		onDisconnect = onDisconnect,
	})
	if files then
		Spring.Echo("Sub-Commanders AI: no sockets here (newer BAR, or forced): linking through LuaUI/Config/scbridge/")
	end
	WG.SubCommandersAI = {
		linkStatus = linkStatus,
		address = address,
		-- is a decision model available behind the bridge?
		deciderReady = function()
			return linkStatus() == "online" and decider.enabled
		end,
		-- ask the decision model: state (text), questions (systemone format); fn(answers, err) runs later
		decide = function(sub, state, questions, fn)
			if linkStatus() ~= "online" or not decider.enabled then
				return false
			end
			decider.nextID = decider.nextID + 1
			decider.pending[-decider.nextID] = { fn = fn, frame = Spring.GetGameFrame() }
			send({ type = "decide", id = -decider.nextID, sub = sub, args = { state = state, questions = questions } })
			return true
		end,
		-- ask one of our own decision models (design/decision-models.md): the bridge renders the features
		-- of task "fight", "unit" or "turret" into text and routes the request; fn(answers, err) runs later
		decideTask = function(sub, task, features, fn)
			if linkStatus() ~= "online" or not decider.enabled then
				return false
			end
			decider.nextID = decider.nextID + 1
			decider.pending[-decider.nextID] = { fn = fn, frame = Spring.GetGameFrame() }
			send({ type = "decide", id = -decider.nextID, sub = sub, args = { task = task, features = features } })
			return true
		end,
	}
end

function widget:Shutdown()
	if link then
		link.close()
	end
	WG.SubCommandersAI = nil
end
