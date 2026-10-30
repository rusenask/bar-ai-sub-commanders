local function guard()
	local lines, reports = {}, {}
	local G = T.load("sc_guard")({
		echo = function(s)
			lines[#lines + 1] = s
		end,
		report = function(e)
			reports[#reports + 1] = e
		end,
		frame = function()
			return 42
		end,
	})
	return G, lines, reports
end

return {
	passes_results_through = function()
		local G = guard()
		local a, b = G.run("t", function(x, y, z)
			return x + y, z
		end, 1, 2, nil)
		T.eq(a, 3)
		T.eq(b, nil)
		local first, _, third = G.run("t", function(...)
			return ...
		end, "a", nil, "c")
		T.eq(first, "a")
		T.eq(third, "c", "nil arguments keep their place")
	end,
	error_is_logged_and_skipped = function()
		local G, lines, reports = guard()
		local r = G.run("Tactics.updatePush", function()
			return false < 0.6
		end)
		T.eq(r, nil)
		T.ok(lines[1]:find("^Sub%-Commanders ERROR %(Tactics%.updatePush, 1x%): .*attempt to compare"), lines[1])
		T.ok(not lines[1]:find("Error in"), "not the engine's crash line: the harness tells them apart")
		T.eq(#reports, 1)
		T.eq(reports[1].where, "Tactics.updatePush")
		T.eq(reports[1].count, 1)
		T.eq(reports[1].frame, 42)
		T.ok(reports[1].traceback and reports[1].traceback:find("traceback"), "first report has the traceback")
	end,
	repeats_are_throttled = function()
		local G, lines, reports = guard()
		local function bad()
			error("boom")
		end
		for _ = 1, 150 do
			G.run("step", bad)
		end
		T.eq(#reports, 3, "1st, 10th, 100th")
		T.eq(reports[2].count, 10)
		T.eq(reports[3].count, 100)
		T.eq(reports[2].traceback, nil)
		T.eq(G.total, 150)
		T.eq(#lines, 4, "three error lines and one traceback")
	end,
	wraps_widget_callins = function()
		local G, lines = guard()
		local w = {}
		function w:GetInfo()
			return {}
		end
		function w:Initialize()
			error("init fails as BAR intends")
		end
		function w:GameFrame(n)
			if n == 2 then
				error("bad frame")
			end
			self.last = n
		end
		function w:IsAbove()
			return true
		end
		w.include = print
		w.Echo = print
		local init = w.Initialize
		G.widget(w, "w", "guard_test.lua")
		T.eq(w.Initialize, init, "Initialize is left alone")
		T.eq(w.include, print, "BAR's functions in the widget table are left alone")
		T.eq(w.Echo, print, "system calls copied into the widget table are left alone")
		w:GameFrame(1)
		w:GameFrame(2)
		w:GameFrame(3)
		T.eq(w.last, 3, "the widget goes on after an error")
		T.eq(w:IsAbove(), true)
		T.ok(lines[1]:find("w:GameFrame"), lines[1])
	end,
}
