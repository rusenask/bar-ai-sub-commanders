-- Sub-Commanders bridge link: one connection to scbridge carrying JSON messages, one per line, over
-- whichever transport this BAR allows:
--   tcp    LuaSocket to host:port (BAR up to game version test-31578)
--   files  append-only files in LuaUI/Config/scbridge/ (BAR test-31614+ takes sockets away from widgets
--          and allows writes only under LuaUI/Config/):
--            session.txt                this game's session id; the bridge treats a new one as a new link
--            <session>.w2b.<n>.jsonl    to the bridge, a new segment every segmentBytes, each closed with
--                                       {"type":"next"} (the bridge deletes segments it has read)
--            <session>.b2w.jsonl        from the bridge (small: actions, answers, a ping every 10 s)
-- The bridge side is internal/game (transport_tcp.go, transport_files.go).
--
-- usage: local Link = VFS.Include("LuaUI/Include/sc_link.lua", nil, VFS.RAW_FIRST)
--        local link = Link({ address = "127.0.0.1:7878", files = not socket, socket = socket, json = Json,
--                            hello = fn() -> message, onConnect = fn(), onMessage = fn(msg),
--                            onDisconnect = fn(reason) })
--        link.update()      -- every frame: connects, retries, sends what's queued, delivers what arrived
--        link.send(msg)     -- queued; false when not online
--        link.status()      -- "offline" | "connecting" | "online"
--        link.transport()   -- "tcp" | "files"
--        link.close()
-- Plain Lua with injectable socket / io / clock: unit-tested in widget/tests/link_test.lua.

return function(opts)
	local json = opts.json
	local clock = opts.clock or os.clock
	local fio = opts.io or io
	local RETRY = opts.retry or 5 -- seconds between connection attempts
	local SILENT = opts.silent or 30 -- files: a bridge silent this long is gone (it pings every 10 s)
	local SEGMENT = opts.segmentBytes or 2 * 1024 * 1024
	local DIR = opts.dir or "LuaUI/Config/scbridge/"
	local useFiles = opts.files and true or false

	local L = {}
	local state, t = "offline", nil
	local inbuf, outbuf = "", ""
	local nextAttempt, lastHeard, connectDeadline = 0, 0, 0

	local function deliver(chunk)
		inbuf = inbuf .. chunk
		while true do
			local nl = inbuf:find("\n", 1, true)
			if not nl then
				break
			end
			local line = inbuf:sub(1, nl - 1)
			inbuf = inbuf:sub(nl + 1)
			if #line > 0 then
				local ok, msg = pcall(json.decode, line)
				if ok and type(msg) == "table" then
					lastHeard = clock()
					if state == "connecting" then
						-- files: any message means the bridge has our session
						state = "online"
						if opts.onConnect then
							opts.onConnect()
						end
					end
					if opts.onMessage then
						opts.onMessage(msg)
					end
				end
			end
		end
	end

	-- the TCP transport: connect without blocking, then send / receive what's ready
	local function tcp()
		local sock = opts.socket
		local host, port = (opts.address or ""):match("^([^:]+):(%d+)$")
		if not sock or not host then
			return nil
		end
		local c = sock.tcp()
		c:settimeout(0)
		c:connect(host, tonumber(port))
		return {
			name = "tcp",
			-- nil: still connecting, true: connected, false: refused
			ready = function()
				local _, writable = sock.select(nil, { c }, 0)
				if writable and #writable > 0 then
					return c:getpeername() ~= nil
				end
				return nil
			end,
			write = function(s)
				local sent, err, last = c:send(s)
				return sent or last or 0, err == "closed"
			end,
			read = function()
				local data, err, partial = c:receive(65536)
				return data or partial, err == "closed"
			end,
			close = function()
				c:close()
			end,
		}
	end

	-- the file transport: announce the session, append to the current segment, read what the bridge added
	local function files()
		if opts.mkdir then
			opts.mkdir(DIR)
		end
		L.session = L.session or (opts.sessionID and opts.sessionID()) or tostring(os.time())
		local f = fio.open(DIR .. "session.txt", "w")
		if not f then
			return nil
		end
		f:write(L.session)
		f:close()
		local seg, written, inOffset, lastRead = L.segment or 0, 0, 0, -1
		local function open()
			return fio.open(DIR .. L.session .. ".w2b." .. seg .. ".jsonl", "a")
		end
		local out = open()
		if not out then
			return nil
		end
		return {
			name = "files",
			ready = function()
				return nil -- online once the bridge answers (deliver)
			end,
			write = function(s)
				out:write(s)
				written = written + #s
				if written >= SEGMENT then
					-- close this segment: the bridge moves on and deletes it
					out:write(json.encode({ type = "next" }) .. "\n")
					out:close()
					seg, written = seg + 1, 0
					L.segment = seg
					out = open()
				end
				if out then
					out:flush()
				end
				return #s, out == nil
			end,
			read = function()
				-- at most 5 times a second: Update runs every frame, the bridge polls every 150 ms anyway
				if clock() - lastRead < 0.2 then
					return nil, false
				end
				lastRead = clock()
				local fin = fio.open(DIR .. L.session .. ".b2w.jsonl", "r")
				if not fin then
					return nil, false
				end
				fin:seek("set", inOffset)
				local data = fin:read("*a")
				fin:close()
				if data and #data > 0 then
					inOffset = inOffset + #data
					return data, false
				end
				return nil, false
			end,
			close = function()
				if out then
					out:close()
				end
			end,
		}
	end

	local function disconnect(reason)
		local was = state
		if t then
			t.close()
		end
		t, state, inbuf, outbuf = nil, "offline", "", ""
		nextAttempt = clock() + RETRY
		if was == "online" and opts.onDisconnect then
			opts.onDisconnect(reason)
		end
	end

	local function connect()
		t = useFiles and files() or tcp()
		if not t then
			nextAttempt = clock() + RETRY * 6
			return
		end
		state, lastHeard, connectDeadline = "connecting", clock(), clock() + RETRY
		if t.name == "files" and opts.hello then
			-- files: the hello opens the session (the bridge answers it)
			t.write(json.encode(opts.hello()) .. "\n")
		end
	end

	function L.update()
		if state == "offline" then
			if clock() >= nextAttempt then
				connect()
			end
			return
		end
		if state == "connecting" and t.name == "tcp" then
			local r = t.ready()
			if r == true then
				state = "online"
				t.write(json.encode(opts.hello and opts.hello() or { type = "hello" }) .. "\n")
				if opts.onConnect then
					opts.onConnect()
				end
			elseif r == false or clock() > connectDeadline then
				disconnect(r == false and "refused" or "timeout")
			end
			return
		end
		if #outbuf > 0 and state == "online" then
			local n, closed = t.write(outbuf)
			outbuf = outbuf:sub(n + 1)
			if closed then
				disconnect("closed")
				return
			end
		end
		local data, closed = t.read()
		if data and #data > 0 then
			deliver(data)
		end
		if closed then
			disconnect("closed")
		elseif t and t.name == "files" and state == "online" and clock() - lastHeard > SILENT then
			disconnect("bridge silent")
		end
	end

	function L.send(msg)
		if state ~= "online" then
			return false
		end
		outbuf = outbuf .. json.encode(msg) .. "\n"
		return true
	end

	function L.status()
		return state
	end

	function L.transport()
		return useFiles and "files" or "tcp"
	end

	function L.close()
		if t then
			t.close()
		end
		t, state = nil, "offline"
	end

	return L
end
