-- Runs the widget modules' unit tests under plain Lua (make test-lua). Each *_test.lua file returns a
-- table of name -> function; a test fails by raising an error (use the helpers below).
-- The modules must stay plain Lua (no engine calls at load) for this to work.
package.path = "widget/LuaUI/Include/?.lua;widget/tests/?.lua;" .. package.path

T = {}
function T.eq(got, want, what)
	if got ~= want then
		error((what or "value") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
	end
end
function T.ok(cond, what)
	if not cond then
		error(what or "condition failed", 2)
	end
end
function T.near(got, want, tol, what)
	if math.abs(got - want) > (tol or 1e-6) then
		error((what or "value") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
	end
end
function T.load(name)
	return dofile("widget/LuaUI/Include/" .. name .. ".lua")
end

local failed, passed = 0, 0
for _, file in ipairs(arg) do
	local tests = dofile(file)
	local names = {}
	for name in pairs(tests) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local ok, err = pcall(tests[name])
		if ok then
			passed = passed + 1
		else
			failed = failed + 1
			print("FAIL " .. file .. ": " .. name .. ": " .. tostring(err))
		end
	end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
