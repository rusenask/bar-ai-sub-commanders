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

-- team planning (sc_team.lua): the phase and the requests between sub-commanders
D.team = {
	openingMinutes = 6,
	defendBase = 600, -- enemy metal inside the base that makes the whole team defend ...
	defendBaseShare = 0.08, -- ... or this share of our army's metal, whichever is more
	defendRatio = 1.2, -- a known enemy army this much bigger than ours: defend
	pushRatio = 1.6, -- ours this much bigger than everything known of theirs: push
	pushMin = 4000, -- and at least this big
	requestLife = 30 * 45, -- a request nobody refreshes expires
	mergeRadius = 900,
	hold = 30 * 45, -- a plan holds this long unless the base is attacked
	defendTurrets = 1.5, -- the turret budget while the team defends
	defendResponders = 1.5, -- the response squad's share of the army while the team defends
}

-- the commander (sc_commander.lua): modes and personality
D.commander = {
	careful = { retreat = 0.6, dgunMin = 150, homeRange = 1600, frontline = false },
	bold = { retreat = 0.45, dgunMin = 90, homeRange = 3200, frontline = true },
	dgunRange = 250, -- elmos (BAR's D-gun reaches about 250-300)
	dgunEnergy = 600, -- energy needed in storage before firing (it costs ~500)
	dgunCooldown = 30 * 2,
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
		-- from 40 a few mobile anti-air with the army (v21c armies had none: one bomber wing would have
		-- walked over them), and more artillery later for their turret lines (76 turrets killed after 35 min)
		{ income = 40, constructor = 0.15, raider = 0.0, assault = 0.25, skirmisher = 0.2, heavy = 0.3, artillery = 0.05, ["mobile anti-air"] = 0.05 },
		{ income = 60, constructor = 0.12, raider = 0.0, assault = 0.18, skirmisher = 0.2, heavy = 0.3, artillery = 0.1, ["mobile anti-air"] = 0.1 },
	},
	-- the first lab's opening: constructors and raiders in this order before the tier mix takes over
	opening = { "constructor", "constructor", "raider", "raider", "constructor" },
	-- combat units the economy lab sends to an Army sub-commander that has no factory of its own
	feedArmy = true,
	constructorScale = 1, -- multiplies the tiers' constructor shares (tunable: constructor_share)
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
	escorts = 2, -- combat units the economy keeps with the commander before it feeds the Army
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
	-- tier 2: BARbarian techs around minute 25 and wins long games with T2 units; T2 constructors also
	-- upgrade extractors (several times the metal) and build fusion. The T2 lab first makes t2Builders
	-- constructors for the economy, then goes to the Army.
	t2Income = 30, -- metal income at which the T2 lab is built (full autonomy)
	t2Minute = 18, -- or from this minute with t2MinIncome
	t2MinIncome = 20,
	t2Builders = 2,
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

-- spending a big economy (v19: 150-240 metal/s by minute 35, metal at the storage cap, T1 turrets only,
-- 130 idle guards): the defences grow and harden, Defense gets tier 2, the Army gets an air wing
D.escalation = {
	mixFrom = 50, -- the turret mix grows only above this income (below it production comes first: v20
	-- grew it from 30 metal/s, metal never piled up, no second lab, and the commander died alone)
	mixPerIncome = 50, -- each area's heavy and long-range turret shares grow by one per this much income
	mixMax = 4, -- at most this many times the base mix
	t2DefenseIncome = 60, -- Defense asks for a tier 2 constructor (harder turrets) from this income
	t2AirDefenseIncome = 90, -- Air Defense too (flak) from this income
	airRaidIncome = 50, -- the Army gets an aircraft plant of its own (air raids) from this income
	overkill = 8, -- in a push, the main army leaves intruders it outweighs this much to the response squad
	t2VehicleIncome = 80, -- a tier 2 vehicle plant for the Army (heavy tanks, flak, artillery) from here;
	-- v21c's T2 was bots only (railgun skirmishers), no heavy armour
}

-- air raids (Tactics.airRaid): the Army's bombers and gunships as one wing
D.airRaid = {
	min = 800, -- wing metal before it goes out
	need = 3, -- wing power at least this many times the enemy anti-air near a target
	aaRadius = 900, -- anti-air counted around a target
	retreat = 0.5, -- planes below this health go home to repair
	reroute = 30 * 20, -- pick a new target at most this often unless the old one is gone
}

-- the Air Force sub-commander (sc_air.lua): its mix and where its wings go
D.air = {
	bombRadius = 300, -- bombers strike with an area attack this wide around the target (a fight-move drops nothing on unarmed structures)
	scouts = 1, -- scout (or radar) planes kept looking at the enemy's side
	fighters = 0.25, -- share of the armed planes that are fighters (1.5x their air share when they fly)
	maxFighters = 0.6,
	bombers = 0.5, -- of the strike planes (bombers and gunships): bombers
	coverRange = 3500, -- fighters intercept enemy aircraft this close to home or our army
	huntRange = 3500, -- gunships hunt raiding parties this close to home
	huntNeed = 1.5, -- gunships at least this many times a party's power
	strikeMin = 800, -- strike wing metal before it goes out
	need = 3, -- the wing at least this many times the enemy anti-air around a target
	aaRadius = 900, -- anti-air counted around a target
	aaBonus = 3, -- their anti-air the wing can destroy outright is worth this much more (it opens the way)
	retreat = 0.45, -- planes below this health fly home to repair (back out above 0.9)
	reroute = 30 * 20, -- a new strike target at most this often unless the old one is gone
	t2Income = 70, -- from this income the Air Force asks for a tier 2 constructor (a T2 air plant)
}

-- how each kind of unit fights and the army styles that change it (sc_micro.lua). Measured in 143
-- strong players' duels (245k samples, `gamereport -micro testenv/data/pro`, docs/research/pro-micro.md):
-- every ground kind fights from 0.7-0.8 of its range; only long-range units kite (mortars back off 34% of
-- the time from what they outrange against 4% from what outranges them, at ~0.6 of range); heavies lead;
-- artillery stays with its group; structures get shot as often as they're what's near (no siege habit);
-- damaged units aren't pulled out more than healthy ones.
D.micro = {
	outrange = 0.9, -- an enemy with at least this fraction of our range isn't outranged: no kiting from it
	kiteRange = 450, -- only units with at least this range kite (short-range kiters were rare in the data)
	-- focus fire: armed enemies count this much more. mode "settarget": fire control (Engine.fireControl,
	-- every `fireEvery` frames) gives each army unit a priority target with BAR's set-target command, which
	-- leaves its movement alone, and splits fire: a target gets shooters until their damage over killTime
	-- seconds covers its health x overkill (false: everyone on the best). mode "attack": attack orders
	-- while engaging, a target kept `every` frames (a kind with focus = false fights what's nearest)
	focus = { on = true, armed = 3, every = 45, mode = "attack", fireEvery = 15, killTime = 2, overkill = 1.2 },
	kinds = {
		default = { hold = 0.73, kite = false },
		raider = { hold = 0.67, kite = false },
		assault = { hold = 0.73, kite = false, front = true },
		heavy = { hold = 0.75, kite = false, front = true },
		skirmisher = { hold = 0.72, kite = 0.6 },
		artillery = { hold = 0.79, kite = 0.62 },
		["long-range artillery"] = { hold = 0.79, kite = 0.62 },
		["mobile anti-air"] = { hold = 0.62, kite = false },
		gunship = { hold = 0.69, kite = false },
	},
	styles = {
		balanced = { label = "Balanced", desc = "one army that fights where it wins; ranged units keep their range" },
		skirmish = {
			label = "Skirmish",
			desc = "poke at range: skirmishers and artillery kite early, assault units stay at the edge of range",
			kinds = { skirmisher = { kite = 0.8, hold = 0.95 }, artillery = { kite = 0.85 }, assault = { hold = 0.85 } },
		},
		siege = {
			label = "Siege",
			desc = "artillery and skirmishers shell turrets and structures first, heavies screen them",
			kinds = { skirmisher = { siege = true }, artillery = { siege = true, kite = 0.5, behind = 250 }, heavy = { front = true } },
		},
		harass = {
			label = "Harass",
			desc = "rockets, artillery and railguns join the raids and hit outlying economy from range",
			raidKinds = { skirmisher = true, artillery = true },
			raidMax = 2.5, -- raid squads up to this many times doctrine.raid.max
		},
		hold = { label = "Hold", desc = "no pushes or attacks: hold behind our turrets until it's clearly won", noAttack = true },
	},
	order = { "auto", "balanced", "skirmish", "siege", "harass", "hold" },
	auto = {
		siegeStatic = 0.4, -- their known power this much static: siege
		skirmishRanged = 0.35, -- our army this much ranged ...
		skirmishFront = 0.5, -- ... against an army this much heavy/assault: skirmish
		harassRanged = 0.25, -- not pushing and this much ranged: harass
		hold = 30 * 60, -- an auto style holds at least this long
	},
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
	constructor_share = { D.production, "constructorScale", 0.4, 2, "multiplies the share of production that is constructors (lower = more army early)", "economy" },
	responders_share = { D.responders, "share", 0.1, 0.6, "share of the army's power in the base response squad", "army" },
	defend_base_share = { D.team, "defendBaseShare", 0.02, 0.25, "enemy metal in the base, as a share of our army, that makes the team defend", "army" },
}
D.tuneEvery = 30 * 120 -- one change per rule per this many frames
D.tuneStep = 0.5 -- a change moves a rule at most this fraction of its current value (or of its range near 0)

return D
