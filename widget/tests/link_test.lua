-- the file transport of sc_link.lua against a fake bridge (files in a temp dir)

-- a codec for flat messages: { type = "x", n = 1 } <-> "x|1"
local codec = {
	encode = function(t)
		return t.type .. "|" .. tostring(t.n or "")
	end,
	decode = function(s)
		local ty, n = s:match("^([^|]*)|(.*)$")
		if not ty then
			error("bad line")
		end
		return { type = ty, n = tonumber(n) }
	end,
}

local function tempdir()
	local d = os.tmpname()
	os.remove(d)
	os.execute("mkdir -p " .. d)
	return d .. "/"
end

local function readAll(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

local function link(dir, now, events, segment)
	return T.load("sc_link")({
		files = true, json = codec, dir = dir, segmentBytes = segment or 4096,
		clock = function()
			return now.t
		end,
		sessionID = function()
			return "s1"
		end,
		hello = function()
			return { type = "hello" }
		end,
		onConnect = function()
			events[#events + 1] = "connect"
		end,
		onMessage = function(m)
			events[#events + 1] = "msg:" .. m.type
		end,
		onDisconnect = function(r)
			events[#events + 1] = "down:" .. r
		end,
	})
end

return {
	files_connect_and_exchange = function()
		local dir, now, ev = tempdir(), { t = 0 }, {}
		local l = link(dir, now, ev)
		T.eq(l.transport(), "files")
		l.update()
		T.eq(l.status(), "connecting")
		T.eq(readAll(dir .. "session.txt"), "s1", "the session is announced")
		T.eq(readAll(dir .. "s1.w2b.0.jsonl"), "hello|\n", "hello opens it")
		T.eq(l.send({ type = "state" }), false, "nothing is sent before the bridge answers")
		-- the bridge answers
		local f = io.open(dir .. "s1.b2w.jsonl", "a")
		f:write("config|\n")
		f:close()
		now.t = now.t + 1
		l.update()
		T.eq(l.status(), "online")
		T.eq(ev[1], "connect")
		T.eq(ev[2], "msg:config")
		T.ok(l.send({ type = "state", n = 7 }))
		l.update()
		T.eq(readAll(dir .. "s1.w2b.0.jsonl"), "hello|\nstate|7\n")
		-- only new lines are delivered
		f = io.open(dir .. "s1.b2w.jsonl", "a")
		f:write("action|3\n")
		f:close()
		now.t = now.t + 1
		l.update()
		T.eq(#ev, 3)
		T.eq(ev[3], "msg:action")
	end,
	files_rotate_segments = function()
		local dir, now, ev = tempdir(), { t = 0 }, {}
		local l = link(dir, now, ev, 20)
		l.update()
		local f = io.open(dir .. "s1.b2w.jsonl", "a")
		f:write("config|\n")
		f:close()
		now.t = now.t + 1
		l.update()
		for i = 1, 5 do
			l.send({ type = "state", n = i })
			l.update()
		end
		local seg0 = readAll(dir .. "s1.w2b.0.jsonl")
		T.ok(seg0:find("next|\n$"), "a full segment ends with next")
		T.ok(readAll(dir .. "s1.w2b.1.jsonl"), "and the next one starts")
	end,
	files_silent_bridge_is_gone = function()
		local dir, now, ev = tempdir(), { t = 0 }, {}
		local l = link(dir, now, ev)
		l.update()
		local f = io.open(dir .. "s1.b2w.jsonl", "a")
		f:write("config|\n")
		f:close()
		now.t = 1
		l.update()
		now.t = 32
		l.update()
		T.eq(l.status(), "offline")
		T.eq(ev[#ev], "down:bridge silent")
		-- and it comes back on the same session
		now.t = 40
		l.update()
		T.eq(l.status(), "connecting")
		T.eq(readAll(dir .. "session.txt"), "s1")
	end,
}
