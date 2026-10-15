local F = dofile("widget/tests/fixtures.lua")

local function firebase()
	return T.load("sc_firebase")({ doctrine = F.doctrine })
end

local home, enemy = { x = 0, z = 0 }, { x = 10000, z = 0 }
local function safe()
	return 0
end

return {
	site_is_past_the_frontier_toward_the_enemy = function()
		local FB = firebase()
		local s = FB.site({ { x = 2000, z = 0, score = 1 } }, home, enemy, {}, safe)
		T.ok(s and s.x > 2000, "pushed forward: " .. tostring(s and s.x))
	end,
	site_steps_back_out_of_their_reach = function()
		local FB = firebase()
		-- their weapons cover everything past 2100: the full step is unsafe, half a step isn't
		local s = FB.site({ { x = 2000, z = 0, score = 1 } }, home, enemy, {}, function(x)
			return x > 2300 and 1 or 0
		end)
		T.ok(s and s.x > 2000 and s.x <= 2300, "half a step: " .. tostring(s and s.x))
		T.eq(FB.site({ { x = 2000, z = 0, score = 1 } }, home, enemy, {}, function()
			return 1
		end), nil, "nothing safe")
	end,
	site_keeps_spacing_and_reach = function()
		local FB = firebase()
		T.eq(FB.site({ { x = 2000, z = 0, score = 1 } }, home, enemy, { { x = 2300, z = 0 } }, safe), nil, "too close to a firebase")
		T.eq(FB.site({ { x = 6000, z = 0, score = 1 } }, home, enemy, {}, safe), nil, "past half the map")
	end,
	site_reach_can_be_shortened = function()
		local FB = firebase()
		T.ok(FB.site({ { x = 4000, z = 0, score = 1 } }, home, enemy, {}, safe), "4000-4450 is inside 0.55 of 10000")
		T.eq(FB.site({ { x = 4000, z = 0, score = 1 } }, home, enemy, {}, safe, nil, 0.3), nil, "not inside 0.3")
	end,
	site_prefers_the_better_picket = function()
		local FB = firebase()
		local s = FB.site({ { x = 2000, z = 2000, score = 1 }, { x = 2000, z = -2000, score = 3 } }, home, enemy, {}, safe)
		T.ok(s.z < 0, "the higher-scored picket")
	end,
	established_once_the_core_stands = function()
		local FB = firebase()
		T.ok(not FB.established({ light = 1, heavy = 1, radar = 1 }, 0, 5, 20), "core not yet")
		T.ok(FB.established({ light = 2, heavy = 1, radar = 1 }, 0, 9, 40), "core stands, long-range still to come")
		T.eq(FB.nextLayer({ light = 2, heavy = 1, radar = 1 }, 0, 9, 40), "heavy", "the rest goes on")
	end,
	site_prefers_free_metal = function()
		local FB = firebase()
		local pickets = { { x = 2000, z = 2000, score = 1 }, { x = 2000, z = -2000, score = 1 } }
		local s = FB.site(pickets, home, enemy, {}, safe, function(_, z)
			return z > 0 and 3 or 0
		end)
		T.ok(s.z > 0, "the side with metal")
	end,
	layers_in_order_with_air_and_late_conditions = function()
		local FB = firebase()
		T.eq(FB.nextLayer({}, 0, 5, 20), "light")
		T.eq(FB.nextLayer({ light = 1 }, 0, 5, 20), "heavy", "v6: the heavy second")
		T.eq(FB.nextLayer({ light = 1, heavy = 1 }, 0, 5, 20), "radar")
		T.eq(FB.nextLayer({ light = 2, radar = 1, heavy = 1 }, 0, 5, 20), "heavy", "no air: no anti-air")
		T.eq(FB.nextLayer({ light = 2, radar = 1, heavy = 1 }, 0.3, 5, 20), "aa")
		T.eq(FB.nextLayer({ light = 2, radar = 1, heavy = 2 }, 0, 5, 20), nil, "complete before minute 8")
		T.eq(FB.nextLayer({ light = 2, radar = 1, heavy = 2 }, 0, 9, 40), "long")
	end,
}
