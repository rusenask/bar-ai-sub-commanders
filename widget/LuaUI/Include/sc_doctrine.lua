-- Sub-Commanders doctrine: the executor's tuning as data (design/engine.md).
-- Values come from BARbarian's hard profile (ref/bar/luarules/configs/BARb/stable/config/hard) and from
-- strong players' replays (docs/research/pro-playbook.md), adapted to metal-value power. Change numbers
-- here, not in the code; measure every change with an A/B batch (.claude/skills/ab-test).
-- usage: local doctrine = VFS.Include("LuaUI/Include/sc_doctrine.lua", nil, VFS.RAW_FIRST)

local D = {}

-- health fraction below which a unit leaves the fight (BARb hard: builder 0.85, fighter 0.5)
D.retreat = {
	builder = 0.85, -- constructors under fire
	fighter = 0.5,
	commander = 0.6,
	minCost = 60, -- cheaper units fight on
	back = 0.9, -- health at which a retreated unit returns
	maxFrames = 30 * 45, -- give up waiting for repairs after this
}

-- squad decisions, as ratios of our local power to the enemy's local threat (metal value; our turrets
-- count on our side, theirs on theirs)
D.engage = {
	attack = 1.2, -- start a fight away from home only this much stronger
	hold = 0.8, -- keep fighting while at least this strong
	defend = 0.5, -- inside our base, with turret support, fight down to this
	radius = 700, -- "local": around the target / the squad
	cohesion = 650, -- units farther than this from the squad centre regroup first
	minAttack = 1200, -- metal value of the smallest squad that attacks on its own (BARb quota.attack)
	chase = 2600, -- an army chases intruders it drove off this far from home (if it still beats them)
	raid = { 250, 900 }, -- [min, max] metal value of a raid squad (BARb quota.raid)
}

-- raids (Army sub-commanders with Raids on): its fast units scout the enemy's side and hit what they beat
D.raid = {
	min = 250, -- metal value of raiders needed before they go out (BARb quota.raid min)
	max = 900, -- the rest of the raiders stay with the main army
	need = 1.5, -- local power over threat needed to hit a target
	share = 0.2, -- of the army's units, raiders while Raids is on
	prefer = { constructor = 3, extractor = 2, generator = 1.5, radar = 1.5, structure = 1, factory = 0.5 },
	revisit = 30 * 180, -- scouting: a metal spot is worth a look again after this long
	reroute = 30 * 10, -- recompute the route this often
}

-- the Army's response squad: its fastest units wait at the centre of the base and intercept raids anywhere
-- in it, so the main army holds the front instead of being dragged around by raiders (strong players keep
-- such a force; raids from every side pulled our single squad back and forth)
D.responders = {
	share = 0.3, -- of the army's power, at most
	min = 300, -- metal value before a response squad forms (below that the main army answers)
	speed = 70, -- fast units only
}

-- threat map
D.threat = {
	cell = 256, -- elmos per cell
	every = 10, -- frames between rebuilds (3 a second, like CircuitAI)
	margin = 120, -- added to weapon range
	mobileMemory = 30 * 90, -- a mobile enemy's threat fades over this long after it was last seen
	staticMemory = 30 * 60 * 10, -- static defences are remembered much longer
	fresh = 30 * 8, -- seen this recently: full weight
	minRange = 200, -- treat short-ranged and unknown weapons as at least this
	blip = { cost = 120, range = 350 }, -- what an unidentified radar contact is assumed to be
	-- a big army that walks out of sight isn't gone: units seen in a group worth hordePower+ are remembered
	-- for hordeMemory, never fading below hordeFloor of their value (a watched game forgot a huge horde
	-- 90 s after it left view and walked into it)
	hordePower = 1500,
	hordeMemory = 30 * 300,
	hordeFloor = 0.4,
}

-- production by income tier: shares of what a factory makes (BARb hard factory.json tiers, adapted to
-- unit kinds). `income` is the lower bound of the tier's metal income.
D.production = {
	tiers = {
		{ income = 0, constructor = 0.25, raider = 0.45, assault = 0.30 },
		-- past the opening raiders are a small share: cheap ones feed the enemy kills (engine-v1 vs hard:
		-- 500 Goblins lost after minute 12); BARb hard's Legion mix drops them after its first tiers
		{ income = 12, constructor = 0.2, raider = 0.15, assault = 0.5, skirmisher = 0.15 },
		{ income = 25, constructor = 0.15, raider = 0.05, assault = 0.4, skirmisher = 0.2, heavy = 0.2 },
		{ income = 40, constructor = 0.15, raider = 0.0, assault = 0.3, skirmisher = 0.2, heavy = 0.3, artillery = 0.05 },
	},
	-- the first lab's opening: constructors and raiders in this order before the tier mix takes over
	opening = { "constructor", "constructor", "raider", "raider", "constructor" },
	-- combat units the economy lab sends to an Army sub-commander that has no factory of its own
	feedArmy = true,
}

-- counter-response (BARb hard response.json): our kind -> enemy kinds it answers, with weights, and the
-- most of our army it may make up
D.response = {
	raider = { vs = { scout = 2.0, raider = 0.5, artillery = 1.2 }, max = 0.3 },
	assault = { vs = { raider = 0.9, skirmisher = 0.4, turret = 0.3 }, max = 0.8 },
	skirmisher = { vs = { assault = 0.8, heavy = 0.5, skirmisher = 0.7, artillery = 0.6 }, max = 0.8 },
	heavy = { vs = { assault = 0.5, skirmisher = 0.7, heavy = 1.5, turret = 0.3 }, max = 0.6 },
	artillery = { vs = { turret = 1.0, ["long-range artillery"] = 0.5 }, max = 0.2 },
	["mobile anti-air"] = { vs = { gunship = 1.0, bomber = 1.0, fighter = 0.5 }, max = 0.25 },
}
D.responseWeight = 0.6 -- how much the counter matrix moves the tier mix (0 = tier mix only)

-- factories, constructors, economy
D.economy = {
	secondFactoryIncome = 25, -- strong players run one lab until about minute 8-10
	factoryPerIncome = 22, -- then about one more lab per this much metal income
	maxFactories = 5, -- tunable by the strategist (e.g. 1 to stop new labs)
	builders = function(income) -- constructor target (BARb buildpower 1.2; strong players 5-8)
		return math.min(12, math.floor(3 + income / 10))
	end,
	energyPerMetal = 12, -- energy income to aim for per metal income (strong players 10-16)
	-- construction turrets before more labs: 200 build power for 230 metal against a lab's 150 for 470;
	-- a lab is saturated at 4-7 turrets (unit exit time), only then does another lab pay off
	nanoFrom = 10, -- metal income the first lab uses on its own
	nanoRate = 1.7, -- construction turrets per 10 metal/s of income above nanoFrom (1.25 left metal piling up)
	nanosPerLab = 5, -- a lab with this many turrets around it is saturated
	builderBonus = 0, -- added to the constructor target (tunable by the strategist)
	maxStorage = 4000, -- metal storage beyond this hides waste instead of fixing it: spend instead
	airPlantIncome = 35, -- full autonomy: past this income (and a saturated lab) the next factory is aircraft
	radarFrom = 30 * 90, -- the economy puts up a radar toward the enemy from about minute 1.5
}

-- turrets: a budget instead of filling zones (strong players: ~5 turrets by minute 6, ~1.7k metal at 12)
D.turrets = {
	budget = function(minute, armyValue)
		return math.max(300 + 90 * minute, 0.4 * armyValue)
	end,
	extractorCoverFrom = 30 * 150, -- first turret at exposed extractors from about minute 2.5
	extractorCoverRadius = 450,
	scale = 1, -- multiplies the budget (tunable by the strategist)
	-- per area (each defense zone), a mix of turret roles instead of one count for everything:
	-- light (cheap, fast-firing: raiders), heavy (damage: assault and heavy units), long (range >= 700:
	-- outranges their units and artillery). Counts are multiplied by the posture's density.
	mix = { light = 3, heavy = 2, long = 1 },
	longFrom = 30 * 60 * 8, -- long-range turrets from about minute 8
	longRange = 700,
	lightCost = 150,
}

-- autonomy levels: what a sub-commander does on its own
D.autonomy = {
	levels = { "light", "balanced", "full" },
	labels = { light = "Light", balanced = "Balanced", full = "Full" },
	light = { expand = false, factories = false, help = false, push = false, attack = false, proactiveTurrets = false, extractorCover = false },
	balanced = { expand = true, factories = "overflow", help = true, push = true, attack = false, proactiveTurrets = false, extractorCover = true },
	full = { expand = true, factories = true, help = true, push = true, attack = true, proactiveTurrets = true, extractorCover = true },
}

-- what the AI strategist may tune (tool tune_rules): key -> table and field, bounds, what it does, and the
-- role that owns it (only that role's sub-commanders may change it: they used to undo each other).
-- Team-wide: the doctrine is shared by every sub-commander. Changes are rate-limited (Engine.tune).
D.tunable = {
	max_factories = { D.economy, "maxFactories", 1, 5, "most factories the economy builds on its own (lower stops new labs)", "economy" },
	nanos_per_lab = { D.economy, "nanosPerLab", 0, 10, "construction turrets around a lab before another lab pays off", "economy" },
	construction_turret_rate = { D.economy, "nanoRate", 0.5, 4, "construction turrets per 10 metal/s of income (higher = more turrets, more build power)", "economy" },
	second_factory_income = { D.economy, "secondFactoryIncome", 10, 100, "metal income before a second lab (full autonomy)", "economy" },
	builder_bonus = { D.economy, "builderBonus", -3, 6, "mobile constructors above (or below) the income-based target", "economy" },
	turret_budget_scale = { D.turrets, "scale", 0.25, 3, "multiplies the turret budget (higher = more turrets)", "defense" },
	retreat_builder = { D.retreat, "builder", 0.3, 1, "health at which a constructor under fire leaves (lower = they stay longer)", "defense" },
	raid_share = { D.raid, "share", 0, 0.6, "share of an army's units that are raiders while Raids is on", "army" },
	raid_need = { D.raid, "need", 1, 4, "how much stronger a raid must be than what guards a target", "army" },
	engage_attack = { D.engage, "attack", 0.8, 2.5, "strength ratio an army needs to start a fight away from home (higher = fewer fights)", "army" },
	engage_hold = { D.engage, "hold", 0.4, 1.5, "strength ratio below which an army breaks off a fight (higher = retreats sooner)", "army" },
	engage_defend = { D.engage, "defend", 0.3, 1.2, "strength ratio an army defends the base down to (higher = gives up the base sooner)", "army" },
	chase_distance = { D.engage, "chase", 0, 5000, "how far from home an army chases intruders it drove off", "army" },
	retreat_fighter = { D.retreat, "fighter", 0.2, 0.7, "health at which a fighting unit leaves the fight (higher = fewer losses, fewer kills)", "army" },
	response_weight = { D, "responseWeight", 0, 1, "how much production follows counters to what the enemy fields", "army" },
}
D.tuneEvery = 30 * 120 -- one change per rule per this many frames
D.tuneStep = 0.5 -- a change moves a rule at most this fraction of its current value (or of its range near 0)

return D
