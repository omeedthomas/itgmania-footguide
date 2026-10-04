-- FootGuide Solver
--
-- Pure Lua 5.1 (no StepMania dependencies) so it can be tested outside the game.
--
-- Given the notes of a chart, finds the foot assignment (which foot hits which
-- arrow) with the lowest total "awkwardness" cost, using dynamic programming
-- over foot positions -- the same idea used by ITGmania's internal StepParity
-- generator and by chart editors that simulate foot placement.
--
-- State per row:  where the left foot is, where the right foot is, and which
-- foot(s) stepped on the previous row (needed to detect doublesteps).
-- A foot "placement" is one of:
--   single  - standing on one panel
--   bracket - heel and toe covering two adjacent panels
--   float   - was pushed off a panel by the other foot (footswitch); it keeps
--             the coordinates of where it was but covers no panel

local Solver = {}

-- Panel centre coordinates, x to the right and y upward.
Solver.Layouts = {
	["dance-single"] = {
		cols  = { {0,1}, {1,0}, {1,2}, {2,1} },
		dirs  = { "Left", "Down", "Up", "Right" },
		start = { 1, 4 },
	},
	["dance-double"] = {
		cols  = { {0,1}, {1,0}, {1,2}, {2,1}, {3,1}, {4,0}, {4,2}, {5,1} },
		dirs  = { "Left", "Down", "Up", "Right", "Left", "Down", "Up", "Right" },
		start = { 4, 5 },
	},
}

-- Cost weights. Only their relative size matters. Tuned so the tech counts
-- line up with ITGmania's own StepParity counts across a few hundred charts
-- (see test/compare.lua).
Solver.Weights = {
	DOUBLESTEP      = 1000, -- same foot twice in a row on different panels
	SPIN            = 600,  -- fully backwards (left foot right of right foot by 2+ panels)
	CROSSOVER       = 40,   -- per panel of crossing, per row spent crossed
	FOOTSWITCH      = 100,  -- foot steps onto the other foot's panel, in fast stream
	SLOW_FOOTSWITCH = 400,  -- ... when there was time to just jack or move instead
	BRACKET         = 30,   -- one foot covering two panels
	HOLD_TAP        = 400,  -- tapping with the toe/heel of a foot that is holding
	FAST_JACK       = 70,   -- same foot same panel, consecutive, quick
	JACK            = 20,   -- same foot same panel, consecutive
	STACKED         = 15,   -- feet vertically aligned (one on Up, one on Down)
	DISTANCE        = 10,   -- per panel of foot travel
	SPREAD          = 150,  -- per panel of leg spread beyond comfortable (doubles)
}

-- Seconds between rows below which a step counts as "fast" (jacks, footswitches).
Solver.FastThreshold = 0.2

Solver.BeamWidth = 48
Solver.YieldEvery = 120

local W = Solver.Weights
local EPS = 1e-6

-- ---------------------------------------------------------------------------
-- Chart text parsing

local function lc(s) return (s or ""):lower() end

local function NoteDataFromSSC(text, stepsType, difficulty, description, normalizeDifficulty)
	stepsType, difficulty = lc(stepsType), lc(difficulty)
	-- Split on #NOTEDATA: so each chunk is one chart.
	local pos = 1
	local lower = text:lower()
	local starts = {}
	while true do
		local s = lower:find("#notedata:", pos, true)
		if not s then break end
		starts[#starts+1] = s
		pos = s + 1
	end
	for i, s in ipairs(starts) do
		local chunk = text:sub(s, (starts[i+1] or (#text + 1)) - 1)
		local function field(name)
			local v = chunk:match("#" .. name .. ":([^;]*);")
				or chunk:match("#" .. name:upper() .. ":([^;]*);")
			return v and v:gsub("^%s+", ""):gsub("%s+$", "") or ""
		end
		local st = lc(field("stepstype")):gsub("%s+", "")
		local diff = field("difficulty"):gsub("%s+", "")
		diff = lc(normalizeDifficulty and normalizeDifficulty(diff) or diff)
		if st == stepsType and diff == difficulty
		and (difficulty ~= "edit" or field("description") == description) then
			return chunk:match("#[Nn][Oo][Tt][Ee][Ss]2?:([^;]*)")
		end
	end
end

local function NoteDataFromSM(text, stepsType, difficulty, description, normalizeDifficulty)
	stepsType, difficulty = lc(stepsType), lc(difficulty)
	for block in text:gmatch("#[Nn][Oo][Tt][Ee][Ss]2?:([^;]*)") do
		local parts = {}
		for part in (block .. ":"):gmatch("([^:]*):") do parts[#parts+1] = part end
		if #parts >= 6 then
			local st = lc(parts[1]):gsub("[^%w-]", "")
			local diff = parts[3]:gsub("[^%w]", "")
			diff = lc(normalizeDifficulty and normalizeDifficulty(diff) or diff)
			local desc = parts[2]:gsub("^%s+", ""):gsub("%s+$", "")
			if st == stepsType and diff == difficulty
			and (difficulty ~= "edit" or desc == description) then
				return parts[6]
			end
		end
	end
end

-- Returns the raw note-data string for one chart, or nil.
function Solver.ExtractNoteData(text, filetype, stepsType, difficulty, description, normalizeDifficulty)
	if not text then return nil end
	text = text:gsub("\r\n?", "\n")
	if lc(filetype) == "ssc" then
		return NoteDataFromSSC(text, stepsType, difficulty, description, normalizeDifficulty)
	end
	return NoteDataFromSM(text, stepsType, difficulty, description, normalizeDifficulty)
end

-- Parses note data into a list of notes:
--   { col=, beat=, kind="tap"|"hold"|"roll", endBeat= (holds/rolls only) }
-- Mines, fakes and keysounds are dropped; lifts are treated as taps.
function Solver.ParseNotes(noteData, numCols)
	noteData = noteData:gsub("//[^\n]*", "")
	-- Couples/routine charts: only the first player's part.
	noteData = noteData:match("^([^&]*)")
	-- SSC per-note attributes like 1{...} or 1[...]
	noteData = noteData:gsub("%b{}", ""):gsub("%b[]", "")

	local notes, openHolds = {}, {}
	local measureIndex = 0
	for measure in (noteData .. ","):gmatch("([^,]*),") do
		local lines = {}
		for line in measure:gmatch("[^%s]+") do
			if #line == numCols then lines[#lines+1] = line end
		end
		local n = #lines
		for i = 1, n do
			local beat = measureIndex * 4 + 4 * (i - 1) / n
			local line = lines[i]
			for c = 1, numCols do
				local ch = line:sub(c, c)
				if ch == "1" or ch == "L" then
					notes[#notes+1] = { col = c, beat = beat, kind = "tap" }
				elseif ch == "2" or ch == "4" then
					local note = { col = c, beat = beat, kind = (ch == "2") and "hold" or "roll" }
					notes[#notes+1] = note
					openHolds[c] = note
				elseif ch == "3" then
					if openHolds[c] then
						openHolds[c].endBeat = beat
						openHolds[c] = nil
					end
				end
			end
		end
		measureIndex = measureIndex + 1
	end
	-- Unterminated holds become taps.
	for _, note in pairs(openHolds) do note.kind = "tap" end
	table.sort(notes, function(a, b)
		if a.beat ~= b.beat then return a.beat < b.beat end
		return a.col < b.col
	end)
	return notes
end

-- Groups notes (which must already have .time and, for holds, .endTime) into rows.
function Solver.BuildRows(notes)
	local rows, current = {}, nil
	for _, note in ipairs(notes) do
		if not current or math.abs(note.beat - current.beat) > EPS then
			current = { beat = note.beat, time = note.time, notes = {} }
			rows[#rows+1] = current
		end
		current.notes[#current.notes+1] = note
	end

	-- Work out which columns are being held down during each row.
	local active = {}  -- col -> endTime
	for _, row in ipairs(rows) do
		local cols = {}
		for _, note in ipairs(row.notes) do cols[note.col] = true end
		local held = {}
		for col, endTime in pairs(active) do
			if endTime <= row.time + 1e-4 or cols[col] then
				active[col] = nil
			else
				held[#held+1] = col
			end
		end
		table.sort(held)
		row.held = held
		for _, note in ipairs(row.notes) do
			if note.endTime and note.endTime > row.time then
				active[note.col] = note.endTime
			end
		end
	end
	return rows
end

-- ---------------------------------------------------------------------------
-- Placements

local function BuildPlacements(layout)
	local cols = layout.cols
	local list, single, bracket, float = {}, {}, {}, {}
	local function add(p) list[#list+1] = p; p.id = #list; return p end

	for c = 1, #cols do
		single[c] = add{ kind = "single", cols = { c }, x = cols[c][1], y = cols[c][2] }
		bracket[c] = {}
	end
	for a = 1, #cols - 1 do
		for b = a + 1, #cols do
			local dx, dy = cols[a][1] - cols[b][1], cols[a][2] - cols[b][2]
			if math.sqrt(dx*dx + dy*dy) <= 1.5 then
				local p = add{
					kind = "bracket", cols = { a, b },
					x = (cols[a][1] + cols[b][1]) / 2, y = (cols[a][2] + cols[b][2]) / 2,
				}
				bracket[a][b], bracket[b][a] = p, p
			end
		end
	end
	for c = 1, #cols do
		float[c] = add{ kind = "float", cols = {}, x = cols[c][1], y = cols[c][2] }
	end
	return { list = list, single = single, bracket = bracket, float = float }
end

local function Covers(p, c)
	for _, pc in ipairs(p.cols) do if pc == c then return true end end
	return false
end

local function Dist(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx*dx + dy*dy)
end

-- Placement for a foot that must cover all of `need` (1 or 2 columns), or nil.
local function PlacementFor(PL, need)
	if #need == 1 then return PL.single[need[1]] end
	if #need == 2 then return PL.bracket[need[1]][need[2]] end
	return nil
end

-- Where a foot ends up this row.
--   steps: columns this foot hits;  owned: held columns this foot must keep covering
-- Returns placement, or false if impossible.
local function Resolve(PL, prev, steps, owned)
	if #steps == 0 then return prev end
	local need = {}
	for _, c in ipairs(steps) do need[#need+1] = c end
	for _, c in ipairs(owned) do need[#need+1] = c end
	if #need > 2 then return false end
	table.sort(need)
	return PlacementFor(PL, need) or false
end

-- An idle foot loses any panels the other foot just stepped on.
local function Displace(PL, idle, other)
	local remaining, lost = {}, false
	for _, c in ipairs(idle.cols) do
		if Covers(other, c) then lost = true else remaining[#remaining+1] = c end
	end
	if not lost then return idle end
	if #remaining == 0 then return PL.float[idle.cols[1]] end
	return PlacementFor(PL, remaining)
end

-- Every way to split a row's notes between the feet (at most 2 notes per foot).
local function RowOptions(cols)
	local k, options = #cols, {}
	for mask = 0, (2 ^ k) - 1 do
		local left, right = {}, {}
		local m = mask
		for i = 1, k do
			if m % 2 == 0 then left[#left+1] = cols[i] else right[#right+1] = cols[i] end
			m = math.floor(m / 2)
		end
		if #left <= 2 and #right <= 2 then
			options[#options+1] = { left = left, right = right }
		end
	end
	return options
end

local function DoublestepScale(dt)
	if dt <= 0.5 then return 1 end
	if dt >= 2.0 then return 0.1 end
	return 1 - 0.9 * (dt - 0.5) / 1.5
end

-- Cost of moving from state `s` to (nl, nr). If `tech` is a table it is filled
-- with the techniques this step uses (only done for the final chosen path).
local function TransitionCost(s, nl, nr, opt, lOwned, rOwned, dt, tech)
	local cost = 0
	local movedL, movedR = #opt.left > 0, #opt.right > 0

	-- Doublesteps (free while the other foot is holding or has just let go,
	-- since releasing a hold takes the place of that foot's step).
	if movedL and not movedR and s.last == 1 and #rOwned == 0 and not s.rHolding and nl ~= s.l then
		cost = cost + W.DOUBLESTEP * DoublestepScale(dt)
		if tech then tech.doublestep = true end
	end
	if movedR and not movedL and s.last == 2 and #lOwned == 0 and not s.lHolding and nr ~= s.r then
		cost = cost + W.DOUBLESTEP * DoublestepScale(dt)
		if tech then tech.doublestep = true end
	end

	local fast = dt < Solver.FastThreshold

	-- Jacks: same foot re-hits the same panel(s) right after itself.
	if (movedL and nl == s.l and (s.last == 1 or s.last == 3))
	or (movedR and nr == s.r and (s.last == 2 or s.last == 3)) then
		cost = cost + (fast and W.FAST_JACK or W.JACK)
		if tech and fast then tech.jack = true end
	end

	-- Footswitches: stepping onto the panel the other foot is standing on.
	-- (If the other foot jumps elsewhere in the same row it's just a jump.)
	local footswitch = fast and W.FOOTSWITCH or W.SLOW_FOOTSWITCH
	for _, c in ipairs(opt.left) do
		if not movedR and Covers(s.r, c) then
			cost = cost + footswitch
			if tech then tech.footswitch = true end
		end
	end
	for _, c in ipairs(opt.right) do
		if not movedL and Covers(s.l, c) then
			cost = cost + footswitch
			if tech then tech.footswitch = true end
		end
	end

	-- Brackets.
	if (movedL and nl.kind == "bracket") or (movedR and nr.kind == "bracket") then
		cost = cost + W.BRACKET
		if tech then tech.bracket = true end
	end
	if movedL and nl.kind == "bracket" and movedR and nr.kind == "bracket" then
		cost = cost + W.BRACKET
	end
	if (movedL and #lOwned > 0) or (movedR and #rOwned > 0) then
		cost = cost + W.HOLD_TAP
	end

	-- Travel.
	if movedL then cost = cost + W.DISTANCE * Dist(s.l, nl) end
	if movedR then cost = cost + W.DISTANCE * Dist(s.r, nr) end

	-- Body orientation of the new stance.
	local dx = nr.x - nl.x
	if dx < -EPS then
		cost = cost + W.CROSSOVER * (-dx)
		if dx <= -2 + EPS then
			cost = cost + W.SPIN
			if tech and s.r.x - s.l.x > -2 + EPS then tech.spin = true end
		end
		if tech and s.r.x - s.l.x >= -EPS then tech.crossover = true end
	elseif dx < EPS and nl.kind ~= "float" and nr.kind ~= "float" then
		cost = cost + W.STACKED
	end
	local spread = Dist(nl, nr)
	if spread > 2.6 then cost = cost + W.SPREAD * (spread - 2.6) end

	return cost
end

-- ---------------------------------------------------------------------------
-- Body direction
--
-- Which way the hips/shoulders face for a given foot placement, seen from
-- above. Angles are in degrees: 0 = facing the screen, negative = turned to
-- the player's right (clockwise from above), positive = turned left.
-- A body facing angle a has its right hand pointing along (cos a, sin a) in
-- pad coordinates (x right, y toward the screen); "legs crossed" is the angle
-- between that and the left-foot -> right-foot direction. We pick the angle
-- that best balances facing the screen against crossing the legs, never
-- twisting the hips more than MAX_CROSS degrees against the feet (not
-- physically possible), and turning smoothly from the previous step.

Solver.Body = {
	CROSS = 2,        -- cost of crossing the legs, relative to...
	TURN = 1,         -- ...turning away from the screen
	TURN_RATE = 0.3,  -- cost of turning from the previous step's direction
	MAX_CROSS = 120,  -- hips can't twist further than this against the feet
}

local function WrapDeg(d)
	d = d % 360
	if d > 180 then d = d - 360 end
	return d
end
Solver.WrapDeg = WrapDeg

function Solver.Facing(lx, ly, rx, ry, previous)
	local B = Solver.Body
	local dx, dy = rx - lx, ry - ly
	local len = math.sqrt(dx * dx + dy * dy)
	previous = previous or 0
	local best, bestCost = previous, math.huge
	for deg = -180, 175, 5 do
		local a = math.rad(deg)
		local cross = 0
		if len > EPS then
			local c = (dx * math.cos(a) + dy * math.sin(a)) / len
			cross = math.deg(math.acos(math.max(-1, math.min(1, c))))
		end
		if cross <= B.MAX_CROSS then
			local cost = B.CROSS * (cross / 180) ^ 2
				+ B.TURN * (math.abs(deg) / 180) ^ 2
				+ B.TURN_RATE * math.abs(WrapDeg(deg - previous)) / 180
			if cost < bestCost then best, bestCost = deg, cost end
		end
	end
	return best
end

-- Unit vector the body faces, in pad coordinates.
function Solver.FacingVector(deg)
	local a = math.rad(deg)
	return -math.sin(a), math.cos(a)
end

-- ---------------------------------------------------------------------------
-- Solve

-- rows: from Solver.BuildRows. layoutName: "dance-single" or "dance-double".
-- yield: optional function called every Solver.YieldEvery rows (e.g. coroutine.yield).
-- Returns { layout=, rows = { ... per row: feet, L, R, tech ... }, stats = {...} }
function Solver.Solve(rows, layoutName, yield)
	local layout = Solver.Layouts[layoutName]
	if not layout then return nil end
	local PL = BuildPlacements(layout)

	-- Standing on the start panels; nobody has stepped yet.
	local startState = {
		l = PL.single[layout.start[1]], r = PL.single[layout.start[2]],
		last = 0, cost = 0,
	}
	local frontier = { startState }
	local prevTime = nil

	local function Step(row, relaxHolds)
		local cols = {}
		for _, note in ipairs(row.notes) do cols[#cols+1] = note.col end
		local options = RowOptions(cols)
		local held = relaxHolds and {} or row.held
		local dt = prevTime and (row.time - prevTime) or 10
		local best = {}
		local startsHold = {}
		for _, note in ipairs(row.notes) do
			if note.endTime and note.endTime > row.time then startsHold[note.col] = true end
		end
		local function Holding(steps, owned)
			if #owned > 0 then return true end
			for _, c in ipairs(steps) do if startsHold[c] then return true end end
			return false
		end

		for _, s in ipairs(frontier) do
			local lOwned, rOwned = {}, {}
			for _, c in ipairs(held) do
				if Covers(s.l, c) then lOwned[#lOwned+1] = c
				elseif Covers(s.r, c) then rOwned[#rOwned+1] = c end
			end
			for _, opt in ipairs(options) do
				local nl = Resolve(PL, s.l, opt.left, lOwned)
				local nr = Resolve(PL, s.r, opt.right, rOwned)
				if nl and nr then
					if #opt.left == 0 then nl = Displace(PL, nl, nr) end
					if #opt.right == 0 then nr = Displace(PL, nr, nl) end
					if nl and nr then
						local last = (#opt.left > 0 and 1 or 0) + (#opt.right > 0 and 2 or 0)
						local cost = s.cost + TransitionCost(s, nl, nr, opt, lOwned, rOwned, dt)
						local key = (nl.id * 1000 + nr.id) * 4 + last
						local cur = best[key]
						if not cur or cost < cur.cost then
							best[key] = {
								l = nl, r = nr, last = last, cost = cost,
								prev = s, opt = opt, lOwned = lOwned, rOwned = rOwned, dt = dt,
								lHolding = Holding(opt.left, lOwned),
								rHolding = Holding(opt.right, rOwned),
							}
						end
					end
				end
			end
		end

		local nextFrontier = {}
		for _, st in pairs(best) do nextFrontier[#nextFrontier+1] = st end
		return nextFrontier
	end

	for i, row in ipairs(rows) do
		local nextFrontier = Step(row, false)
		if #nextFrontier == 0 then nextFrontier = Step(row, true) end
		if #nextFrontier == 0 then
			-- Not physically playable with two feet (5+ panels); leave unassigned.
			nextFrontier = {}
			for _, s in ipairs(frontier) do
				nextFrontier[#nextFrontier+1] = {
					l = s.l, r = s.r, last = s.last, cost = s.cost, prev = s, unassigned = true,
				}
			end
		end
		table.sort(nextFrontier, function(a, b) return a.cost < b.cost end)
		for j = #nextFrontier, Solver.BeamWidth + 1, -1 do nextFrontier[j] = nil end
		frontier = nextFrontier
		prevTime = row.time
		if yield and i % Solver.YieldEvery == 0 then yield() end
	end

	-- Walk back from the cheapest final state.
	local path = {}
	local node = frontier[1]
	for i = #rows, 1, -1 do
		path[i] = node
		node = node.prev
	end

	local function Snapshot(p)
		return { kind = p.kind, x = p.x, y = p.y, cols = p.cols }
	end

	local stats = { crossovers = 0, footswitches = 0, brackets = 0, doublesteps = 0, jacks = 0, spins = 0 }
	local out = {}
	local startFacing = Solver.Facing(startState.l.x, startState.l.y, startState.r.x, startState.r.y, 0)
	local facing = startFacing
	for i, row in ipairs(rows) do
		local st = path[i]
		local feet, tech = {}, {}
		if not st.unassigned then
			for _, c in ipairs(st.opt.left) do feet[c] = "L" end
			for _, c in ipairs(st.opt.right) do feet[c] = "R" end
			TransitionCost(st.prev, st.l, st.r, st.opt, st.lOwned, st.rOwned, st.dt, tech)
			if tech.crossover then stats.crossovers = stats.crossovers + 1 end
			if tech.footswitch then stats.footswitches = stats.footswitches + 1 end
			if tech.bracket then stats.brackets = stats.brackets + 1 end
			if tech.doublestep then stats.doublesteps = stats.doublesteps + 1 end
			if tech.jack then stats.jacks = stats.jacks + 1 end
			if tech.spin then stats.spins = stats.spins + 1 end
		end
		local notes = {}
		for _, note in ipairs(row.notes) do
			notes[#notes+1] = {
				col = note.col, foot = feet[note.col],
				kind = note.kind, endTime = note.endTime,
			}
		end
		facing = Solver.Facing(st.l.x, st.l.y, st.r.x, st.r.y, facing)
		out[i] = {
			beat = row.beat, time = row.time, notes = notes, tech = tech, cost = st.cost,
			L = Snapshot(st.l), R = Snapshot(st.r), facing = facing,
			movedL = st.opt ~= nil and #st.opt.left > 0,
			movedR = st.opt ~= nil and #st.opt.right > 0,
		}
	end

	return {
		layout = layout,
		rows = out,
		startL = Snapshot(startState.l),
		startR = Snapshot(startState.r),
		startFacing = startFacing,
		stats = stats,
		cost = frontier[1].cost,
	}
end

return Solver
