local D = dofile("widget/LuaUI/Include/sc_doctrine.lua")

return {
	tiers_sum_to_one = function()
		for i, t in ipairs(D.production.tiers) do
			local s = 0
			for k, v in pairs(t) do
				if k ~= "income" then
					s = s + v
				end
			end
			T.near(s, 1, 1e-9, "tier " .. i)
			if i > 1 then
				T.ok(t.income > D.production.tiers[i - 1].income, "tiers ascend")
			end
		end
	end,
	builders_and_turret_budget = function()
		T.eq(D.economy.builders(0), 3)
		T.eq(D.economy.builders(47), 7, "strong players have 7 at +47 metal")
		T.eq(D.economy.builders(500), 12, "capped")
		T.eq(D.turrets.budget(6, 1000), 840, "~5 light turrets by minute 6")
		T.eq(D.turrets.budget(12, 6000), 2400, "army share once the army is big")
	end,
	autonomy_levels_complete = function()
		for _, level in ipairs(D.autonomy.levels) do
			T.ok(D.autonomy[level], level)
			T.ok(D.autonomy.labels[level], level .. " label")
		end
	end,
	tunables_point_at_values_within_bounds = function()
		for key, t in pairs(D.tunable) do
			local v = t[1][t[2]]
			T.ok(type(v) == "number", key .. " is a number")
			T.ok(v >= t[3] and v <= t[4], key .. " default within bounds")
			T.ok(type(t[5]) == "string" and #t[5] > 10, key .. " described")
		end
	end,
}
