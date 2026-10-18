-- Per-widget CPU time for docs/research/speed.md (not shipped). Only runs when LuaUI/Config/sctest_profile.txt
-- exists (testenv/speedbench.sh PROFILE=1): wraps every widget's callins through BAR's widget_profiling
-- include and writes the top widgets by total time to LuaUI/Config/sctest_speedprof.txt every 5 game minutes.
function widget:GetInfo()
	return { name = "ZZ Speed Profiler", layer = -99990, enabled = true, handler = true }
end

local profiling
local noGadgets
local total = {}
local callinTotal = {} -- the Sub-Commanders widget's time by callin (own wrappers: the include's detail
-- view is shared with the widget selector, which keeps switching it)
local DETAIL = "Sub-Commanders"
local lastGen = 0

function widget:Initialize()
	local opts = VFS.LoadFile("LuaUI/Config/sctest_profile.txt", VFS.RAW)
	if not opts then
		widgetHandler:RemoveWidget(self)
		return
	end
	noGadgets = opts:find("nogadgets") ~= nil
	if opts:find("nowidgets") then
		return
	end
	profiling = VFS.Include("luaui/Include/widget_profiling.lua")
	profiling.subscribe(self, 0.5)
end

function widget:Shutdown()
	if profiling then
		profiling.unsubscribe(self)
	end
end

local function dump(n)
	local list = {}
	for name, t in pairs(total) do
		list[#list + 1] = { name, t }
	end
	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)
	local f = io.open("LuaUI/Config/sctest_speedprof.txt", "a")
	if not f then
		return
	end
	f:write(string.format("frame %d\n", n))
	for i = 1, math.min(25, #list) do
		f:write(string.format("%8.0f ms  %s\n", list[i][2] * 1000, list[i][1]))
	end
	local cl = {}
	for name, t in pairs(callinTotal) do
		cl[#cl + 1] = { name, t }
	end
	table.sort(cl, function(a, b)
		return a[2] > b[2]
	end)
	for i = 1, math.min(10, #cl) do
		f:write(string.format("%8.0f ms  %s:%s\n", cl[i][2] * 1000, DETAIL, cl[i][1]))
	end
	-- an instrumented copy of the widget (docs/research/speed.md) times GameFrame's steps into WG.scprof
	local sl = {}
	for name, t in pairs(WG.scprof or {}) do
		sl[#sl + 1] = { name, t }
	end
	table.sort(sl, function(a, b)
		return a[2] > b[2]
	end)
	for i = 1, math.min(20, #sl) do
		f:write(string.format("%8.0f ms  GameFrame:%s\n", sl[i][2] * 1000, sl[i][1]))
	end
	f:close()
end

function widget:Update()
	-- another reader (the widget selector) may have taken this tick's sample: follow gen
	if profiling and (profiling.sample() or profiling.gen ~= lastGen) then
		lastGen = profiling.gen
		for name, e in pairs(profiling.stats) do
			total[name] = (total[name] or 0) + (e.share or 0) * profiling.deltaTime
		end
	end
end

local CALLINS = { "GameFrame", "Update", "DrawScreen", "DrawWorldPreUnit", "UnitCreated", "UnitFinished",
	"UnitDestroyed", "UnitIdle", "UnitCommand", "UnitEnteredLos", "UnitEnteredRadar", "UnitTaken", "AddConsoleLine" }
local wrapped = false
local function wrapDetail()
	local w = widgetHandler:FindWidget(DETAIL)
	if not w then
		return
	end
	for _, name in ipairs(CALLINS) do
		local f = w[name]
		if type(f) == "function" then
			w[name] = function(...)
				local t = Spring.GetTimer()
				local a, b, c, d = f(...)
				callinTotal[name] = (callinTotal[name] or 0) + Spring.DiffTimers(Spring.GetTimer(), t)
				return a, b, c, d
			end
		end
	end
	wrapped = true
end

function widget:GameFrame(n)
	if profiling and not wrapped then
		wrapDetail()
	end
	-- the gadget profiler only draws on screen: the harness's closing screenshot shows it
	if n == 60 and not noGadgets then
		Spring.SendCommands("luarules profile")
	end
	if n > 0 and n % 9000 == 0 then
		dump(n)
	end
end
