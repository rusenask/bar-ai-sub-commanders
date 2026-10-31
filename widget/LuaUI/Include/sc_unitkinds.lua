-- Sub-Commanders unit classification, shared by the Sub-Commanders widget and test/logging widgets.
-- Returns a table defID -> traits (cost, kind, role flags, ranges, ...), computed once from UnitDefs.
-- usage: local defs = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)

local max, min, floor = math.max, math.min, math.floor
local AVG_WIND = ((Game.windMin or 0) + (Game.windMax or 0)) * 0.5
local TIDAL = Game.tidal or 0

local EXCLUDED_DEFENSE_GROUPS = { nuke = true, antinuke = true, explo = true, emp = true }

local defs = {}
for defID, ud in pairs(UnitDefs) do
	local cp = ud.customParams or {}
	local mobile = (ud.speed or 0) > 0 and not ud.isFactory
	local buildOptions = ud.buildOptions or {}
	local weapons = ud.weapons or {}
	local aaOnly = #weapons > 0
	for i = 1, #weapons do
		local only = weapons[i].onlyTargets or {}
		if not only.vtol then
			aaOnly = false
		end
	end
	local energy = (ud.energyMake or 0) - (ud.energyUpkeep or 0)
	if (ud.windGenerator or 0) > 0 then
		energy = energy + min(ud.windGenerator, AVG_WIND)
	end
	if (ud.tidalGenerator or 0) > 0 then
		energy = energy + ud.tidalGenerator * TIDAL
	end
	local group = cp.unitgroup
	local d = {
		name = ud.name,
		human = ud.translatedHumanName or ud.humanName or ud.name,
		group = group,
		tech = floor(tonumber(cp.techlevel) or 1),
		cost = (ud.metalCost or 0) + (ud.energyCost or 0) / 60,
		metal = ud.metalCost or 0,
		energyCost = ud.energyCost or 0,
		hx = (ud.xsize or 2) * 4,
		hz = (ud.zsize or 2) * 4,
		mobile = mobile,
		air = ud.canFly and true or false,
		commander = cp.iscommander and true or false,
		factory = ud.isFactory and true or false,
		options = buildOptions,
		armed = #weapons > 0,
		range = ud.maxWeaponRange or 0,
	}
	d.aaOnly = d.armed and (aaOnly or group == "aa")
	d.builder = ud.isBuilder and mobile and #buildOptions > 0
	d.reclaimer = d.builder and ud.canReclaim and (ud.reclaimSpeed or 0) > 0
	d.nano = ud.isBuilder and not mobile and not ud.isFactory and (ud.buildSpeed or 0) > 0
	d.buildRange = ud.buildDistance or 0
	d.combat = mobile and d.armed and not d.builder and (ud.transportCapacity or 0) == 0
	d.staticDef = not mobile and not ud.isFactory and not ud.isBuilder and d.armed and not EXCLUDED_DEFENSE_GROUPS[group] and d.range > 0 and d.range <= 1200 and not cp.stockpilelimit
	d.mex = (ud.extractsMetal or 0) > 0 and not mobile and ud.extractsMetal or 0
	d.energy = (not mobile and group == "energy" and not cp.geothermal and energy > 0) and energy or 0
	d.conv = (not mobile and tonumber(cp.energyconv_capacity)) or 0
	d.mstore = (not mobile and d.mex == 0 and group == "metal" and (ud.metalStorage or 0) >= 500) and ud.metalStorage or 0
	d.estore = (not mobile and d.energy == 0 and group == "energy" and (ud.energyStorage or 0) >= 1000) and ud.energyStorage or 0
	d.radar = (not mobile and not d.armed and (ud.radarDistance or 0) >= 1200 and d.cost < 200) and ud.radarDistance or 0
	-- intelligence
	d.radarRange = ud.radarDistance or 0
	d.jammer = (ud.radarDistanceJam or 0) > 0 and ud.radarDistanceJam or 0
	d.sonar = (not mobile and (ud.sonarDistance or 0) > 0) and ud.sonarDistance or 0
	d.seismic = (ud.seismicDistance or 0) > 0 and ud.seismicDistance or 0
	d.sight = ud.sightDistance or ud.losRadius or 0
	d.camera = not mobile and not d.armed and (ud.cloakCost or 0) > 0 and d.cost < 100
	d.scout = mobile and not d.builder and not d.air and d.cost < 45 and (ud.speed or 0) >= 120 and d.sight >= 550
	-- the spies (Ghost, Spectre, Eidolon): cloaking, radar-stealthy "builders" without build options and a
	-- dummy weapon, whose self-destruct is an EMP (SPYBOMBX). (d.builder needs build options: tested on it,
	-- this was never true)
	d.spy = mobile and (ud.cloakCost or 0) > 0 and ud.stealth and ud.isBuilder and #buildOptions == 0 and not cp.iscommander
	d.decloak = ud.decloakDistance or ud.minCloakDistance or 75
	d.mobileSonar = mobile and (ud.sonarDistance or 0) > 0
	d.canCloak = ud.canCloak or false
	-- abilities (docs/research/units.md, scripts/unit_catalogue.py)
	local ucp = ud.customParams or {}
	d.stealthy = ud.stealth or false
	d.resurrect = ud.canResurrect or false
	d.capture = ud.canCapture or false
	d.mine = ucp.mine ~= nil
	d.decoy = ucp.decoyfor ~= nil
	d.kamikaze = ud.canKamikaze or ucp.instantselfd ~= nil
	d.paralyzer, d.interceptor, d.stockpile, d.shield, d.flame, d.juno = false, false, false, false, false, false
	d.intelStructure = not mobile and (d.radarRange >= 1000 or d.jammer > 0 or d.sonar > 0 or d.seismic > 0 or d.camera)
	-- what a weapon loadout says about a unit
	local bomb, arty = false, false
	d.dps = 0
	-- damage per second against ground and against aircraft, by what each weapon may target: the Slasher
	-- and the Samson have a weak ground missile next to their anti-air one (63 vs 120 a hit, preferring air;
	-- strong players' fire 4-7% of the time near ground armies): they are anti-air, not skirmishers
	local vtolArmor = Game.armorTypes and Game.armorTypes.vtol
	d.groundDps, d.airDps = 0, 0
	for i = 1, #weapons do
		local wd = WeaponDefs[weapons[i].weaponDef]
		if wd then
			bomb = bomb or wd.type == "AircraftBomb"
			-- special weapons (docs/research/units.md): what a unit can do beyond damage
			d.paralyzer = d.paralyzer or wd.paralyzer or false
			d.interceptor = d.interceptor or ((wd.interceptor or 0) > 0)
			d.stockpile = d.stockpile or wd.stockpile or false
			d.shield = d.shield or wd.type == "Shield" or ((wd.shieldPower or 0) > 0)
			d.flame = d.flame or wd.type == "Flame"
			d.juno = d.juno or ((wd.name or ""):lower():find("juno") ~= nil)
			d.weaponAoe = max(d.weaponAoe or 0, wd.damageAreaOfEffect or 0)
			arty = arty or (wd.highTrajectory == 1 and (wd.range or 0) >= 600)
			local per = (wd.salvoSize or 1) * (wd.projectiles or 1) / max(wd.reload or 1, 0.1)
			local dmg = wd.damages and wd.damages[0] or 0
			d.dps = d.dps + dmg * per
			-- a weapon hits the ground unless aircraft are all it may target
			local only = weapons[i].onlyTargets or {}
			local airOnly = only.vtol and next(only, next(only)) == nil and next(only) == "vtol"
			if not airOnly then
				d.groundDps = d.groundDps + dmg * per
			end
			if next(only) == nil or only.vtol then
				d.airDps = d.airDps + ((vtolArmor and wd.damages and wd.damages[vtolArmor]) or dmg) * per
			end
		end
	end
	-- (treating mostly-anti-air units as anti-air for production was tried in v28 and reverted: Cortex
	-- can't tell, Legion's opening worse. The numbers stay for analysis.)
	d.aaPrimary = mobile and d.armed and d.groundDps > 0 and d.airDps > 1.5 * d.groundDps
	-- strategic roles (docs/research/units.md): what the Intelligence, Defense and Army jobs look for
	d.antinuke = not mobile and d.interceptor
	d.nukeSilo = not mobile and d.stockpile and not d.interceptor and not d.juno and (d.weaponAoe or 0) >= 500
	d.lrpc = not mobile and d.armed and not d.stockpile and not d.interceptor and d.range >= 3000 and d.range < 20000
	d.shieldGen = not mobile and d.shield
	-- the Juno silo (Legion's Blindfold gunship carries a Juno weapon too: the Air Force flies it)
	d.junoSilo = not mobile and d.juno
	d.rezBot = mobile and d.resurrect and not d.commander
	local move = ud.moveDef and ud.moveDef.name or ""
	d.naval = mobile and not d.air and (move:find("boat") ~= nil or (ud.minWaterDepth or 0) > 0)
	d.hover = mobile and move:find("hover") ~= nil
	-- how deep the water it can go into: land units 20 (BAR's movedefs), amphibious 5000; hovers and ships
	-- go anywhere on water (deepWater: what a fleet at sea can be reached with)
	d.maxDepth = ud.maxWaterDepth or 20
	d.deepWater = mobile and not d.air and (d.naval or d.hover or d.maxDepth >= 255)
	-- submarines (UBOAT movedefs): hidden from all but sonar
	-- (not construction or resurrection subs: Legion's 240-metal Dionysus was Intelligence's "cheapest sub",
	-- 9 in 6 Boulder Beach games)
	d.sub = d.naval and move:lower():find("uboat") ~= nil and not (ud.isBuilder or d.resurrect)
	d.speed = ud.speed or 0
	d.health = ud.health or 0
	d.transport = (ud.transportCapacity or 0) > 0
	if d.commander then
		d.kind = "commander"
	elseif ud.isFactory then
		d.kind = "factory"
	elseif d.builder or d.nano then
		d.kind = "constructor"
	elseif not mobile then
		if d.staticDef then
			d.kind = d.aaOnly and "anti-air turret" or "turret"
		elseif d.armed and d.range > 1200 then
			d.kind = "long-range artillery"
		elseif d.intelStructure then
			d.kind = d.jammer > 0 and "jammer" or (d.camera and "camera" or "radar")
		else
			d.kind = "economy"
		end
	elseif d.air then
		d.kind = d.transport and "air transport" or (not d.armed and "scout plane") or (d.aaOnly and "fighter") or (bomb and "bomber") or "gunship"
	elseif d.naval then
		d.kind = "naval"
	elseif not d.armed then
		d.kind = d.jammer > 0 and "mobile jammer" or (d.radarRange > 0 and "mobile radar" or "utility")
	elseif d.aaOnly then
		d.kind = "mobile anti-air"
	elseif arty then
		d.kind = "artillery"
	elseif d.scout then
		d.kind = "scout"
	elseif d.range >= 500 then
		-- armoured long-range units too (Tzar, Fatboy, Legion's Incinerator and Javelin): calling them heavies
		-- (health 4000+ and 3.5 x cost) cost Legion -0.15 [-0.31, +0.02] over 36 pairs, wins 21 -> 16
		d.kind = "skirmisher"
	elseif d.speed >= 70 and d.cost <= 120 then
		d.kind = "raider"
	elseif d.cost >= 300 or d.health >= 2000 then
		d.kind = "heavy"
	else
		d.kind = "assault"
	end
	if d.hover and d.mobile and not d.air then
		d.kind = "hover " .. d.kind
	end
	-- a spy's dummy weapon does nothing: not a fighter (the Ghost read as a 285-metal "assault" unit)
	if d.spy then
		d.armed, d.combat, d.dps, d.groundDps, d.kind = false, false, 0, 0, "spy"
	end
	defs[defID] = d
end

return defs
