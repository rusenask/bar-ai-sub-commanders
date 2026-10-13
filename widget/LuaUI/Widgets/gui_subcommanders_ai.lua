--------------------------------------------------------------------------------
-- Sub-Commanders AI link
--
-- Connects the Sub-Commanders widget to scbridge (localhost TCP, one JSON
-- object per line). The bridge runs the LLM strategist through opencode; this
-- widget only reports state and applies the high-level actions it sends back.
--
--   widget -> bridge: hello, state (every 3 game seconds), result, gameover
--   bridge -> widget: action { id, sub, op, args }
--
-- Address: springsettings.cfg "SubCommandersBridge" (default 127.0.0.1:7878).
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
local RETRY_SECONDS = 5

local address = Spring.GetConfigString("SubCommandersBridge", "127.0.0.1:7878")
local host, port = address:match("^([^:]+):(%d+)$")
port = tonumber(port)

local client
local link = "offline" -- offline | connecting | online
local nextAttempt = 0
local inbuf, outbuf = "", ""
local lastStateFrame = -STATE_EVERY
local announcedOffline = false

-- decision model behind the bridge (optional): requests waiting for an answer
local decider = { enabled = false, nextID = 0, pending = {} }

local ROLE_OK = { economy = true, defense = true, airdefense = true, army = true, intelligence = true }
local POSTURE_OK = { conserve = true, balanced = true, spend = true }

local function now()
	return os.clock()
end

local function SC()
	return WG.SubCommanders
end

local function send(msg)
	if link ~= "online" then
		return
	end
	outbuf = outbuf .. Json.encode(msg) .. "\n"
end

local function disconnect(reason)
	if client then
		client:close()
	end
	for id, cb in pairs(decider.pending) do
		decider.pending[id] = nil
		cb.fn(nil, "bridge disconnected")
	end
	decider.enabled = false
	client = nil
	inbuf, outbuf = "", ""
	if link == "online" then
		Spring.Echo("Sub-Commanders AI: bridge disconnected (" .. tostring(reason) .. ")")
	end
	link = "offline"
	nextAttempt = now() + RETRY_SECONDS
end

local function gameInfo()
	local myTeam = Spring.GetMyTeamID()
	local _, _, _, _, side = Spring.GetTeamInfo(myTeam, false)
	local name = Spring.GetPlayerInfo(Spring.GetMyPlayerID(), false)
	return {
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
		local v, err = sc.tune(args.key, args.value)
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
	elseif op == "set_autonomy" then
		if not (sc.setAutonomy and sc.setAutonomy(sub.id, args.autonomy)) then
			return nil, "autonomy must be light, balanced or full"
		end
	elseif op == "set_role" then
		if not ROLE_OK[args.role] then
			return nil, "role must be economy, defense, airdefense, army or intelligence"
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

local function handle(line)
	local ok, msg = pcall(Json.decode, line)
	if not ok or type(msg) ~= "table" then
		Spring.Echo("Sub-Commanders AI: bad message from bridge")
		return
	end
	if msg.type == "config" then
		decider.enabled = type(msg.args) == "table" and msg.args.decider == true
		return
	elseif msg.type == "decision" then
		local cb = decider.pending[msg.id]
		decider.pending[msg.id] = nil
		if cb then
			cb.fn(msg.ok and msg.data or nil, msg.error)
		end
		return
	end
	if msg.type == "action" then
		local okApply, data, err = pcall(apply, msg)
		if not okApply then
			data, err = nil, tostring(data)
		end
		send({ type = "result", id = msg.id, ok = data ~= nil, data = data ~= true and data or nil, error = err })
	end
end

local function pump()
	-- read
	local data, err, partial = client:receive(65536)
	local chunk = data or partial
	if chunk and #chunk > 0 then
		inbuf = inbuf .. chunk
		while true do
			local nl = inbuf:find("\n", 1, true)
			if not nl then
				break
			end
			local line = inbuf:sub(1, nl - 1)
			inbuf = inbuf:sub(nl + 1)
			if #line > 0 then
				handle(line)
			end
		end
	end
	if err == "closed" then
		disconnect("closed")
		return
	end
	-- write
	if #outbuf > 0 then
		local sent, werr, last = client:send(outbuf)
		local n = sent or last or 0
		if n > 0 then
			outbuf = outbuf:sub(n + 1)
		end
		if werr == "closed" then
			disconnect("closed")
		end
	end
end

local function tryConnect()
	if not socket or not host then
		return
	end
	client = socket.tcp()
	client:settimeout(0)
	client:connect(host, port)
	link = "connecting"
	nextAttempt = now() + RETRY_SECONDS
end

local function checkConnected()
	local _, writable = socket.select(nil, { client }, 0)
	if writable and #writable > 0 then
		if client:getpeername() then
			link = "online"
			announcedOffline = false
			Spring.Echo("Sub-Commanders AI: connected to bridge at " .. address)
			send({ type = "hello", game = gameInfo() })
			sendState()
			return
		end
		disconnect("refused")
	elseif now() > nextAttempt then
		disconnect("timeout")
	end
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
	if link == "offline" then
		if now() >= nextAttempt then
			tryConnect()
		elseif not announcedOffline then
			announcedOffline = true
			markOffline()
		end
	elseif link == "connecting" then
		checkConnected()
	else
		pump()
	end
end

function widget:GameFrame(n)
	if link == "online" and n - lastStateFrame >= STATE_EVERY then
		lastStateFrame = n
		sendState()
	elseif link ~= "online" and n % 300 == 0 then
		markOffline()
	end
end

function widget:GameOver()
	send({ type = "gameover" })
end

function widget:Initialize()
	if not socket then
		Spring.Echo("Sub-Commanders AI: LuaSocket is disabled (LuaSocketEnabled = 0)")
		widgetHandler:RemoveWidget()
		return
	end
	if Spring.GetSpectatingState() then
		widgetHandler:RemoveWidget()
		return
	end
	WG.SubCommandersAI = {
		linkStatus = function()
			return link
		end,
		address = address,
		-- is a decision model available behind the bridge?
		deciderReady = function()
			return link == "online" and decider.enabled
		end,
		-- ask the decision model: state (text), questions (systemone format); fn(answers, err) runs later
		decide = function(sub, state, questions, fn)
			if link ~= "online" or not decider.enabled then
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
			if link ~= "online" or not decider.enabled then
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
	if client then
		client:close()
	end
	WG.SubCommandersAI = nil
end
