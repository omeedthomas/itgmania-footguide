-- Compares FootGuide's solver with ITGmania's own StepParity tech counts,
-- which ITGmania stores in its song cache (#TECHCOUNTS).
--   node tests/run.js tests/compare.lua <cache dir> <song roots> [max songs] [verbose] [weights] [stride]
--     <cache dir>   ITGmania's Cache/Songs folder (in its data folder)
--     <song roots>  folders containing Songs/, separated by ";" (e.g. the install
--                   folder and the data folder)
--     [weights]     overrides like "CROSSOVER=60,BRACKET=40" for tuning
--     [stride]      only use every Nth song (for quicker tuning runs)
local Solver = assert(load(READ(ROOT .. "Modules/FootGuide/Solver.lua"), "@Solver.lua"))()

local cacheDir = ARGS[1]
if not cacheDir or not ARGS[2] then
	error("usage: compare.lua <cache dir> <song roots separated by ;> [max songs] [verbose] [weights] [stride]", 0)
end
local songRoots = {}
for root in ARGS[2]:gmatch("[^;]+") do songRoots[#songRoots+1] = (root:gsub("[/\\]$", "")) end
table.remove(ARGS, 2)   -- the remaining arguments keep their old positions
local stride = tonumber(ARGS[5] or "1")

local OLD_DIFFICULTY = {
	beginner = "beginner", easy = "easy", basic = "easy", light = "easy",
	medium = "medium", another = "medium", trick = "medium", standard = "medium", difficult = "medium",
	hard = "hard", ssr = "hard", maniac = "hard", heavy = "hard",
	challenge = "challenge", smaniac = "challenge", expert = "challenge", oni = "challenge",
	edit = "edit",
}
local function NormalizeDifficulty(d) return OLD_DIFFICULTY[d:lower()] or d end

local fileCache = {}
local function ReadSimfile(stepFilename)
	if fileCache[stepFilename] == nil then
		fileCache[stepFilename] = false
		for _, root in ipairs(songRoots) do
			local text = READ(root .. stepFilename)
			if text then fileCache[stepFilename] = text break end
		end
	end
	return fileCache[stepFilename] or nil
end
local maxSongs = tonumber(ARGS[2] or "100000")
local verbose = ARGS[3] == "verbose"
-- ARGS[4]: weight overrides, e.g. "CROSSOVER=60,BRACKET=40"
for k, v in (ARGS[4] or ""):gmatch("([%w_]+)=([%d%.]+)") do
	if k == "FastThreshold" then Solver.FastThreshold = tonumber(v) else Solver.Weights[k] = tonumber(v) end
end

local FIELDS = { "Crossovers", "HalfCrossovers", "FullCrossovers", "Footswitches",
	"UpFootswitches", "DownFootswitches", "Sideswitches", "Jacks", "Brackets", "Doublesteps" }

local function ParsePairs(s)
	local out = {}
	for a, b in (s or ""):gmatch("([%-%d%.]+)=([%-%d%.]+)") do
		out[#out+1] = { tonumber(a), tonumber(b) }
	end
	return out
end

-- Seconds from beat using BPM changes and stops (warps/negative BPMs ignored).
local function TimingFunc(bpms, stops)
	return function(beat)
		local t, i = 0, 1
		while i <= #bpms do
			local startBeat, bpm = bpms[i][1], bpms[i][2]
			local endBeat = bpms[i+1] and bpms[i+1][1] or math.huge
			if beat <= endBeat then
				t = t + (beat - startBeat) * 60 / bpm
				break
			end
			t = t + (endBeat - startBeat) * 60 / bpm
			i = i + 1
		end
		for _, s in ipairs(stops) do
			if s[1] < beat then t = t + s[2] end
		end
		return t
	end
end

local function Field(chunk, name)
	return chunk:match("#" .. name .. ":([^;]*);")
end

local totals = { charts = 0, rows = 0, seconds = 0, skipped = 0 }
local agg = {}
for _, k in ipairs({ "crossovers", "footswitches", "brackets", "doublesteps", "jacks" }) do
	agg[k] = { mine = 0, engine = 0, absdiff = 0, exact = 0 }
end

local function Compare(key, mine, engine)
	local a = agg[key]
	a.mine = a.mine + mine
	a.engine = a.engine + engine
	a.absdiff = a.absdiff + math.abs(mine - engine)
	if mine == engine then a.exact = a.exact + 1 end
end

local files = LISTDIR(cacheDir)
local nSongs = 0
for fileIndex, name in ipairs(files) do
	if nSongs >= maxSongs then break end
	local text = (fileIndex % stride == 0) and READ(cacheDir .. "/" .. name)
	if text then
		nSongs = nSongs + 1
		text = text:gsub("\r\n?", "\n")
		local songBpms = ParsePairs(Field(text, "BPMS"))
		local songStops = ParsePairs(Field(text, "STOPS"))
		local warps = Field(text, "WARPS") or ""
		local pos = 1
		while true do
			local s = text:find("#NOTEDATA:", pos, true)
			if not s then break end
			local e = text:find("#NOTEDATA:", s + 1, true) or (#text + 1)
			local chunk = text:sub(s, e - 1)
			pos = s + 1
			local st = (Field(chunk, "STEPSTYPE") or ""):gsub("%s", "")
			local tc = Field(chunk, "TECHCOUNTS")
			local stepFile = Field(chunk, "STEPFILENAME") or ""
			local simfile = ReadSimfile(stepFile)
			local noteData = simfile and Solver.ExtractNoteData(simfile, stepFile:match("[^.]+$"),
				"dance-single", NormalizeDifficulty(Field(chunk, "DIFFICULTY") or ""),
				Field(chunk, "DESCRIPTION") or "", NormalizeDifficulty)
			if st == "dance-single" and tc and not noteData then totals.missing = (totals.missing or 0) + 1 end
			local chartBpms = ParsePairs(Field(chunk, "BPMS"))
			if st == "dance-single" and tc and noteData and warps:match("^%s*$")
			and not (Field(chunk, "WARPS") or ""):match("%d") then
				local bpms = #chartBpms > 0 and chartBpms or songBpms
				local stops = #chartBpms > 0 and ParsePairs(Field(chunk, "STOPS")) or songStops
				local negative = false
				for _, b in ipairs(bpms) do if b[2] <= 0 then negative = true end end
				for _, b in ipairs(stops) do if b[2] < 0 then negative = true end end
				if negative or #bpms == 0 then
					totals.skipped = totals.skipped + 1
				else
					local ToTime = TimingFunc(bpms, stops)
					local notes = Solver.ParseNotes(noteData, 4)
					for _, n in ipairs(notes) do
						n.time = ToTime(n.beat)
						if n.endBeat then n.endTime = ToTime(n.endBeat) end
					end
					local rows = Solver.BuildRows(notes)
					local t0 = CLOCK()
					local result = Solver.Solve(rows, "dance-single")
					totals.seconds = totals.seconds + (CLOCK() - t0)
					totals.charts = totals.charts + 1
					totals.rows = totals.rows + #rows

					local engine = {}
					local i = 0
					for v in tc:gmatch("[^,]+") do
						i = i + 1
						if FIELDS[i] then engine[FIELDS[i]] = math.floor(tonumber(v) + 0.5) end
					end
					local m = result.stats
					Compare("crossovers", m.crossovers, engine.Crossovers)
					Compare("footswitches", m.footswitches, engine.Footswitches)
					Compare("brackets", m.brackets, engine.Brackets)
					Compare("doublesteps", m.doublesteps, engine.Doublesteps)
					Compare("jacks", m.jacks, engine.Jacks)
					if verbose then
						print(string.format("%-50s %-10s rows=%4d  XO %3d/%3d  FS %3d/%3d  BR %3d/%3d  DS %3d/%3d",
							name:sub(1, 50), (Field(chunk, "DIFFICULTY") or ""):sub(1, 10), #rows,
							m.crossovers, engine.Crossovers, m.footswitches, engine.Footswitches,
							m.brackets, engine.Brackets, m.doublesteps, engine.Doublesteps))
					end
				end
			end
		end
	end
end

print("charts whose note data could not be extracted: " .. (totals.missing or 0))
print(string.format("charts=%d (skipped %d with warps/negative timing)  rows=%d  solve time=%.1fs (%.2f ms/row in fengari)",
	totals.charts, totals.skipped, totals.rows, totals.seconds, 1000 * totals.seconds / math.max(1, totals.rows)))
local score = 0
for _, k in ipairs({ "crossovers", "footswitches", "brackets", "doublesteps" }) do
	score = score + agg[k].absdiff / math.max(1, totals.charts)
end
print(string.format("SCORE %.3f  (sum of mean|diff| over XO/FS/BR/DS; weights: %s)", score, ARGS[4] or "default"))
print("                 mine   engine   mean|diff|   exact-match")
for _, k in ipairs({ "crossovers", "footswitches", "brackets", "doublesteps", "jacks" }) do
	local a = agg[k]
	print(string.format("%-14s %7d %8d %10.2f %10.1f%%", k, a.mine, a.engine,
		a.absdiff / math.max(1, totals.charts), 100 * a.exact / math.max(1, totals.charts)))
end
