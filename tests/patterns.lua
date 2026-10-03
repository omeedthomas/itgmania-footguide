-- Synthetic pattern tests: known patterns with an expected footing.
local Solver = assert(load(READ(ROOT .. "Modules/FootGuide/Solver.lua"), "@Solver.lua"))()

local DIR = { L = 1, D = 2, U = 3, R = 4 }

-- Build rows from a compact pattern: tokens separated by spaces.
--   "L"    tap Left          "LR"  jump
--   "L*4"  hold Left for 4 rows
-- spacing: seconds between rows
local function Rows(pattern, spacing)
	local notes, i = {}, 0
	for token in pattern:gmatch("%S+") do
		local arrows, len = token:match("^(%a+)%*?(%d*)$")
		for a in arrows:gmatch(".") do
			local note = { col = DIR[a], beat = i, time = i * spacing, kind = "tap" }
			if len ~= "" then
				note.kind = "hold"
				note.endTime = (i + tonumber(len)) * spacing
			end
			notes[#notes+1] = note
		end
		i = i + 1
	end
	return Solver.BuildRows(notes)
end

local function Feet(result)
	local out = {}
	for _, row in ipairs(result.rows) do
		local s = ""
		for _, note in ipairs(row.notes) do s = s .. (note.foot or "?") end
		out[#out+1] = s
	end
	return table.concat(out, " ")
end

local function Techs(result)
	local out = {}
	for _, row in ipairs(result.rows) do
		local t = {}
		for k in pairs(row.tech) do t[#t+1] = k end
		table.sort(t)
		out[#out+1] = #t > 0 and table.concat(t, "+") or "-"
	end
	return table.concat(out, " ")
end

-- Feet strings are compared modulo starting foot when `mirror` is set
-- (a stream can legitimately start with either foot).
local function Swap(s) return (s:gsub("[LR]", { L = "R", R = "L" })) end

local pass, fail = 0, 0
-- expected: a feet string, a list of acceptable strings, or nil (don't check feet)
local function Check(name, pattern, spacing, expected, opts)
	opts = opts or {}
	local result = Solver.Solve(Rows(pattern, spacing), "dance-single")
	local got = Feet(result)
	local ok = expected == nil
	if type(expected) == "string" then expected = { expected } end
	for _, e in ipairs(expected or {}) do
		if got == e or (opts.either and got == Swap(e)) then ok = true end
	end
	if opts.tech then ok = ok and Techs(result):find(opts.tech, 1, true) ~= nil end
	if opts.notech then ok = ok and Techs(result):find(opts.notech, 1, true) == nil end
	if ok then pass = pass + 1 else fail = fail + 1 end
	print(string.format("%s %-30s %-24s %s", ok and "PASS" or "FAIL", name, got, Techs(result)))
	if not ok then
		print("     expected: " .. table.concat(expected or {"(any)"}, " | ")
			.. (opts.tech and ("  tech~" .. opts.tech) or ""))
	end
end

local S16 = 0.1   -- 16ths at 150 bpm
local S8  = 0.2

Check("simple alternation", "L D U R L D U R", S16, "L R L R L R L R", { notech = "crossover" })
Check("LURD turns = crossovers", "L U R D L U R D", S16, { "L R L R L R L R", "R L R L R L R L" }, { tech = "crossover" })
Check("crossover over doublestep", "L D R U L", S8, "L R L R L", { tech = "crossover", notech = "doublestep" })
Check("fast jacks use one foot", "L R R R R L", S16, "L R R R R L", { tech = "jack" })
Check("footswitch LDDR", "L D D R L D D R L", S16, "L R L R L R L R L", { tech = "footswitch" })
Check("minijack in stream", "L D L R D D R L", S16, { "L R L R L L R L" }, { either = true, notech = "doublestep" })
Check("jump then alternate", "LR D U D U", S8, { "LR R L R L", "LR L R L R" }, { notech = "doublestep" })
Check("hold frees other foot", "L*6 D U D U D R", S8, "L R R R R R R", { notech = "doublestep" })
Check("hand needs bracket", "L D R U LDR U", S8, nil, { tech = "bracket", notech = "doublestep" })
Check("quad = two brackets", "LDUR L R", S8, { "LLRR L R", "LRLR L R" }, { tech = "bracket" })
Check("no spin on L R trills", "L R L R L R", S16, "L R L R L R", { notech = "spin" })
Check("drill U D", "U D U D U D", S16, { "L R L R L R", "R L R L R L" }, { notech = "doublestep" })

print(string.format("%d passed, %d failed", pass, fail))
