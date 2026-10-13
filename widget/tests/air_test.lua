local F = dofile("widget/tests/fixtures.lua")

local function air()
	return T.load("sc_air")({ doctrine = F.doctrine })
end

local function aaFrom(list)
	return function(x, z)
		local p = 0
		for _, a in ipairs(list) do
			if (a.x - x) ^ 2 + (a.z - z) ^ 2 <= 900 * 900 then
				p = p + a.cost
			end
		end
		return p
	end
end

return {
	classes = function()
		local A = air()
		T.eq(A.class({ air = true, mobile = true, armed = true, aaOnly = true }), "fighter")
		T.eq(A.class({ air = true, mobile = true, armed = true, kind = "bomber" }), "bomber")
		T.eq(A.class({ air = true, mobile = true, armed = true, kind = "gunship" }), "gunship")
		T.eq(A.class({ air = true, mobile = true, armed = false, kind = "scout plane" }), "scout")
		T.eq(A.class({ air = true, mobile = true, builder = true }), nil, "air constructors aren't wings")
		T.eq(A.class({ air = false, mobile = true, armed = true }), nil)
	end,
	production_mix = function()
		local A = air()
		T.eq(A.want({}, 0), "scout", "eyes first")
		T.eq(A.want({ scout = 1 }, 0), "fighter", "then the sky")
		T.eq(A.want({ scout = 1, fighter = 1 }, 0), "bomber")
		T.eq(A.want({ scout = 1, fighter = 1, bomber = 1 }, 0), "gunship")
		T.eq(A.want({ scout = 1, fighter = 3, bomber = 3, gunship = 3 }, 0), "bomber")
		T.eq(A.want({ scout = 1, fighter = 3, bomber = 3, gunship = 3 }, 0.4), "fighter", "they fly: more fighters")
	end,
	strikes_avoid_and_clear_anti_air = function()
		local A = air()
		local aa = { { x = 5000, z = 5000, cost = 1000 }, { x = 2000, z = 2000, cost = 200 } }
		local cands = {
			{ id = 1, x = 5000, z = 5100, value = 2000, kind = "factory" }, -- 1000 AA: too much for 1500
			{ id = 2, x = 3000, z = 3000, value = 60, kind = "extractor" }, -- no AA
			{ id = 3, x = 2000, z = 2000, value = 200, kind = "anti-air", aa = true }, -- AA we beat 7x
		}
		local t = A.strike(cands, aaFrom(aa), { x = 1000, z = 1000, power = 1500 })
		T.eq(t.id, 3, "the anti-air we can take out first")
		aa[2] = { x = 2000, z = 2000, cost = 600 }
		t = A.strike(cands, aaFrom(aa), { x = 1000, z = 1000, power = 1500 })
		T.eq(t.id, 2, "too strong to clear: around it")
		t = A.strike(cands, aaFrom(aa), { x = 1000, z = 1000, power = 6000 })
		T.eq(t.id, 1, "a big wing goes for the factory")
	end,
	hunting_raids = function()
		local A = air()
		local groups = { { x = 1000, z = 1000, power = 300 }, { x = 2000, z = 1000, power = 900 }, { x = 3000, z = 0, power = 3000 } }
		local g = A.hunt(groups, aaFrom({}), 1500)
		T.eq(g.power, 900, "the biggest party it beats")
		g = A.hunt(groups, aaFrom({ { x = 2000, z = 1000, cost = 600 } }), 1500)
		T.eq(g.power, 300, "not into their anti-air")
		T.eq(A.hunt(groups, aaFrom({}), 100), nil)
	end,
}
