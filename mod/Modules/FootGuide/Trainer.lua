-- FootGuide Trainer: the actors for ScreenFootGuideTrainer.
--
-- Pick a section of the chart (the trickiest 2-measure stretches are listed
-- first). The song plays and the notes scroll up to a line; the music pauses
-- whenever a step reaches the line and you haven't hit it yet. (Only a song
-- with no music file falls back to simply waiting at every step.)
-- Each step is demonstrated on a big pad: the moving foot slides along a
-- dotted path to where it lands, and for footswitches the foot already on
-- the panel visibly lifts off as the other one lands.
--
-- Loaded by Modules/FootGuide.lua, which passes in shared helpers.

local ctx = ...
local Solver = ctx.Solver
local StartAnalysis, TECHS = ctx.StartAnalysis, ctx.TECHS
local PadDef, SetupPad, Arrow, FootColor = ctx.PadDef, ctx.SetupPad, ctx.Arrow, ctx.FootColor
local ROTATION, TechColor, WarnColor = ctx.ROTATION, ctx.TechColor, ctx.WarnColor

local SECTION_MEASURES = 2
local MAX_SECTIONS     = 8
local MENU_ITEMS       = MAX_SECTIONS + 1
local UPCOMING         = 6      -- rows in the step-by-step "next steps" list
local MAX_COLS         = 8
local DOTS_PER_FOOT    = 6
local DEMO_PERIOD      = 1.6    -- seconds per loop of the move demonstration
local LANE_NOTES       = 32     -- pooled arrows for the music lane
local LANE_PX_PER_SEC  = 150
local PRE_ROLL         = 2.0    -- seconds of music before a section's first step
local EARLY_WINDOW     = 0.5    -- presses this early (seconds) count in music mode

local GoodColor = color("#69f0ae")
local DIR_WORD  = { Left = "LEFT", Down = "DOWN", Up = "UP", Right = "RIGHT" }
local FOOT_WORD = { L = "LEFT", R = "RIGHT" }
local BUTTON_COL = { Left = 1, Down = 2, Up = 3, Right = 4 }

local function SoundPath(group, name)
	local ok, path = pcall(function() return THEME:GetPathS(group, name) end)
	return ok and path or nil
end
local SND_GOOD = SoundPath("ScreenEdit", "AddNote")
local SND_BAD  = SoundPath("Common", "invalid")
local SND_DONE = SoundPath("Common", "start")
local function Play(path) if path then SOUND:PlayOnce(path) end end

local function Now() return GetTimeSinceStart() end
local function Clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function Smooth(t) return t * t * (3 - 2 * t) end
local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
local function Covers(p, c)
	for _, pc in ipairs(p.cols or {}) do if pc == c then return true end end
	return false
end

-- ---------------------------------------------------------------------------
-- Sections

-- The trickiest non-overlapping stretches of the chart, in chart order.
local function BuildSections(rows)
	local score = {}
	for _, row in ipairs(rows) do
		local m = math.floor(row.beat / 4 + 1e-6)
		for _, def in ipairs(TECHS) do
			if row.tech[def.key] then score[m] = (score[m] or 0) + def.weight end
		end
	end
	local candidates, seen = {}, {}
	for m in pairs(score) do
		for start = math.max(0, m - SECTION_MEASURES + 1), m do
			if not seen[start] then
				seen[start] = true
				local total = 0
				for k = start, start + SECTION_MEASURES - 1 do total = total + (score[k] or 0) end
				candidates[#candidates+1] = { start = start, score = total }
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.start < b.start
	end)
	local picked = {}
	for _, c in ipairs(candidates) do
		if #picked >= MAX_SECTIONS then break end
		local overlaps = false
		for _, p in ipairs(picked) do
			if c.start < p.start + SECTION_MEASURES and p.start < c.start + SECTION_MEASURES then overlaps = true end
		end
		if not overlaps then picked[#picked+1] = c end
	end
	table.sort(picked, function(a, b) return a.start < b.start end)

	local sections = {}
	for _, p in ipairs(picked) do
		local first, last
		local counts = {}
		for i, row in ipairs(rows) do
			local m = math.floor(row.beat / 4 + 1e-6)
			if m >= p.start and m < p.start + SECTION_MEASURES then
				first, last = first or i, i
				for _, def in ipairs(TECHS) do
					if row.tech[def.key] then counts[def.key] = (counts[def.key] or 0) + 1 end
				end
			end
		end
		if first then
			local detail = {}
			for _, def in ipairs(TECHS) do
				if counts[def.key] then detail[#detail+1] = Plural(counts[def.key], def.name) end
			end
			sections[#sections+1] = {
				-- start a couple of steps early so your feet are set up
				first = math.max(1, first - 2), last = last,
				label = ("Measures %d-%d"):format(p.start + 1, p.start + SECTION_MEASURES),
				detail = table.concat(detail, ", "),
			}
		end
	end
	table.insert(sections, 1, {
		first = 1, last = #rows, label = "Whole chart", detail = Plural(#rows, "step"),
	})
	return sections
end

-- ---------------------------------------------------------------------------
-- Explaining a step in words

local function PanelName(layout, col)
	local word = DIR_WORD[layout.dirs[col]]
	if #layout.cols > 4 then word = word .. (col > 4 and " (P2)" or " (P1)") end
	return word
end

local function PlacementName(layout, p)
	if not p.cols or #p.cols == 0 then return "the air" end
	local names = {}
	for _, c in ipairs(p.cols) do names[#names+1] = PanelName(layout, c) end
	return table.concat(names, " + ")
end

-- Where each foot is before row i, where it ends up, and what moves.
local function StepInfo(s, i)
	local row = s.rows[i]
	local before = s.rows[i - 1]
	local info = {
		row = row,
		from = { L = before and before.L or s.result.startL, R = before and before.R or s.result.startR },
		to = { L = row.L, R = row.R },
		moved = { L = row.movedL, R = row.movedR },
		fromFacing = before and before.facing or s.result.startFacing or 0,
		toFacing = row.facing or 0,
	}
	-- how the body was already turning on the step before (to say "keep turning")
	local twoBefore = s.rows[i - 2]
	info.prevTurn = before and (info.fromFacing - (twoBefore and twoBefore.facing or s.result.startFacing or 0)) or 0
	-- A footswitch: the foot already standing on the panel has to get off.
	for _, note in ipairs(row.notes) do
		local f = note.foot
		local g = (f == "L") and "R" or "L"
		if f and not info.moved[g] and Covers(info.from[g], note.col) then
			info.switch = { foot = f, other = g, col = note.col }
			-- where the displaced foot goes next (for the animation)
			for j = i + 1, math.min(#s.rows, i + 16) do
				local later = s.rows[j]
				if (g == "L" and later.movedL) or (g == "R" and later.movedR) then
					info.switch.next = (g == "L") and later.L or later.R
					break
				end
			end
		end
	end
	return info
end

local function Explain(s, info)
	local layout, row = s.layout, info.row
	local parts = {}
	for _, f in ipairs({ "L", "R" }) do
		if info.moved[f] then
			local from, to = PlacementName(layout, info.from[f]), PlacementName(layout, info.to[f])
			if from == to then
				parts[#parts+1] = FOOT_WORD[f] .. " foot: " .. to .. " again"
			else
				parts[#parts+1] = FOOT_WORD[f] .. " foot: " .. from .. "  >  " .. to
			end
		end
	end
	local headline = table.concat(parts, "      ")

	local how = {}
	if info.moved.L and info.moved.R then how[#how+1] = "Jump: both feet land at the same time." end
	if info.switch then
		local sw = info.switch
		how[#how+1] = ("Footswitch: lift your %s foot off %s as your %s foot lands on it."):format(
			FOOT_WORD[sw.other], PanelName(layout, sw.col), FOOT_WORD[sw.foot])
	end
	local mover = info.moved.L and "L" or "R"
	local other = (mover == "L") and "R" or "L"
	-- Is the moving foot ahead of or behind the other one, along the way the body faces?
	local fx, fy = Solver.FacingVector(info.toFacing)
	local m, o = info.to[mover], info.to[other]
	local inFront = ((m.x - o.x) * fx + (m.y - o.y) * fy) >= 0
	-- Turns are described as the turn you actually make on this step (facing
	-- angles keep counting through spins, so this is never the "long way").
	local turn = info.toFacing - info.fromFacing
	local function Side(deg) return deg < 0 and "right" or "left" end
	local function About(deg) return math.max(15, math.floor(math.abs(deg) / 15 + 0.5) * 15) end
	local function Ends(deg)   -- where the body ends up, in words
		local w = Solver.WrapDeg(deg)
		if math.abs(w) < 20 then return "facing the screen" end
		if math.abs(w) <= 65 then return "half-turned to your " .. Side(w) end
		if math.abs(w) <= 120 then return "facing the " .. Side(w) .. " wall" end
		return "with your back to the screen"
	end
	local keepGoing = info.prevTurn * turn > 0 and math.abs(info.prevTurn) >= 15
	local function Turning()
		if math.abs(turn) < 15 then return "" end
		return (", %s about %d degrees to your %s (%s)"):format(keepGoing and "still turning" or "turning",
			About(turn), Side(turn), Ends(info.toFacing))
	end
	if row.tech.crossover then
		how[#how+1] = ("Crossover: bring your %s leg %s your %s leg%s."):format(FOOT_WORD[mover],
			inFront and "across in front of" or "around behind", FOOT_WORD[other], Turning())
	end
	if row.tech.spin then
		how[#how+1] = ("Spin: %s %s (to your %s) about %d degrees, ending %s. Turn your whole body, not just your legs."):format(
			keepGoing and "keep turning" or "turn", turn < 0 and "clockwise" or "counter-clockwise", Side(turn),
			About(turn), Ends(info.toFacing))
	end
	if not row.tech.crossover and not row.tech.spin and math.abs(turn) >= 30 then
		how[#how+1] = ("Body: %s about %d degrees to your %s, ending %s."):format(
			keepGoing and "keep turning" or "turn", About(turn), Side(turn), Ends(info.toFacing))
	end
	for _, f in ipairs({ "L", "R" }) do
		local p = info.to[f]
		if info.moved[f] and p.kind == "bracket" then
			local a, b = p.cols[1], p.cols[2]
			if layout.cols[a][2] > layout.cols[b][2] then a, b = b, a end
			if layout.cols[a][2] == layout.cols[b][2] then
				how[#how+1] = ("Bracket: your %s foot covers %s and %s at once (ball of the foot across both)."):format(
					FOOT_WORD[f], PanelName(layout, a), PanelName(layout, b))
			else
				how[#how+1] = ("Bracket: %s heel on %s, toe on %s; hit both at once."):format(
					FOOT_WORD[f], PanelName(layout, a), PanelName(layout, b))
			end
		end
	end
	if row.tech.doublestep then
		how[#how+1] = ("Doublestep: your %s foot steps again; the other foot can't get there in time."):format(FOOT_WORD[mover])
	end
	if row.tech.jack then how[#how+1] = "Jack: same foot, same arrow, again." end
	for _, note in ipairs(row.notes) do
		if note.endTime and note.foot then
			how[#how+1] = ("Hold %s down with your %s foot until the hold ends."):format(
				PanelName(layout, note.col), FOOT_WORD[note.foot])
		end
	end
	-- Holds from earlier rows that are still down.
	for _, h in ipairs(s.holds) do
		if h.time < row.time and h.endTime > row.time and h.foot then
			how[#how+1] = ("Keep holding %s with your %s foot."):format(PanelName(layout, h.col), FOOT_WORD[h.foot])
		end
	end
	if info.to.L.x > info.to.R.x + 1e-6 and not row.tech.crossover and not row.tech.spin then
		how[#how+1] = ("(Still crossed: you're %s.)"):format(Ends(info.toFacing))
	end
	return headline, table.concat(how, "\n")
end

-- ---------------------------------------------------------------------------

local panels = {}   -- pnShort -> controller, for input routing

local function TrainerPanel(pn)
	local pnShort = ToEnumShortString(pn)
	local s = { holds = {} }
	local W, H = 640, 440

	local af = Def.ActorFrame{
		Name = "Trainer" .. pnShort,
		InitCommand = function(self) self:visible(false) end,
	}
	local function Text(name, font, zoom, init)
		return Def.BitmapText{
			Font = font, Name = name,
			InitCommand = function(self)
				self:zoom(zoom)
				if init then init(self) end
			end,
		}
	end

	af[#af+1] = Def.Quad{ Name = "Bg", InitCommand = function(self) self:zoomto(W, H):valign(0):diffuse(0, 0, 0, 0.8) end }
	af[#af+1] = Text("Title", "Common Bold", 0.8, function(self) self:y(22):settext("FOOT GUIDE TRAINER") end)
	af[#af+1] = Text("Chart", "Common Normal", 0.65, function(self) self:y(46):diffusealpha(0.8):maxwidth(W / 0.65 - 40) end)
	af[#af+1] = Text("Status", "Common Normal", 0.8, function(self) self:y(200):wrapwidthpixels(W / 0.8 - 80) end)

	-- Section menu
	local menu = Def.ActorFrame{ Name = "Menu" }
	menu[#menu+1] = Text("Prompt", "Common Normal", 0.7, function(self)
		self:y(74):diffuse(TechColor):settext("Choose what to practice (Up/Down), then press Start")
	end)
	menu[#menu+1] = Text("About", "Common Normal", 0.6, function(self)
		self:y(98):diffusealpha(0.8):settext("The song plays and pauses whenever an arrow reaches the line before you've stepped.")
	end)
	menu[#menu+1] = Def.Quad{ Name = "Cursor", InitCommand = function(self) self:zoomto(W - 60, 28):diffuse(1, 1, 1, 0.12) end }
	for i = 1, MENU_ITEMS do
		menu[#menu+1] = Def.ActorFrame{
			Name = "Item" .. i,
			Text("Label", "Common Bold", 0.42, function(self) self:halign(0):x(-W / 2 + 44):maxwidth((W / 2 - 60) / 0.42) end),
			Text("Detail", "Common Normal", 0.6, function(self) self:halign(1):x(W / 2 - 44):diffusealpha(0.85):maxwidth((W / 2 - 60) / 0.6) end),
		}
	end
	af[#af+1] = menu

	-- Drill
	local dots = Def.ActorFrame{ Name = "Dots" }
	for f = 1, 2 do
		for d = 1, DOTS_PER_FOOT do
			dots[#dots+1] = Def.Quad{ Name = "Dot" .. f .. "_" .. d, InitCommand = function(self) self:zoomto(6, 6):rotationz(45):visible(false) end }
		end
	end
	local drill = Def.ActorFrame{ Name = "Drill" }
	drill[#drill+1] = Text("Instruction", "Common Bold", 0.72, function(self) self:y(76):maxwidth((W - 30) / 0.72) end)
	drill[#drill+1] = Text("Help", "Common Normal", 0.58, function(self)
		self:y(96):valign(0):diffuse(TechColor):wrapwidthpixels((W - 40) / 0.58):vertspacing(-2)
	end)
	drill[#drill+1] = PadDef("Pad", { dots })

	-- Step-by-step: list of the next few steps
	local list = Def.ActorFrame{ Name = "List" }
	list[#list+1] = Def.Quad{ Name = "Current", InitCommand = function(self) self:diffuse(1, 1, 1, 0.12) end }
	for r = 1, UPCOMING do
		local row = Def.ActorFrame{ Name = "Row" .. r }
		for c = 1, MAX_COLS do
			row[#row+1] = Def.ActorFrame{
				Name = "Note" .. c,
				Arrow(26, "Arrow"),
				Text("Letter", "Common Normal", 0.6, function(self) self:diffuse(Color.Black) end),
			}
		end
		row[#row+1] = Text("Tag", "Common Bold", 0.5, function(self) self:halign(0) end)
		list[#list+1] = row
	end
	list[#list+1] = Text("Heading", "Common Normal", 0.55, function(self) self:diffusealpha(0.7):settext("NEXT STEPS") end)
	drill[#drill+1] = list

	-- With music: notes scroll up to a line and the music waits there
	local lane = Def.ActorFrame{ Name = "Lane" }
	lane[#lane+1] = Def.Quad{ Name = "LaneBg", InitCommand = function(self) self:diffuse(1, 1, 1, 0.05) end }
	for c = 1, MAX_COLS do lane[#lane+1] = Arrow(26, "Receptor" .. c) end
	for k = 1, LANE_NOTES do
		lane[#lane+1] = Def.ActorFrame{
			Name = "Note" .. k,
			Arrow(26, "Arrow"),
			Text("Letter", "Common Normal", 0.6, function(self) self:diffuse(Color.Black) end),
		}
	end
	lane[#lane+1] = Text("Heading", "Common Normal", 0.55, function(self) self:diffusealpha(0.7) end)
	drill[#drill+1] = lane

	drill[#drill+1] = Text("Progress", "Common Normal", 0.7, function(self) self:y(H - 50) end)
	drill[#drill+1] = Text("Result", "Common Bold", 0.9, function(self) self:y(H - 92):visible(false) end)
	af[#af+1] = drill

	af[#af+1] = Text("Hint", "Common Normal", 0.55, function(self) self:y(H - 20):diffusealpha(0.7) end)

	-- -----------------------------------------------------------------------

	local function Child(name) return s.af:GetChild(name) end
	local function Drill() return Child("Drill") end
	local function SetHint(text) Child("Hint"):settext(text) end

	-- Back to Player Options for the same song, where you can practise again
	-- (Start) or change the Foot Guide mode and play it. This screen type
	-- doesn't act on Back by itself, so the trainer starts the transition.
	local function LeaveScreen()
		local screen = SCREENMAN:GetTopScreen()
		if s.leaving or not screen then return end
		s.leaving = true
		screen:SetNextScreenName("ScreenPlayerOptions"):StartTransitioningScreen("SM_GoToNextScreen")
	end

	local function StopAudio()
		if s.playing then SOUND:StopMusic() end
		s.playing = false
	end

	local function StartAudio()
		if not s.musicPath then return end
		local untilT = s.rows[s.section.last].time + 1.5
		SOUND:PlayMusicPart(s.musicPath, s.clock, math.max(0.2, untilT - s.clock), 0.03, 0.15, false, true)
		s.playing, s.realStart, s.clockStart = true, Now(), s.clock
	end

	local function ShowPhase(phase)
		s.phase = phase
		Child("Menu"):visible(phase == "menu")
		Drill():visible(phase == "drill" or phase == "done")
		Child("Status"):visible(phase == "loading" or phase == "error")
		if phase == "menu" then
			SetHint("Up/Down: section   Start: practice   Back: options")
		elseif phase == "drill" then
			SetHint(s.music and "Step when the arrows reach the line; the music waits for you   Start: restart   Back: sections"
				or "Watch the demo, then step on the glowing arrows   Start: restart   Back: sections")
		elseif phase == "done" then
			SetHint("Start: go again   Back: choose another section")
		elseif phase == "error" then
			SetHint("Back: return to options")
		end
	end

	local function DrawMenu()
		local M = Child("Menu")
		for i = 1, MENU_ITEMS do
			local item = M:GetChild("Item" .. i)
			local section = s.sections[i]
			item:visible(section ~= nil):y(126 + (i - 1) * 30)
			if section then
				item:GetChild("Label"):settext(section.label)
				item:GetChild("Detail"):settext(section.detail)
			end
		end
		M:GetChild("Cursor"):y(126 + (s.menuIndex - 1) * 30)
	end

	local function SetupDrillLayout()
		local layout = s.layout
		local n = #layout.cols
		local double = n > 4
		local D = Drill()
		local panelSize = double and 46 or 72
		D:GetChild("Pad"):x(double and -150 or -140)
		s.pad = SetupPad(D:GetChild("Pad"), layout, panelSize, 160)
		s.panelSize = panelSize

		local colW = double and 22 or 34
		local listX = double and 165 or 175
		s.colX = function(c) return (c - (n + 1) / 2) * colW end

		local L = D:GetChild("List")
		L:x(listX)
		L:GetChild("Heading"):y(160)
		L:GetChild("Current"):zoomto(n * colW + 16, 34):y(188)
		for r = 1, UPCOMING do
			local rowAF = L:GetChild("Row" .. r)
			rowAF:y(188 + (r - 1) * 36)
			for c = 1, MAX_COLS do
				local note = rowAF:GetChild("Note" .. c)
				note:visible(false):x(c <= n and s.colX(c) or 0):zoom(colW / 30)
				if c <= n then note:GetChild("Arrow"):rotationz(ROTATION[layout.dirs[c]]) end
			end
			rowAF:GetChild("Tag"):x(s.colX(n) + colW / 2 + 6)
		end

		local Ln = D:GetChild("Lane")
		Ln:x(listX)
		s.laneTop, s.laneBottom, s.receptorY = 170, H - 72, 188
		Ln:GetChild("Heading"):y(160):settext("THE LINE = NOW")
		Ln:GetChild("LaneBg"):zoomto(n * colW + 16, s.laneBottom - s.laneTop):valign(0):y(s.laneTop)
		for c = 1, MAX_COLS do
			local r = Ln:GetChild("Receptor" .. c)
			r:visible(c <= n)
			if c <= n then
				r:xy(s.colX(c), s.receptorY):rotationz(ROTATION[layout.dirs[c]]):zoom(colW / 30):diffuse(1, 1, 1, 0.35)
			end
		end
		for k = 1, LANE_NOTES do Ln:GetChild("Note" .. k):visible(false):zoom(colW / 30) end
	end

	-- -----------------------------------------------------------------------
	-- Drawing

	local function HideDots()
		local Dots = Drill():GetChild("Pad"):GetChild("Dots")
		for f = 1, 2 do
			for d = 1, DOTS_PER_FOOT do Dots:GetChild("Dot" .. f .. "_" .. d):visible(false) end
		end
	end

	-- Text, pad glow, ghost feet and dotted paths for the current step.
	local function DrawStep()
		local D = Drill()
		if s.phase == "done" then
			local last = s.rows[s.section.last]
			s.info = nil
			s.pad.Show(last.L, last.R, nil, false, nil, last.facing)
			HideDots()
			return
		end
		local info = StepInfo(s, s.i)
		s.info = info
		s.pad.Show(info.from.L, info.from.R, info.row, false, s.pressed, info.fromFacing)

		local headline, how = Explain(s, info)
		if s.i == s.section.first and s.mistakes == 0 and next(s.pressed) == nil and not s.music then
			headline = "Get in place, then:  " .. headline
		end
		D:GetChild("Instruction"):settext(headline)
		D:GetChild("Help"):settext(how)

		-- dotted path from where each moving foot is to where it lands
		local Dots = D:GetChild("Pad"):GetChild("Dots")
		for fi, f in ipairs({ "L", "R" }) do
			local a, b = info.from[f], info.to[f]
			local show = info.moved[f] and (a.x ~= b.x or a.y ~= b.y or a.kind ~= b.kind)
			local x1, y1 = s.pad.Where(info.from[f])
			local x2, y2 = s.pad.Where(info.to[f])
			for d = 1, DOTS_PER_FOOT do
				local dot = Dots:GetChild("Dot" .. fi .. "_" .. d)
				if show then
					local t = d / (DOTS_PER_FOOT + 1)
					dot:visible(true):xy(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
						:diffuse(FootColor(f)):diffusealpha(0.65)
				else
					dot:visible(false)
				end
			end
		end
	end

	-- Animate the feet: `p` is the move's progress 0..1, `lift` how far the
	-- displaced foot (footswitch) has lifted off.
	local function PoseFeet(p, lift)
		local info = s.info
		if not info then return end
		local PadAF = Drill():GetChild("Pad")
		local at = {}   -- where each foot is drawn this frame, for the body
		for _, f in ipairs({ "L", "R" }) do
			local actor = PadAF:GetChild("Foot" .. f)
			local x1, y1, r1 = s.pad.Where(info.from[f])
			at[f] = { x1, y1 }
			if info.moved[f] then
				local x2, y2, r2 = s.pad.Where(info.to[f])
				local e = Smooth(p)
				at[f] = { x1 + (x2 - x1) * e, y1 + (y2 - y1) * e }
				actor:visible(true):stoptweening()
					:xy(at[f][1], at[f][2]):rotationz(r1 + (r2 - r1) * e)
					:zoom(1 + 0.22 * math.sin(math.pi * e)):diffusealpha(1)
			elseif info.switch and info.switch.other == f then
				-- footswitch: this foot lifts off and drifts toward where it goes next
				local tx, ty = x1 + (f == "L" and -0.35 or 0.35) * s.panelSize, y1
				if info.switch.next then
					local nx, ny = s.pad.Where(info.switch.next)
					tx, ty = x1 + (nx - x1) * 0.45, y1 + (ny - y1) * 0.45
				end
				local e = Smooth(lift)
				at[f] = { x1 + (tx - x1) * e, y1 + (ty - y1) * e }
				actor:visible(true):stoptweening()
					:xy(at[f][1], at[f][2]):rotationz(r1)
					:zoom(1 + 0.18 * e):diffusealpha(1 - 0.5 * e)
			else
				actor:visible(true):stoptweening():xy(x1, y1):rotationz(r1):zoom(1)
					:diffusealpha(info.from[f].kind == "float" and 0.45 or 1)
			end
		end
		-- the body turns along with the step (facing keeps counting through spins,
		-- so this always turns the way the body really goes)
		local facing = info.fromFacing + (info.toFacing - info.fromFacing) * Smooth(p)
		s.pad.DrawBody(at.L[1], at.L[2], at.R[1], at.R[2], facing)
	end

	-- Looping demonstration (step by step, or while the music waits).
	local function DemoPose()
		local t = ((Now() - s.demoStart) % DEMO_PERIOD) / DEMO_PERIOD
		local p = Clamp((t - 0.15) / 0.4, 0, 1)            -- hold, move, hold at target
		local lift = Clamp((t - 0.1) / 0.35, 0, 1)          -- the displaced foot leaves first
		PoseFeet(p, lift)
	end

	local function DrawList()
		local Lst = Drill():GetChild("List")
		for r = 1, UPCOMING do
			local rowAF = Lst:GetChild("Row" .. r)
			local idx = s.i + r - 1
			local upcoming = (s.phase ~= "done") and idx <= s.section.last and s.rows[idx] or nil
			if upcoming then
				rowAF:visible(true)
				local feet = {}
				for _, note in ipairs(upcoming.notes) do feet[note.col] = note.foot or "?" end
				for c = 1, #s.layout.cols do
					local note = rowAF:GetChild("Note" .. c)
					if feet[c] then
						note:visible(true)
						note:GetChild("Arrow"):diffuse(FootColor(feet[c])):diffusealpha(r == 1 and 1 or 0.75)
						note:GetChild("Letter"):settext(feet[c])
					else
						note:visible(false)
					end
				end
				rowAF:GetChild("Tag"):settext(upcoming.tags or "")
					:diffuse(upcoming.tech.doublestep and WarnColor or TechColor)
			else
				rowAF:visible(false)
			end
		end
		Lst:GetChild("Current"):visible(s.phase ~= "done")
	end

	local function DrawLane()
		local Ln = Drill():GetChild("Lane")
		local k = 0
		if s.phase == "drill" then
			for idx = s.i, s.section.last do
				local row = s.rows[idx]
				local y = s.receptorY + (row.time - s.clock) / s.rate * LANE_PX_PER_SEC
				if y > s.laneBottom then break end
				for _, note in ipairs(row.notes) do
					if k >= LANE_NOTES then break end
					k = k + 1
					local actor = Ln:GetChild("Note" .. k)
					-- the row you still owe sits on the line until you hit it
					actor:visible(true):xy(s.colX(note.col), math.max(y, s.receptorY))
					local pressed = (idx == s.i) and s.pressed[note.col]
					actor:GetChild("Arrow"):rotationz(ROTATION[s.layout.dirs[note.col]])
						:diffuse(pressed and Color.White or FootColor(note.foot))
					actor:GetChild("Letter"):settext(note.foot or "?")
				end
			end
		end
		for j = k + 1, LANE_NOTES do Ln:GetChild("Note" .. j):visible(false) end
		Ln:GetChild("Heading"):settext(s.frozen and "WAITING FOR YOUR STEP" or "THE LINE = NOW")
			:diffuse(s.frozen and TechColor or Color.White):diffusealpha(s.frozen and 1 or 0.7)
	end

	local function DrawProgress()
		local total = s.section.last - s.section.first + 1
		local done = math.min(total, s.i - s.section.first)
		Drill():GetChild("Progress"):settext(("%s   Step %d / %d   Mistakes: %d"):format(
			s.section.label, done, total, s.mistakes))
	end

	local function Redraw()
		DrawStep()
		if s.music then DrawLane() else DrawList() end
		DrawProgress()
	end

	-- -----------------------------------------------------------------------
	-- Flow

	local function BeginSection(index)
		StopAudio()
		s.section = s.sections[index]
		-- the clean-run streak counts repeats of the same section
		if s.streakKey ~= index then s.streak, s.streakKey = 0, index end
		s.i = s.section.first
		s.pressed, s.mistakes = {}, 0
		s.demoStart, s.frozen, s.stopAt = Now(), false, nil
		Drill():GetChild("Result"):visible(false)
		-- (visible() needs a real true/false; nil is an error in the game)
		Drill():GetChild("List"):visible(not s.music)
		Drill():GetChild("Lane"):visible(s.music == true)
		ShowPhase("drill")
		if s.music then
			s.clock = math.max(0, s.rows[s.i].time - PRE_ROLL * s.rate)
			StartAudio()
		end
		Redraw()
	end

	local function FinishSection()
		ShowPhase("done")
		local clean = (s.mistakes == 0)
		s.streak = clean and (s.streak or 0) + 1 or 0
		local text = clean and "Clean run!" or ("Done, " .. Plural(s.mistakes, "mistake"))
		if s.streak > 1 then text = text .. ("   (%d clean in a row)"):format(s.streak) end
		Drill():GetChild("Result"):visible(true):settext(text):diffuse(clean and GoodColor or TechColor)
		Drill():GetChild("Instruction"):settext(s.streak >= 3
			and "You've got this one. Try it in the song, or pick another section."
			or "Again until it's clean, then try it in the song.")
		Drill():GetChild("Help"):settext("")
		Play(SND_DONE)
		s.stopAt = Now() + 1.0   -- let the music ring out briefly
		Redraw()
	end

	local function CompleteRow()
		Play(SND_GOOD)
		s.i, s.pressed = s.i + 1, {}
		s.demoStart = Now()
		if s.i > s.section.last then FinishSection() return end
		if s.music and s.frozen then
			s.frozen = false
			StartAudio()
		end
		Redraw()
	end

	local function PressColumn(col)
		local row = s.rows[s.i]
		if s.music and not s.frozen and row.time - s.clock > EARLY_WINDOW * s.rate then
			return   -- far too early: ignore rather than punish
		end
		local needed = false
		for _, note in ipairs(row.notes) do
			if note.col == col then needed = true end
		end
		if not needed then
			s.mistakes = s.mistakes + 1
			s.pad.Flash(col, WarnColor)
			Play(SND_BAD)
			DrawProgress()
			return
		end
		s.pressed[col] = true
		for _, note in ipairs(row.notes) do
			if not s.pressed[note.col] then
				Redraw()   -- part of a jump/bracket; wait for the rest
				return
			end
		end
		CompleteRow()
	end

	local function Update()
		if s.phase == "loading" then
			s.job:Step()
			if s.job.err then
				Child("Status"):settext(s.job.err)
				ShowPhase("error")
			elseif s.job.result then
				s.Ready()
			end
			return
		end
		if s.stopAt and Now() >= s.stopAt then StopAudio(); s.stopAt = nil end
		if s.phase ~= "drill" then return end

		if s.music then
			if s.playing then s.clock = s.clockStart + (Now() - s.realStart) * s.rate end
			local row = s.rows[s.i]
			if not s.frozen and s.clock >= row.time then
				-- the step reached the line and hasn't been hit: wait for it
				s.clock = row.time
				StopAudio()
				s.frozen, s.demoStart = true, Now()
			end
			if s.frozen then
				DemoPose()
			else
				-- feet move in time with the music, landing as the arrow hits the line
				local before = s.rows[s.i - 1]
				local t0 = before and before.time or (row.time - 0.5)
				local span = math.max(0.05, math.min(row.time - t0, 0.6))
				local p = Clamp(1 - (row.time - s.clock) / span, 0, 1)
				PoseFeet(p, Clamp(p + 0.2, 0, 1))
			end
			DrawLane()
		else
			DemoPose()
		end
	end

	-- Returns true if the input was used.
	-- event.button is the physical button (a pad panel is "Left", "Down"...),
	-- event.GameButton is what it means in menus ("MenuUp", "Start", "Back"...).
	function s.Input(event)
		local panel, menuButton = event.button, event.GameButton
		local first = event.type == "InputEventType_FirstPress"
		local repeating = event.type == "InputEventType_Repeat"
		if not (first or repeating) then return false end

		if first and menuButton == "Back" and s.phase ~= "drill" and s.phase ~= "done" then
			LeaveScreen()   -- from the section list, or while loading / after an error
			return true
		end

		if s.phase == "menu" then
			if menuButton == "MenuUp" or panel == "Up" then
				s.menuIndex = math.max(1, s.menuIndex - 1); DrawMenu(); return true
			elseif menuButton == "MenuDown" or panel == "Down" then
				s.menuIndex = math.min(#s.sections, s.menuIndex + 1); DrawMenu(); return true
			elseif menuButton == "Start" and first then
				BeginSection(s.menuIndex); return true
			end
			return false
		end

		if s.phase == "drill" or s.phase == "done" then
			if not first then return false end
			if menuButton == "Back" then
				StopAudio(); s.stopAt = nil
				ShowPhase("menu"); DrawMenu(); return true
			elseif menuButton == "Start" then
				BeginSection(s.menuIndex); return true
			elseif s.phase == "drill" and BUTTON_COL[panel] then
				local col = BUTTON_COL[panel]
				if #s.layout.cols > 4 and event.controller == "GameController_2" then col = col + 4 end
				PressColumn(col)
				return true
			end
		end
		return false
	end

	function s.Ready()
		s.result = s.job.result
		s.rows = s.result.rows
		s.layout = s.result.layout
		s.sections = BuildSections(s.rows)
		s.menuIndex = math.min(2, #s.sections)   -- the first tricky section, if any
		s.holds = {}
		for _, row in ipairs(s.rows) do
			for _, note in ipairs(row.notes) do
				if note.endTime then
					s.holds[#s.holds+1] = { col = note.col, time = row.time, endTime = note.endTime, foot = note.foot }
				end
			end
		end
		SetupDrillLayout()
		ShowPhase("menu")
		DrawMenu()
	end

	af.ModuleCommand = function(self)
		s.af = self
		s.phase, s.result, s.streak, s.playing, s.stopAt, s.leaving = nil, nil, 0, false, nil, false
		panels[pnShort] = nil
		if not GAMESTATE:IsHumanPlayer(pn) then self:visible(false) return end
		panels[pnShort] = s

		-- One trainer fills the screen; two share it side by side.
		local humans = #GAMESTATE:GetHumanPlayers()
		local areaW = humans > 1 and SCREEN_WIDTH / 2 or SCREEN_WIDTH
		local zoom = math.min(1, (areaW - 10) / W, (SCREEN_HEIGHT - 20) / H)
		local x = humans > 1 and (pn == PLAYER_1 and SCREEN_WIDTH * 0.25 or SCREEN_WIDTH * 0.75) or _screen.cx
		self:visible(true):xy(x, (SCREEN_HEIGHT - H * zoom) / 2):zoom(zoom)

		local song, steps = GAMESTATE:GetCurrentSong(), GAMESTATE:GetCurrentSteps(pn)
		local chart = ""
		if song and steps then
			local diff = ToEnumShortString(steps:GetDifficulty())
			local ok, name = pcall(function() return THEME:GetString("Difficulty", diff) end)
			chart = song:GetDisplayFullTitle() .. "  -  " .. (ok and name or diff) .. " " .. steps:GetMeter()
		end
		Child("Chart"):settext(chart)

		-- Practice always plays the song (at the player's chosen Music Rate). Only
		-- a song with no music file falls back to waiting at every step.
		s.musicPath = song and song.GetMusicPath and song:GetMusicPath() or nil
		local okRate, rate = pcall(function() return GAMESTATE:GetSongOptionsObject("ModsLevel_Preferred"):MusicRate() end)
		s.rate = (okRate and type(rate) == "number" and rate > 0) and rate or 1
		s.music = s.musicPath ~= nil and s.musicPath ~= ""

		s.job = StartAnalysis(pn)
		if s.job.err then
			Child("Status"):settext(s.job.err)
			ShowPhase("error")
		elseif s.job.result then
			s.Ready()
		else
			Child("Status"):settext("Analyzing chart...")
			ShowPhase("loading")
		end
		self:SetUpdateFunction(Update)
	end

	af.ScreenChangedMessageCommand = function(self)
		local screen = SCREENMAN:GetTopScreen()
		if not (screen and screen:GetName() == "ScreenFootGuideTrainer") then
			StopAudio()
			s.phase, s.stopAt = nil, nil
		end
	end

	return af
end

-- ---------------------------------------------------------------------------

local function RouteInput(event)
	if not event or not (event.GameButton or event.button) then return false end
	local target
	local style = GAMESTATE:GetCurrentStyle()
	if style and style:GetStyleType() == "StyleType_OnePlayerTwoSides" then
		-- doubles: both pads belong to the one player
		local humans = GAMESTATE:GetHumanPlayers()
		target = humans[1] and panels[ToEnumShortString(humans[1])]
	elseif event.PlayerNumber then
		target = panels[ToEnumShortString(event.PlayerNumber)]
	end
	if target and target.Input then return target.Input(event) end
	return false
end

local listeningOn = nil
return Def.ActorFrame{
	ModuleCommand = function(self)
		local screen = SCREENMAN:GetTopScreen()
		if screen and screen ~= listeningOn then
			listeningOn = screen
			screen:AddInputCallback(RouteInput)
		end
	end,
	TrainerPanel(PLAYER_1),
	TrainerPanel(PLAYER_2),
}
