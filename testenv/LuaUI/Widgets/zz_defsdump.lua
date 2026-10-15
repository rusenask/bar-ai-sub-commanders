-- Unit facts dump (test-only): every unit definition's name, faction prefix, human name, cost, tech
-- level, cloak and stealth abilities, speed, health, range and the kind sc_unitkinds gives it, written
-- to defsdump.jsonl (root, else LuaUI/Config) when defsdump.txt exists in the write dir; then quits.
-- Used to ground per-faction doctrine in the game's own data (testenv/defsdump.sh).
function widget:GetInfo()
	return { name = "ZZ Unit Facts Dump", layer = 102, enabled = true }
end

local function loadInput(name)
	return VFS.LoadFile("LuaUI/Config/" .. name, VFS.RAW) or VFS.LoadFile(name, VFS.RAW)
end

function widget:GameFrame(n)
	if n ~= 5 or not loadInput("defsdump.txt") then
		return
	end
	local kinds = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)
	local out = io.open("defsdump.jsonl", "w") or io.open("LuaUI/Config/defsdump.jsonl", "w")
	for id, ud in pairs(UnitDefs) do
		local k = kinds[id]
		local cp = ud.customParams or {}
		local fields = {
			string.format('"name":%q', ud.name), string.format('"human":%q', ud.translatedHumanName or ud.humanName or ""),
			string.format('"cost":%.0f', ud.metalCost or 0), string.format('"tech":%q', tostring(cp.techlevel or "")),
			string.format('"canCloak":%s', tostring(ud.canCloak or false)), string.format('"stealth":%s', tostring(ud.stealth or false)),
			string.format('"sonarStealth":%s', tostring(ud.sonarStealth or false)), string.format('"speed":%.0f', ud.speed or 0),
			string.format('"health":%.0f', ud.health or 0), string.format('"kind":%q', k and k.kind or ""),
			string.format('"range":%.0f', k and k.range or 0), string.format('"dps":%.0f', k and k.dps or 0),
			string.format('"mobile":%s', tostring(k and k.mobile or false)), string.format('"air":%s', tostring(k and k.air or false)),
			string.format('"builder":%s', tostring(ud.isBuilder or false)),
		}
		out:write("{" .. table.concat(fields, ",") .. "}\n")
	end
	out:close()
	Spring.SendCommands("quitforce")
end
