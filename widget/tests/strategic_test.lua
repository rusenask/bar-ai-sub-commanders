local F = dofile("widget/tests/fixtures.lua")

local function strategic()
	return T.load("sc_strategic")({ doctrine = F.doctrine })
end

return {
	lrpc_site_reaches_from_safety = function()
		local S = strategic()
		-- home at 0, their base 8000 away; a cannon of range 4650 reaches from 8000 - 0.9 x 4650 = 3815 on;
		-- known threat from 4500 on
		local x = S.lrpcSite({ x = 0, z = 0 }, { x = 8000, z = 0 }, 4650, function(px)
			return px >= 4500 and 1 or 0
		end)
		T.ok(x and x >= 3815 and x < 4500, "the first safe point in reach: " .. tostring(x))
		T.eq(S.lrpcSite({ x = 0, z = 0 }, { x = 8000, z = 0 }, 4650, function(px)
			return px >= 3000 and 1 or 0
		end), nil, "nowhere safe reaches")
	end,
	lrpc_shoots_their_cannon_first_not_under_shields = function()
		local S = strategic()
		local gun = { x = 0, z = 0, range = 5000 }
		local targets = {
			{ id = 1, x = 4000, z = 0, cost = 500, role = "factory" },
			{ id = 2, x = 4500, z = 0, cost = 4500, role = "lrpc" },
			{ id = 3, x = 3000, z = 0, cost = 3500, role = "energy" },
			{ id = 4, x = 9000, z = 0, cost = 9000, role = "lrpc" }, -- out of range
		}
		T.eq(S.lrpcTarget(gun, targets, {}).id, 2, "their cannon")
		T.eq(S.lrpcTarget(gun, targets, { { x = 4500, z = 0, r = 550 } }).id, 3, "the cannon is under a shield")
		T.eq(S.lrpcTarget(gun, { { id = 5, x = 3000, z = 0, cost = 96, role = "turret" } }, {}), nil, "a Sentry: fire at will")
	end,
	juno_clears_the_biggest_cluster = function()
		local S = strategic()
		local cands = { { x = 0, z = 0, cost = 100 }, { x = 300, z = 0, cost = 100 }, { x = 5000, z = 0, cost = 500 } }
		local x, _, n = S.junoTarget(cands, 700, 2)
		T.eq(n, 2)
		T.ok(x == 0 or x == 300)
		T.eq(S.junoTarget({ { x = 0, z = 0, cost = 100 } }, 700, 2), nil, "one radar isn't worth a missile")
		T.ok(S.junoTarget({ { x = 0, z = 0, cost = 100, weight = 2 } }, 700, 2), "one jammer is")
	end,
	nuke_hits_the_richest_uncovered_cluster = function()
		local S = strategic()
		local cands = {
			{ x = 0, z = 0, cost = 3000 }, { x = 200, z = 0, cost = 3000 }, -- 6000 under an anti-nuke
			{ x = 8000, z = 0, cost = 2500 }, { x = 8300, z = 0, cost = 2500 }, -- 5000, open
			{ x = 15000, z = 0, cost = 900 }, -- not worth a missile
		}
		local x, _, v = S.nukeTarget(cands, 640, { { x = 100, z = 0, r = 2000 } }, 3000)
		T.ok(x == 8000 or x == 8300, "the open cluster")
		T.eq(v, 5000)
		T.eq(S.nukeTarget({ { x = 15000, z = 0, cost = 900 } }, 640, {}, 3000), nil, "nothing worth it")
	end,
	rez_takes_the_most_metal_for_the_walk = function()
		local S = strategic()
		local w = S.rezTarget({ x = 0, z = 0 }, { { id = 1, x = 100, z = 0, value = 100 }, { id = 2, x = 2000, z = 0, value = 1500 } })
		T.eq(w.id, 2)
	end,
}
