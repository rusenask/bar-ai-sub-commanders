-- Sub-Commanders micro (design/engine.md): how each kind of unit fights, and army styles that change it.
-- Per kind (doctrine.micro.kinds):
--   hold   fraction of its own weapon range it fights from
--   kite   backs off when an enemy it outranges gets within this fraction of its range (false: never)
--   front  leads the army (heavies, assault)
--   siege  shoots enemy structures in range first (turrets, then their economy)
--   behind how far behind the army's rally point it waits (artillery)
-- Army styles (doctrine.micro.styles) change those rules and what raids are made of; the strategist picks
-- one (set_army_style) or `auto` picks from the team plan and what both sides field.
--
-- usage: local Micro = VFS.Include("LuaUI/Include/sc_micro.lua", nil, VFS.RAW_FIRST)
--        local micro = Micro({ doctrine = D })
--        local rule = micro.rule("skirmisher", "skirmish")
--        micro.kite(rule, ownRange, enemyDistance, enemyRange) -- nil or the distance to back off to
--        micro.auto({ phase, enemyStatic, enemyFront, ourRanged })
-- Pure Lua: unit-tested in widget/tests/micro_test.lua.

return function(ctx)
	local D = ctx.doctrine
	local M = {}

	function M.style(name)
		return D.micro.styles[name or "balanced"] or D.micro.styles.balanced
	end

	-- the rule for a kind of unit under a style: the kind's doctrine with the style's changes
	function M.rule(kind, styleName)
		kind = (kind or ""):gsub("^hover ", "")
		local base = D.micro.kinds[kind] or D.micro.kinds.default
		local over = (M.style(styleName).kinds or {})[kind]
		local r = {}
		for k, v in pairs(base) do
			r[k] = v
		end
		for k, v in pairs(over or {}) do
			r[k] = v
		end
		return r
	end

	-- kiting: nil to keep fighting, or the distance from the enemy to back off to. Only from enemies we
	-- outrange (against longer guns, closing in is the answer).
	function M.kite(rule, ownRange, dist, enemyRange)
		if not rule.kite or ownRange < (D.micro.kiteRange or 0) then
			return nil
		end
		if enemyRange and enemyRange >= ownRange * D.micro.outrange then
			return nil
		end
		if dist < ownRange * rule.kite then
			return ownRange * rule.hold
		end
		return nil
	end

	-- may a unit of this kind join raids under the style?
	function M.raids(category, styleName)
		local kinds = M.style(styleName).raidKinds
		return category == "raider" or (kinds and kinds[category]) or false
	end

	-- the style when the setting is auto. s = { phase (team plan), enemyStatic (share of the known enemy
	-- power that's static defence), enemyFront (share of their army that's heavy or assault), ourRanged
	-- (share of our army's metal in skirmishers and artillery) }
	function M.auto(s)
		local A = D.micro.auto
		if s.phase == "defend" then
			return "hold", "the team defends"
		end
		if s.enemyStatic >= A.siegeStatic then
			return "siege", "their strength is in turrets"
		end
		if s.ourRanged >= A.skirmishRanged and s.enemyFront >= A.skirmishFront then
			return "skirmish", "our range against their front-line units"
		end
		if s.phase ~= "push" and s.ourRanged >= A.harassRanged then
			return "harass", "not decisive yet: ranged units hit their outlying economy"
		end
		return "balanced", "one army, fights where it wins"
	end

	return M
end
