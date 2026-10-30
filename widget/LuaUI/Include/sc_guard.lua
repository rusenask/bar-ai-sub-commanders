-- Error protection for the widgets. BAR removes a widget whose callin raises an error, and the game goes on
-- with nobody controlling our units (docs/research/lessons.md). Guard.run calls a function, and an error
-- in it is logged and skipped instead: the next frame runs again.
--
-- Each error (where + message) is echoed with its traceback the first time, then at 10, 100, 1000...
-- repeats, as "Sub-Commanders ERROR (<where>, <n>x): <message>" (the batch harness counts these lines),
-- and handed to report() at the same moments (the AI widget sends it to the bridge: logs/widget-errors.jsonl).
--
-- opts: echo(text), report(err) where err = { where, message, traceback, count, frame }, frame() -> game frame
return function(opts)
	local G = { seen = {}, total = 0 } -- seen: repeats per where + message
	local echo = opts.echo or print
	local unpack = unpack or table.unpack

	local function milestone(n)
		if n == 1 then
			return true
		end
		while n >= 10 and n % 10 == 0 do
			n = n / 10
		end
		return n == 1
	end

	-- the traceback is built only for the first of each message (a repeating error runs every pass)
	local traced, lastTrace = {}, nil
	local function handler(e)
		local msg = tostring(e)
		lastTrace = nil
		if not traced[msg] and debug and debug.traceback then
			lastTrace = debug.traceback(msg, 2)
		end
		return msg
	end

	local function failed(where, msg)
		G.total = G.total + 1
		local key = where .. "|" .. msg
		local n = (G.seen[key] or 0) + 1
		G.seen[key], traced[msg] = n, true
		if not milestone(n) then
			return
		end
		echo(string.format("Sub-Commanders ERROR (%s, %dx): %s", where, n, msg))
		if n == 1 and lastTrace then
			echo(lastTrace)
		end
		if opts.report then
			pcall(opts.report, { where = where, message = msg, traceback = n == 1 and lastTrace or nil, count = n, frame = opts.frame and opts.frame() or nil })
		end
	end

	local function finish(where, ok, ...)
		if ok then
			return ...
		end
		failed(where, (...))
		return nil
	end

	-- fn(...)'s results, or nil when it raised an error
	function G.run(where, fn, ...)
		local n, args = select("#", ...), { ... }
		return finish(where, xpcall(function()
			return fn(unpack(args, 1, n))
		end, handler))
	end

	-- wrap the callins (capitalised functions) a widget file defines, but its loading and unloading: a widget
	-- that fails to start should fail as BAR intends. BAR's own functions in the widget table (include, and
	-- the system calls with locals access) stay as they are: file is part of the widget's file name.
	local SKIP = { GetInfo = true, Initialize = true, Shutdown = true }
	local function defined(fn, file)
		if not (debug and debug.getinfo) then
			return true
		end
		local src = debug.getinfo(fn, "S").source or ""
		return src:find(file, 1, true) ~= nil
	end
	function G.widget(w, name, file)
		local wrap = {}
		for callin, fn in pairs(w) do
			if type(fn) == "function" and callin:find("^%u") and not SKIP[callin] and defined(fn, file) then
				wrap[callin] = fn
			end
		end
		for callin, fn in pairs(wrap) do
			local where = name .. ":" .. callin
			w[callin] = function(...)
				return G.run(where, fn, ...)
			end
		end
	end

	return G
end
