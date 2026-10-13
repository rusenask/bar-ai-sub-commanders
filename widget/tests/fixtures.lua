-- shared test fixtures: a few unit definitions in sc_unitkinds' shape
local F = {}
F.defs = {
	[1] = { name = "raider", mobile = true, armed = true, cost = 100, range = 200, kind = "raider" },
	[2] = { name = "turret", mobile = false, armed = true, staticDef = true, cost = 300, range = 450, kind = "turret" },
	[3] = { name = "aa", mobile = false, armed = true, staticDef = true, aaOnly = true, cost = 200, range = 800, kind = "anti-air turret" },
	[4] = { name = "artillery", mobile = true, armed = true, cost = 250, range = 1000, kind = "artillery" },
	[5] = { name = "mex", mobile = false, armed = false, cost = 50, range = 0, kind = "economy" },
	[6] = { name = "gunship", mobile = true, armed = true, air = true, cost = 150, range = 300, kind = "gunship" },
}
F.doctrine = dofile("widget/LuaUI/Include/sc_doctrine.lua")
function F.map(size)
	return T.load("sc_threatmap")({ defs = F.defs, mapX = size or 4096, mapZ = size or 4096, doctrine = F.doctrine })
end
return F
