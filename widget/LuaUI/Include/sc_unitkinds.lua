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
	d.spy = mobile and (ud.cloakCost or 0) > 0 and ud.stealth and d.builder and not d.commander
	d.intelStructure = not mobile and (d.radarRange >= 1000 or d.jammer > 0 or d.sonar > 0 or d.seismic > 0 or d.camera)
	-- what a weapon loadout says about a unit
	local bomb, arty = false, false
	d.dps = 0
	for i = 1, #weapons do
		local wd = WeaponDefs[weapons[i].weaponDef]
		if wd then
			bomb = bomb or wd.type == "AircraftBomb"
			arty = arty or (wd.highTrajectory == 1 and (wd.range or 0) >= 600)
			local dmg = wd.damages and wd.damages[0] or 0
			d.dps = d.dps + dmg * (wd.salvoSize or 1) * (wd.projectiles or 1) / max(wd.reload or 1, 0.1)
		end
	end
	local move = ud.moveDef and ud.moveDef.name or ""
	d.naval = mobile and not d.air and (move:find("boat") ~= nil or (ud.minWaterDepth or 0) > 0)
	d.hover = mobile and move:find("hover") ~= nil
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
	defs[defID] = d
end

return defs
