-- Unit catalogue dump (test-only): every unit definition's abilities, economy, intel, what it builds and
-- every weapon's properties, one JSON object per line in defsdump.jsonl (root, else LuaUI/Config) when
-- defsdump.txt exists in the write dir; then quits. The game's own data behind docs/research/units.md and
-- the ability flags of sc_unitkinds.lua (testenv/unit-catalogue.sh).
function widget:GetInfo()
	return { name = "ZZ Unit Catalogue Dump", layer = 102, enabled = true }
end

local function loadInput(name)
	return VFS.LoadFile("LuaUI/Config/" .. name, VFS.RAW) or VFS.LoadFile(name, VFS.RAW)
end

-- a field that may be missing or error on some engine versions
local function get(t, k)
	local ok, v = pcall(function()
		return t[k]
	end)
	if ok then
		return v
	end
	return nil
end

local function num(v)
	return type(v) == "number" and v or nil
end

local function weaponInfo(wd)
	local damages = get(wd, "damages") or {}
	local shield = get(wd, "shield") or {}
	return {
		name = get(wd, "name"),
		type = get(wd, "type"),
		range = num(get(wd, "range")),
		reload = num(get(wd, "reload")),
		damage = num(get(damages, 0)) or num(get(damages, "default")),
		aoe = num(get(wd, "damageAreaOfEffect")),
		salvo = num(get(wd, "salvoSize")),
		projectiles = num(get(wd, "projectiles")),
		paralyzer = get(wd, "paralyzer") or false,
		paralyzeTime = num(get(damages, "paralyzeDamageTime")),
		interceptor = num(get(wd, "interceptor")),
		targetable = num(get(wd, "targetable")),
		stockpile = get(wd, "stockpile") or false,
		stockpileTime = num(get(wd, "stockpileTime")),
		manualFire = get(wd, "manualFire") or false,
		shieldPower = num(get(shield, "power")) or num(get(wd, "shieldPower")),
		shieldRadius = num(get(shield, "radius")) or num(get(wd, "shieldRadius")),
		tracks = get(wd, "tracks") or false,
		waterWeapon = get(wd, "waterWeapon") or false,
		submissile = get(wd, "submissile") or false,
		canAttackGround = get(wd, "canAttackGround"),
		beamTime = num(get(wd, "beamtime")),
		impulse = num(get(wd, "impulseFactor")),
		coverage = num(get(wd, "coverageRange")),
		energyPerShot = num(get(wd, "energyCost")),
		metalPerShot = num(get(wd, "metalCost")),
		customParams = get(wd, "customParams"),
	}
end

function widget:GameFrame(n)
	if n ~= 5 or not loadInput("defsdump.txt") then
		return
	end
	local kinds = VFS.Include("LuaUI/Include/sc_unitkinds.lua", nil, VFS.RAW_FIRST)
	local out = io.open("defsdump.jsonl", "w") or io.open("LuaUI/Config/defsdump.jsonl", "w")
	for id, ud in pairs(UnitDefs) do
		local k = kinds[id] or {}
		local builds = {}
		for _, b in ipairs(get(ud, "buildOptions") or {}) do
			builds[#builds + 1] = UnitDefs[b] and UnitDefs[b].name
		end
		local weapons = {}
		for _, w in ipairs(get(ud, "weapons") or {}) do
			local wd = WeaponDefs[w.weaponDef]
			if wd then
				weapons[#weapons + 1] = weaponInfo(wd)
			end
		end
		local u = {
			name = ud.name,
			human = get(ud, "translatedHumanName") or get(ud, "humanName"),
			tooltip = get(ud, "translatedTooltip") or get(ud, "tooltip"),
			kind = k.kind,
			cost = num(get(ud, "metalCost")),
			energyCost = num(get(ud, "energyCost")),
			buildTime = num(get(ud, "buildTime")),
			health = num(get(ud, "health")),
			speed = num(get(ud, "speed")),
			mobile = k.mobile or false,
			air = get(ud, "canFly") or false,
			hover = k.hover or false,
			naval = k.naval or false,
			minWaterDepth = num(get(ud, "minWaterDepth")),
			maxWaterDepth = num(get(ud, "maxWaterDepth")),
			canSubmerge = get(ud, "canSubmerge") or false,
			builder = get(ud, "isBuilder") or false,
			buildSpeed = num(get(ud, "buildSpeed")),
			buildDistance = num(get(ud, "buildDistance")),
			builds = builds,
			factory = get(ud, "isFactory") or false,
			canCloak = get(ud, "canCloak") or false,
			cloakCost = num(get(ud, "cloakCost")),
			cloakCostMoving = num(get(ud, "cloakCostMoving")),
			decloakDistance = num(get(ud, "decloakDistance")),
			stealth = get(ud, "stealth") or false,
			sonarStealth = get(ud, "sonarStealth") or false,
			sight = num(get(ud, "sightDistance")) or num(get(ud, "losRadius")),
			airSight = num(get(ud, "airSightDistance")),
			radar = num(get(ud, "radarDistance")),
			sonar = num(get(ud, "sonarDistance")),
			jammer = num(get(ud, "radarDistanceJam")),
			seismic = num(get(ud, "seismicDistance")),
			canResurrect = get(ud, "canResurrect") or false,
			canCapture = get(ud, "canCapture") or false,
			canReclaim = get(ud, "canReclaim") or false,
			canRepair = get(ud, "canRepair") or false,
			canAssist = get(ud, "canAssist") or false,
			canRestore = get(ud, "canRestore") or false,
			transportCapacity = num(get(ud, "transportCapacity")),
			transportMass = num(get(ud, "transportMass")),
			canKamikaze = get(ud, "canKamikaze") or false,
			kamikazeDistance = num(get(ud, "kamikazeDistance")),
			selfDestructAs = get(ud, "selfDExplosion"),
			explodeAs = get(ud, "deathExplosion"),
			canManualFire = get(ud, "canManualFire") or false,
			canStockpile = get(ud, "canStockpile") or false,
			onOffable = get(ud, "onOffable") or false,
			energyMake = num(get(ud, "energyMake")),
			energyUpkeep = num(get(ud, "energyUpkeep")),
			windGenerator = num(get(ud, "windGenerator")),
			tidalGenerator = num(get(ud, "tidalGenerator")),
			extractsMetal = num(get(ud, "extractsMetal")),
			metalMake = num(get(ud, "metalMake")),
			metalStorage = num(get(ud, "metalStorage")),
			energyStorage = num(get(ud, "energyStorage")),
			isFirePlatform = get(ud, "isFirePlatform") or false,
			customParams = get(ud, "customParams"),
			weapons = weapons,
		}
		out:write(Json.encode(u) .. "\n")
	end
	out:close()
	Spring.SendCommands("quitforce")
end
