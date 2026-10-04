-- FootGuide: a Simply Love module that suggests which foot to use for each
-- arrow. Each player picks a mode in Player Options ("Foot Guide"):
--   On Notes    - an L/R badge rides on every arrow in your notefield
--   Tricky Only - badges only around crossovers, footswitches, brackets...
--   Side Panel  - a pad diagram + scrolling L/R lane beside the notefield
--   Trainer     - a step-by-step practice screen instead of playing the song
--
-- Install with install.ps1 (see README.md).

-- ---------------------------------------------------------------------------
-- Settings (edit these to taste)

local Config = {
	-- Set to false to unload the module completely. The per-player mode is
	-- chosen in Player Options; the default for new players is in
	-- Scripts/FootGuide-Settings.lua.
	Enabled        = true,
	LeftColor      = "#33aaff",
	RightColor     = "#ff7043",

	-- On Notes / Tricky Only
	BadgeSize      = 30,     -- badge diameter in pixels at 0% Mini
	BadgeOpacity   = 0.9,
	TrickyLeadIn   = 2,      -- Tricky Only also marks this many steps before each tricky step

	-- Pad diagrams (side panel and trainer)
	ShowBody       = true,   -- see-through legs, hips and head showing how the body turns

	-- Side Panel
	Side           = "auto", -- "auto", "left" or "right" of the notefield
	LookAhead      = 2.0,    -- seconds of upcoming steps shown in the lane
	ShowPad        = true,
	ShowLane       = true,
	ShowTechLabels = true,   -- XO crossover, FS footswitch, BR bracket, DS doublestep
	ShowSummary    = true,
}

-- ---------------------------------------------------------------------------

if not Config.Enabled then return {} end

local MODULE_DIR = THEME:GetCurrentThemeDirectory() .. "Modules/FootGuide/"

local function LoadPart(name)
	local chunk, err = loadfile(MODULE_DIR .. name)
	if not chunk then
		lua.ReportScriptError("FootGuide: could not load " .. name .. ": " .. tostring(err))
	end
	return chunk
end

local Solver = LoadPart("Solver.lua")
if not Solver then return {} end
Solver = Solver()

if not FootGuideSettings then
	lua.ReportScriptError("FootGuide: Scripts/FootGuide-Settings.lua is missing; re-run install.ps1")
	return {}
end

local LeftColor  = color(Config.LeftColor)
local RightColor = color(Config.RightColor)
local Gray       = color("#5a5a5a")
local DimPanel   = color("#1e1e1e")
local TechColor  = color("#ffd54f")
local WarnColor  = color("#ff5252")

local MAX_PANELS = 8
local ROTATION = { Left = -90, Down = 180, Up = 0, Right = 90 }   -- arrows are drawn pointing up

local function FootColor(foot)
	if foot == "L" then return LeftColor end
	if foot == "R" then return RightColor end
	return Gray
end

local function StepsTypeName(stepsType)
	return ToEnumShortString(stepsType):gsub("_", "-"):lower()
end

-- ---------------------------------------------------------------------------
-- Chart loading + analysis (shared by gameplay and the trainer)

local cache = {}   -- solved charts, so restarts and the trainer are instant

local function ReadFile(path)
	local f = RageFileUtil.CreateRageFile()
	local contents
	if f:Open(path, 1) then contents = f:Read() end
	f:destroy()
	return contents
end

local function NormalizeDifficulty(d)
	local ok, diff = pcall(function() return ToEnumShortString(OldStyleStringToDifficulty(d)) end)
	return ok and diff or d
end

-- Column remapping for turn mods. Returns a table (original col -> displayed
-- col), or false if the turn can't be predicted (shuffles, rotations).
local function TurnMapping(pn, numCols)
	local ps = GAMESTATE:GetPlayerState(pn)
	local mods = ps:GetPlayerOptionsString("ModsLevel_Preferred"):lower()
	local tokens = {}
	for token in mods:gmatch("[^,]+") do tokens[token:gsub("^%s+", ""):gsub("%s+$", "")] = true end
	local function pad(map)
		-- extend a 4-panel mapping to doubles (each pad mapped the same way)
		local out = {}
		for c = 1, numCols do
			local base = math.floor((c - 1) / 4) * 4
			out[c] = base + map[(c - 1) % 4 + 1]
		end
		return out
	end
	if tokens["shuffle"] or tokens["softshuffle"] or tokens["supershuffle"] or tokens["hypershuffle"]
	or tokens["left"] or tokens["right"] or tokens["backwards"] then
		return false
	end
	if tokens["mirror"] then
		local out = {}
		for c = 1, numCols do out[c] = numCols + 1 - c end
		return out
	end
	if (tokens["lrmirror"] or tokens["udmirror"]) and numCols ~= 4 then return false end
	if tokens["lrmirror"] then return pad({ 4, 2, 3, 1 }) end
	if tokens["udmirror"] then return pad({ 1, 3, 2, 4 }) end
	return pad({ 1, 2, 3, 4 })
end

local function InRanges(beat, ranges)
	for _, r in ipairs(ranges) do
		if beat >= r[1] - 1e-4 and beat < r[1] + r[2] - 1e-4 then return true end
	end
	return false
end

local TECHS = {
	{ key = "crossover",  tag = "XO",   name = "crossover",  weight = 3 },
	{ key = "spin",       tag = "SPIN", name = "spin",       weight = 4 },
	{ key = "footswitch", tag = "FS",   name = "footswitch", weight = 3 },
	{ key = "bracket",    tag = "BR",   name = "bracket",    weight = 2 },
	{ key = "doublestep", tag = "DS",   name = "doublestep", weight = 4 },
}

local function TechTags(tech)
	local t = {}
	for _, def in ipairs(TECHS) do
		if tech[def.key] then t[#t+1] = def.tag end
	end
	return table.concat(t, " ")
end

-- Extra per-row info used by "Tricky Only" and the trainer.
local function Annotate(result)
	local rows = result.rows
	for i, row in ipairs(rows) do
		local tags = TechTags(row.tech)
		row.tags = tags ~= "" and tags or nil
		if row.tags then
			for j = math.max(1, i - Config.TrickyLeadIn), i do rows[j].tricky = true end
		end
	end
end

-- Returns rows ready for Solver.Solve plus layout name and cache key,
-- or a cached result, or nil + reason.
local function LoadRows(pn)
	local steps = GAMESTATE:GetCurrentSteps(pn)
	if not steps then return nil, "No chart" end
	local stepsType = StepsTypeName(steps:GetStepsType())
	local layout = Solver.Layouts[stepsType]
	if not layout then return nil, "Only dance singles/doubles are supported" end

	local filename = steps:GetFilename()
	local filetype = (filename or ""):match("[^.]+$")
	filetype = filetype and filetype:lower()
	if filetype ~= "ssc" and filetype ~= "sm" then return nil, "Unsupported simfile type" end

	local mapping = TurnMapping(pn, #layout.cols)
	if not mapping then return nil, "Not available with this turn mod" end

	local key = table.concat({ filename, stepsType, ToEnumShortString(steps:GetDifficulty()),
		steps:GetDescription(), table.concat(mapping, "") }, "|")
	if cache[key] then return cache[key], stepsType, key end

	local text = ReadFile(filename)
	local noteData = Solver.ExtractNoteData(text, filetype, stepsType,
		ToEnumShortString(steps:GetDifficulty()), steps:GetDescription(), NormalizeDifficulty)
	if not noteData then return nil, "Could not read chart" end

	local timing = steps:GetTimingData()
	local warps = timing:GetWarps(true) or {}
	local fakes = timing:GetFakes(true) or {}

	local notes = {}
	for _, note in ipairs(Solver.ParseNotes(noteData, #layout.cols)) do
		if not InRanges(note.beat, warps) and not InRanges(note.beat, fakes) then
			note.col = mapping[note.col]
			note.time = timing:GetElapsedTimeFromBeat(note.beat)
			if note.endBeat then note.endTime = timing:GetElapsedTimeFromBeat(note.endBeat) end
			notes[#notes+1] = note
		end
	end
	table.sort(notes, function(a, b)
		if a.beat ~= b.beat then return a.beat < b.beat end
		return a.col < b.col
	end)
	return Solver.BuildRows(notes), stepsType, key
end

-- Starts analysing a player's chart. Call job:Step() once per frame until
-- job.result (success) or job.err (failure) is set.
local function StartAnalysis(pn)
	local job = {}
	local ok, rows, layoutName, key = pcall(LoadRows, pn)
	if not ok then
		lua.ReportScriptError("FootGuide: " .. tostring(rows))
		job.err = "Analysis failed"
	elseif not rows then
		job.err = layoutName
	elseif rows.rows then
		job.result, job.layoutName = rows, layoutName
	else
		job.layoutName = layoutName
		job.co = coroutine.create(function()
			local result = Solver.Solve(rows, layoutName, coroutine.yield)
			Annotate(result)
			cache[key] = result
			return result
		end)
	end
	function job:Step()
		if not self.co then return end
		local resumed, res = coroutine.resume(self.co)
		if not resumed then
			lua.ReportScriptError("FootGuide: " .. tostring(res))
			self.co, self.err = nil, "Analysis failed"
		elseif coroutine.status(self.co) == "dead" then
			self.co, self.result = nil, res
		end
	end
	return job
end

-- ---------------------------------------------------------------------------
-- Drawing helpers

-- An arrow pointing up, centred on 0,0, about `size` pixels tall.
local function Arrow(size, name)
	local h = size / 2
	local verts = {}
	local function tri(a, b, c)
		verts[#verts+1] = { { a[1], a[2], 0 }, Color.White }
		verts[#verts+1] = { { b[1], b[2], 0 }, Color.White }
		verts[#verts+1] = { { c[1], c[2], 0 }, Color.White }
	end
	tri({ 0, -h }, { -h, 0 }, { h, 0 })            -- head
	local w = h * 0.42
	tri({ -w, 0 }, { w, 0 }, { -w, h })            -- shaft
	tri({ w, 0 }, { w, h }, { -w, h })
	return Def.ActorMultiVertex{
		Name = name,
		InitCommand = function(self)
			self:SetDrawState({ Mode = "DrawMode_Triangles" }):SetVertices(verts)
		end,
	}
end

-- A filled circle of the given diameter.
local function Disc(size, name)
	local verts = { { { 0, 0, 0 }, Color.White } }
	for i = 0, 24 do
		local a = i / 24 * 2 * math.pi
		verts[#verts+1] = { { math.cos(a) * size / 2, math.sin(a) * size / 2, 0 }, Color.White }
	end
	return Def.ActorMultiVertex{
		Name = name,
		InitCommand = function(self)
			self:SetDrawState({ Mode = "DrawMode_Fan" }):SetVertices(verts)
		end,
	}
end

-- A footprint marker with a letter on it.
local function Foot(name, letter, col)
	return Def.ActorFrame{
		Name = name,
		Def.Quad{ Name = "Sole", InitCommand = function(self) self:diffuse(col) end },
		Def.Quad{ Name = "Toe", InitCommand = function(self) self:diffuse(col) end },
		Def.BitmapText{
			Font = "Common Normal", Text = letter, Name = "Letter",
			InitCommand = function(self) self:zoom(0.9):diffuse(Color.Black) end,
		},
	}
end

-- A dance pad diagram: panels + current feet + "ghost" feet for the next step.
-- `extra` actors (optional) are drawn above the panels but under the feet.
local function PadDef(name, extra)
	local pad = Def.ActorFrame{ Name = name }
	for i = 1, MAX_PANELS do
		pad[#pad+1] = Def.ActorFrame{
			Name = "Panel" .. i,
			Def.Quad{ Name = "Base" },
			Def.Quad{ Name = "Glow" },
			Arrow(20, "Arrow"),
		}
	end
	for _, actor in ipairs(extra or {}) do pad[#pad+1] = actor end
	-- A see-through body seen from above: legs from the hips to each foot,
	-- shoulders, head and a small arrow showing which way the body faces.
	pad[#pad+1] = Def.ActorFrame{
		Name = "Body",
		Def.Quad{ Name = "LegBack" },     -- the leg further back
		Disc(100, "Torso"),
		Def.Quad{ Name = "LegFront" },    -- the leg further forward, drawn on top
		Disc(100, "Head"),
		Arrow(20, "Nose"),
	}
	pad[#pad+1] = Foot("GhostL", "L", LeftColor)
	pad[#pad+1] = Foot("GhostR", "R", RightColor)
	pad[#pad+1] = Foot("FootL", "L", LeftColor)
	pad[#pad+1] = Foot("FootR", "R", RightColor)
	return pad
end

-- Sizes a PadDef for a layout. Returns a controller used to draw feet.
local function SetupPad(padAF, layout, panelSize, top)
	local n = #layout.cols
	local maxX = 0
	for _, c in ipairs(layout.cols) do maxX = math.max(maxX, c[1]) end
	local pad = { af = padAF, layout = layout }
	function pad.pos(x, y)
		return (x - maxX / 2) * panelSize, top + (2 - y) * panelSize + panelSize / 2
	end
	for i = 1, MAX_PANELS do
		local panel = padAF:GetChild("Panel" .. i)
		if i <= n then
			local px, py = pad.pos(layout.cols[i][1], layout.cols[i][2])
			panel:visible(true):xy(px, py)
			panel:GetChild("Base"):zoomto(panelSize - 3, panelSize - 3):diffuse(DimPanel)
			panel:GetChild("Glow"):zoomto(panelSize - 3, panelSize - 3):diffuse(Gray):diffusealpha(0)
			panel:GetChild("Arrow"):rotationz(ROTATION[layout.dirs[i]]):zoom(panelSize / 34):diffuse(0.45, 0.45, 0.45, 1)
		else
			panel:visible(false)
		end
	end
	for _, footName in ipairs({ "FootL", "FootR", "GhostL", "GhostR" }) do
		local foot = padAF:GetChild(footName)
		foot:GetChild("Sole"):zoomto(panelSize * 0.42, panelSize * 0.5):y(panelSize * 0.1)
		foot:GetChild("Toe"):zoomto(panelSize * 0.32, panelSize * 0.3):y(-panelSize * 0.22)
		foot:GetChild("Letter"):y(panelSize * 0.05):zoom(panelSize / 48)
	end

	-- Pixel position and rotation of a foot placement on this pad.
	function pad.Where(placement)
		local px, py = pad.pos(placement.x, placement.y)
		local rot = 0
		if placement.kind == "bracket" then
			local a, b = layout.cols[placement.cols[1]], layout.cols[placement.cols[2]]
			-- heel on the lower panel, toe on the upper one
			local dx, dy = b[1] - a[1], b[2] - a[2]
			if dy < 0 then dx, dy = -dx, -dy end
			rot = math.deg((math.atan2 or math.atan)(dx, dy))
		end
		return px, py, rot
	end

	-- Draws the body for feet at pixel positions (xL,yL) and (xR,yR), facing
	-- `deg` degrees (0 = the screen, negative = turned to the player's right).
	local body = padAF:GetChild("Body")
	body:visible(false)
	function pad.DrawBody(xL, yL, xR, yR, deg)
		if not Config.ShowBody or not deg then body:visible(false) return end
		body:visible(true)
		local a = math.rad(deg)
		local fx, fy = -math.sin(a), -math.cos(a)   -- facing (screen pixels, y down)
		local rx, ry = math.cos(a), -math.sin(a)    -- the body's right-hand side
		local px, py = (xL + xR) / 2, (yL + yR) / 2
		local hip = 0.24 * panelSize
		local atan2 = math.atan2 or math.atan

		local function Leg(actor, hx, hy, x, y, col, alpha)
			local dx, dy = x - hx, y - hy
			local len = math.sqrt(dx * dx + dy * dy)
			actor:xy((hx + x) / 2, (hy + y) / 2):zoomto(0.24 * panelSize, math.max(1, len))
				:rotationz(math.deg(atan2(dy, dx)) - 90):diffuse(col):diffusealpha(alpha)
		end
		-- whichever foot is further forward (in the facing direction) is the front leg
		local leftForward = (xL - px) * fx + (yL - py) * fy >= (xR - px) * fx + (yR - py) * fy
		local frontIsLeft = leftForward
		local lhx, lhy = px - rx * hip, py - ry * hip
		local rhx, rhy = px + rx * hip, py + ry * hip
		if frontIsLeft then
			Leg(body:GetChild("LegFront"), lhx, lhy, xL, yL, LeftColor, 0.75)
			Leg(body:GetChild("LegBack"), rhx, rhy, xR, yR, RightColor, 0.4)
		else
			Leg(body:GetChild("LegFront"), rhx, rhy, xR, yR, RightColor, 0.75)
			Leg(body:GetChild("LegBack"), lhx, lhy, xL, yL, LeftColor, 0.4)
		end
		body:GetChild("Torso"):xy(px, py):rotationz(math.deg(atan2(ry, rx)))
			:zoomx(0.95 * panelSize / 100):zoomy(0.4 * panelSize / 100):diffuse(1, 1, 1, 0.35)
		body:GetChild("Head"):xy(px + fx * 0.04 * panelSize, py + fy * 0.04 * panelSize)
			:zoom(0.34 * panelSize / 100):diffuse(1, 1, 1, 0.6)
		body:GetChild("Nose"):xy(px + fx * 0.36 * panelSize, py + fy * 0.36 * panelSize)
			:rotationz(math.deg(atan2(fy, fx)) + 90):zoom(panelSize / 55):diffuse(1, 1, 1, 0.9)
	end

	local function Place(actor, placement, animate, alpha)
		if not placement then actor:visible(false) return end
		local px, py, rot = pad.Where(placement)
		actor:visible(true)
		if animate then actor:stoptweening():decelerate(0.08) end
		actor:xy(px, py):rotationz(rot)
		actor:diffusealpha(alpha or (placement.kind == "float" and 0.45 or 1))
	end

	-- L/R: where the feet are now. nextRow: the step to show as ghost feet +
	-- glowing panels. pressed: optional { [col] = true } drawn in white.
	-- facing: body direction in degrees (draws the body), or nil.
	function pad.Show(L, R, nextRow, animate, pressed, facing)
		Place(padAF:GetChild("FootL"), L, animate)
		Place(padAF:GetChild("FootR"), R, animate)
		if L and R then
			local xL, yL = pad.Where(L)
			local xR, yR = pad.Where(R)
			pad.DrawBody(xL, yL, xR, yR, facing)
		else
			pad.DrawBody(0, 0, 0, 0, nil)
		end
		Place(padAF:GetChild("GhostL"), nextRow and nextRow.movedL and nextRow.L or nil, false, 0.35)
		Place(padAF:GetChild("GhostR"), nextRow and nextRow.movedR and nextRow.R or nil, false, 0.35)
		local glow = {}
		if nextRow then
			for _, note in ipairs(nextRow.notes) do glow[note.col] = note.foot end
		end
		for i = 1, n do
			local g = padAF:GetChild("Panel" .. i):GetChild("Glow")
			g:stoptweening()
			if pressed and pressed[i] then g:diffuse(Color.White):diffusealpha(0.7)
			elseif glow[i] then g:diffuse(FootColor(glow[i])):diffusealpha(0.5)
			else g:diffusealpha(0) end
		end
	end

	-- Brief red/white flash on a panel (trainer feedback).
	function pad.Flash(col, c)
		if col < 1 or col > n then return end
		padAF:GetChild("Panel" .. col):GetChild("Glow"):stoptweening():diffuse(c):diffusealpha(0.85)
			:linear(0.25):diffusealpha(0)
	end
	return pad
end

-- ---------------------------------------------------------------------------
-- Gameplay: one overlay per player (badges on notes, or the side panel)

local MAX_BADGES = 48
local MAX_NOTES  = 72   -- side panel lane arrows
local MAX_HOLDS  = 16
local MAX_LABELS = 16

local function GameplayOverlay(pn)
	local s = {}   -- runtime state for this player
	local pnShort = ToEnumShortString(pn)

	local af = Def.ActorFrame{
		Name = "FootGuide" .. pnShort,
		InitCommand = function(self) self:visible(false) end,
	}

	-- Badges that ride on the notefield's arrows (screen coordinates).
	local badges = Def.ActorFrame{ Name = "Badges" }
	for i = 1, MAX_BADGES do
		badges[#badges+1] = Def.ActorFrame{
			Name = "Badge" .. i,
			InitCommand = function(self) self:visible(false) end,
			Disc(Config.BadgeSize + 4, "Ring"),
			Disc(Config.BadgeSize, "Fill"),
			Def.BitmapText{
				Font = "Common Bold", Name = "Letter",
				InitCommand = function(self) self:zoom(Config.BadgeSize / 44):diffuse(Color.Black) end,
			},
			Def.BitmapText{
				Font = "Common Bold", Name = "Tag",
				InitCommand = function(self)
					self:zoom(Config.BadgeSize / 64):diffuse(TechColor):shadowlength(1)
						:halign(0):x(Config.BadgeSize / 2 + 3)
				end,
			},
		}
	end
	af[#af+1] = badges

	-- Side panel (positioned beside the notefield).
	local panel = Def.ActorFrame{ Name = "Panel" }
	panel[#panel+1] = Def.Quad{ Name = "Bg", InitCommand = function(self) self:diffuse(0, 0, 0, 0.72) end }
	panel[#panel+1] = Def.BitmapText{
		Font = "Common Normal", Name = "Title", Text = "FOOT GUIDE",
		InitCommand = function(self) self:zoom(0.7):diffusealpha(0.8) end,
	}
	panel[#panel+1] = Def.BitmapText{
		Font = "Common Normal", Name = "Status",
		InitCommand = function(self) self:zoom(0.65):wrapwidthpixels(220) end,
	}
	panel[#panel+1] = PadDef("Pad")
	local lane = Def.ActorFrame{ Name = "Lane" }
	lane[#lane+1] = Def.Quad{ Name = "LaneBg", InitCommand = function(self) self:diffuse(1, 1, 1, 0.04) end }
	for i = 1, MAX_HOLDS do lane[#lane+1] = Def.Quad{ Name = "Hold" .. i } end
	for i = 1, MAX_PANELS do lane[#lane+1] = Arrow(22, "Receptor" .. i) end
	for i = 1, MAX_NOTES do
		lane[#lane+1] = Def.ActorFrame{
			Name = "Note" .. i,
			Arrow(22, "Arrow"),
			Def.BitmapText{
				Font = "Common Normal", Name = "Letter",
				InitCommand = function(self) self:zoom(0.55):diffuse(Color.Black) end,
			},
		}
	end
	for i = 1, MAX_LABELS do
		lane[#lane+1] = Def.BitmapText{
			Font = "Common Normal", Name = "Label" .. i,
			InitCommand = function(self) self:zoom(0.5):halign(0) end,
		}
	end
	panel[#panel+1] = lane
	panel[#panel+1] = Def.BitmapText{
		Font = "Common Normal", Name = "Summary",
		InitCommand = function(self) self:zoom(0.55):diffusealpha(0.85):vertspacing(-4) end,
	}
	af[#af+1] = panel

	-- -----------------------------------------------------------------------
	-- Side panel layout + drawing

	local function LayoutPanel(P, layoutName)
		local layout = Solver.Layouts[layoutName]
		local n = #layout.cols
		local double = n > 4
		s.layout = layout

		local panelSize = double and 26 or 38
		local colWidth  = double and 21 or 30
		local width     = math.max(double and 3 * 2 * panelSize or 3 * panelSize, n * colWidth) + 24

		local titleY  = 10
		local padTop  = Config.ShowPad and (titleY + 14) or titleY
		local padH    = Config.ShowPad and 3 * panelSize or 0
		local laneTop = padTop + padH + 14
		local bottom  = SCREEN_HEIGHT - 110
		local laneH   = Config.ShowLane and math.max(80, bottom - laneTop - (Config.ShowSummary and 30 or 6)) or 0
		local height  = laneTop + laneH + (Config.ShowSummary and 30 or 6)

		s.colWidth = colWidth
		P:GetChild("Bg"):zoomto(width, height):valign(0):y(0)
		P:GetChild("Title"):y(titleY)
		P:GetChild("Status"):y(laneTop + 30):visible(false)

		P:GetChild("Pad"):visible(Config.ShowPad)
		s.pad = SetupPad(P:GetChild("Pad"), layout, panelSize, padTop)

		local laneAF = P:GetChild("Lane")
		laneAF:visible(Config.ShowLane)
		s.reverse = GAMESTATE:GetPlayerState(pn):GetPlayerOptions("ModsLevel_Preferred"):UsingReverse()
		s.receptorY = s.reverse and (laneTop + laneH - 16) or (laneTop + 16)
		s.pxPerSec = (laneH - 32) / Config.LookAhead
		s.colX = function(c) return (c - (n + 1) / 2) * colWidth end
		laneAF:GetChild("LaneBg"):zoomto(n * colWidth + 8, laneH):valign(0):y(laneTop)
		for i = 1, MAX_PANELS do
			local r = laneAF:GetChild("Receptor" .. i)
			if i <= n then
				r:visible(true):xy(s.colX(i), s.receptorY):rotationz(ROTATION[layout.dirs[i]])
					:zoom(colWidth / 30):diffuse(1, 1, 1, 0.25)
			else
				r:visible(false)
			end
		end
		for i = 1, MAX_NOTES do laneAF:GetChild("Note" .. i):visible(false):zoom(colWidth / 30) end
		for i = 1, MAX_HOLDS do laneAF:GetChild("Hold" .. i):visible(false) end
		for i = 1, MAX_LABELS do laneAF:GetChild("Label" .. i):visible(false) end

		P:GetChild("Summary"):y(laneTop + laneH + 15):visible(Config.ShowSummary):settext("")

		-- Where on screen does the panel go?
		local nfx = GetNotefieldX(pn) or _screen.cx
		local mini = tonumber((tostring(SL[pnShort].ActiveModifiers.Mini or "0"):gsub("%%", ""))) or 0
		local nfw = (GetNotefieldWidth() or 256) * (1 - mini / 200)
		local centered = math.abs(nfx - _screen.cx) < 1
		local side = Config.Side
		if side ~= "left" and side ~= "right" then
			if GAMESTATE:GetNumPlayersEnabled() > 1 then
				side = (pn == PLAYER_1) and "left" or "right"
			elseif centered then
				side = "left" -- Step Statistics, if enabled, goes on the right
			elseif SL[pnShort].ActiveModifiers.DataVisualizations == "Step Statistics" then
				side = (pn == PLAYER_1) and "left" or "right"
			else
				side = (pn == PLAYER_1) and "right" or "left"
			end
		end
		local gap = 12
		local avail = (side == "left") and (nfx - nfw / 2 - 2 * gap) or (SCREEN_WIDTH - (nfx + nfw / 2) - 2 * gap)
		local zoom = math.min(1, math.max(0.4, avail / width))
		local x = (side == "left")
			and (nfx - nfw / 2 - gap - width * zoom / 2)
			or  (nfx + nfw / 2 + gap + width * zoom / 2)
		P:xy(x, 86):zoom(zoom)
	end

	local function UpdatePanelPad(rows, cur)
		if s.shownRow == cur then return end
		s.shownRow = cur
		local row = rows[cur]
		s.pad.Show(row and row.L or s.result.startL, row and row.R or s.result.startR, rows[cur + 1], true, nil,
			row and row.facing or s.result.startFacing)
	end

	local function UpdateLane(P, rows, now)
		local laneAF = P:GetChild("Lane")
		local dir = s.reverse and -1 or 1
		local yFor = function(t) return s.receptorY + dir * (t - now) * s.pxPerSec end
		local horizon = now + Config.LookAhead

		local h = 0
		for _, hold in ipairs(s.holds) do
			if h >= MAX_HOLDS or hold.time > horizon then break end
			if hold.endTime > now then
				h = h + 1
				local y1 = yFor(math.max(hold.time, now))
				local y2 = yFor(math.min(hold.endTime, horizon))
				laneAF:GetChild("Hold" .. h):visible(true)
					:xy(s.colX(hold.col), (y1 + y2) / 2)
					:zoomto(s.colWidth * 0.45, math.abs(y2 - y1))
					:diffuse(FootColor(hold.foot)):diffusealpha(0.45)
			end
		end
		for i = h + 1, MAX_HOLDS do laneAF:GetChild("Hold" .. i):visible(false) end

		local k, lbl = 0, 0
		local i = s.laneStart
		while rows[i] and rows[i].time < now - 0.15 do i = i + 1 end
		s.laneStart = i
		local rightEdge = s.colX(#s.layout.cols) + s.colWidth / 2 + 2
		while rows[i] and rows[i].time <= horizon and k < MAX_NOTES do
			local row = rows[i]
			local y = yFor(row.time)
			local alpha = row.time < now and 0.3 or 1
			for _, note in ipairs(row.notes) do
				if k >= MAX_NOTES then break end
				k = k + 1
				local actor = laneAF:GetChild("Note" .. k)
				actor:visible(true):xy(s.colX(note.col), y)
				actor:GetChild("Arrow"):rotationz(ROTATION[s.layout.dirs[note.col]])
					:diffuse(FootColor(note.foot)):diffusealpha(alpha)
				actor:GetChild("Letter"):settext(note.foot or "?"):diffusealpha(alpha)
			end
			if Config.ShowTechLabels and row.tags and lbl < MAX_LABELS then
				lbl = lbl + 1
				laneAF:GetChild("Label" .. lbl):visible(true):xy(rightEdge, y):settext(row.tags)
					:diffuse(row.tech.doublestep and WarnColor or TechColor):diffusealpha(alpha)
			end
			i = i + 1
		end
		for j = k + 1, MAX_NOTES do laneAF:GetChild("Note" .. j):visible(false) end
		for j = lbl + 1, MAX_LABELS do laneAF:GetChild("Label" .. j):visible(false) end
	end

	-- -----------------------------------------------------------------------
	-- Badges on the real notefield

	-- Is ArrowEffects' column argument 1-based (offset 0) or 0-based (-1)?
	-- Checked once: with no effects active, columns sit symmetrically about 0.
	local function ColumnOffset(ps, n)
		local function symmetric(first, last)
			local ok1, a = pcall(ArrowEffects.GetXPos, ps, first, 0)
			local ok2, b = pcall(ArrowEffects.GetXPos, ps, last, 0)
			return ok1 and ok2 and type(a) == "number" and type(b) == "number"
				and math.abs(a + b) < 2 and math.abs(a - b) > 1
		end
		if symmetric(1, n) then return 0 end
		if symmetric(0, n - 1) then return -1 end
		return 0
	end

	local function SetupBadges(self)
		s.badgesOK = false
		local screen = SCREENMAN:GetTopScreen()
		local playerAF = screen and screen:GetChild("Player" .. pnShort)
		local nf = playerAF and playerAF:GetChild("NoteField")
		if not (nf and ArrowEffects and ArrowEffects.GetYOffset) then return false end
		-- Tilted/skewed perspectives draw the notefield in 3D; we can't follow that.
		local po = GAMESTATE:GetPlayerState(pn):GetPlayerOptions("ModsLevel_Preferred")
		local tilt, skew = po:Tilt(), po:Skew()
		if math.abs(tilt or 0) > 0.01 or math.abs(skew or 0) > 0.01 then return false end
		s.playerAF, s.nf = playerAF, nf
		s.ps = GAMESTATE:GetPlayerState(pn)
		s.colOffset = ColumnOffset(s.ps, #Solver.Layouts[s.layoutName].cols)
		local mini = tonumber((tostring(SL[pnShort].ActiveModifiers.Mini or "0"):gsub("%%", ""))) or 0
		s.miniZoom = 1 - mini / 200
		s.badgeStart = 1
		s.badgesOK = true
		return true
	end

	local function UpdateBadges(B, rows, now)
		local nf, pAF, ps = s.nf, s.playerAF, s.ps
		local px, py, pz = pAF:GetX(), pAF:GetY(), pAF:GetZoom()
		local nx, ny, nz = nf:GetX(), nf:GetY(), nf:GetZoom()
		-- Mini normally zooms the NoteField actor; if it doesn't here, apply it ourselves.
		if math.abs(nz - 1) < 1e-3 then nz = s.miniZoom end
		local zoom = pz * nz
		local limit = (SCREEN_HEIGHT + 2 * Config.BadgeSize) / math.max(zoom, 0.1)
		local onlyTricky = (s.mode == "tricky")

		local i = s.badgeStart
		while rows[i] and rows[i].time < now - 0.03 do i = i + 1 end
		s.badgeStart = i

		local k = 0
		while rows[i] and k < MAX_BADGES do
			local row = rows[i]
			local stop = false
			if not onlyTricky or row.tricky then
				for idx, note in ipairs(row.notes) do
					if k >= MAX_BADGES then break end
					local col = note.col + s.colOffset
					local yOff = ArrowEffects.GetYOffset(ps, col, row.beat)
					if yOff > limit then stop = true break end
					local x = ArrowEffects.GetXPos(ps, col, yOff)
					local y = ArrowEffects.GetYPos(ps, col, yOff)
					local alpha = 1
					if s.alphaOK ~= false then
						local ok, a = pcall(ArrowEffects.GetAlpha, ps, col, yOff)
						if ok and type(a) == "number" then alpha = math.max(0, math.min(1, a))
						else s.alphaOK = false end
					end
					k = k + 1
					local badge = B:GetChild("Badge" .. k)
					badge:visible(alpha > 0.02)
						:xy(px + pz * (nx + nz * x), py + pz * (ny + nz * y))
						:zoom(zoom):diffusealpha(alpha * Config.BadgeOpacity)
					badge:GetChild("Fill"):diffuse(FootColor(note.foot))
					badge:GetChild("Ring"):diffuse(row.tags and TechColor or Color.Black)
					badge:GetChild("Letter"):settext(note.foot or "?")
					-- technique tag once per row, next to its last arrow
					badge:GetChild("Tag"):settext((idx == #row.notes and row.tags) or "")
						:diffuse(row.tech.doublestep and WarnColor or TechColor)
				end
			else
				-- still need to know when we're past the screen
				local yOff = ArrowEffects.GetYOffset(ps, row.notes[1].col + s.colOffset, row.beat)
				if yOff > limit then stop = true end
			end
			if stop then break end
			i = i + 1
		end
		for j = k + 1, MAX_BADGES do B:GetChild("Badge" .. j):visible(false) end
	end

	-- -----------------------------------------------------------------------

	local function ShowStatus(self, text)
		self:GetChild("Panel"):GetChild("Status"):visible(text ~= nil):settext(text or "")
	end

	local function UsePanel(self, yes)
		s.usePanel = yes
		self:GetChild("Panel"):visible(yes)
		self:GetChild("Badges"):visible(not yes)
	end

	local function Start(self)
		s.active, s.job, s.result, s.holds, s.cur = false, nil, nil, nil, 0
		s.mode = FootGuideSettings.Mode(pn)
		if not GAMESTATE:IsHumanPlayer(pn) or not (s.mode == "notes" or s.mode == "tricky" or s.mode == "panel") then
			self:visible(false)
			return
		end
		s.job = StartAnalysis(pn)
		if s.job.err then
			SCREENMAN:SystemMessage("Foot Guide: " .. s.job.err)
			self:visible(false)
			return
		end
		s.layoutName = s.job.layoutName
		LayoutPanel(self:GetChild("Panel"), s.layoutName)
		self:visible(true)
		UsePanel(self, s.mode == "panel")
		if not s.usePanel and not SetupBadges(self) then
			SCREENMAN:SystemMessage("Foot Guide: can't draw on this notefield (3D perspective?); using the side panel")
			UsePanel(self, true)
		end
		if s.usePanel and s.job.co then ShowStatus(self, "Analyzing chart...") end
		s.active = true
		s.shownRow, s.laneStart = nil, 1
		s.pos = GAMESTATE:GetPlayerState(pn):GetSongPosition()
	end

	local function Finish(self)
		local result = s.result
		local P = self:GetChild("Panel")
		ShowStatus(self, nil)
		s.holds = {}
		for _, row in ipairs(result.rows) do
			for _, note in ipairs(row.notes) do
				if note.endTime then
					s.holds[#s.holds+1] = { col = note.col, time = row.time, endTime = note.endTime, foot = note.foot }
				end
			end
		end
		local st = result.stats
		P:GetChild("Summary"):settext(string.format(
			"Crossovers %d   Footswitches %d\nBrackets %d   Doublesteps %d",
			st.crossovers, st.footswitches, st.brackets, st.doublesteps))
		s.cur = 0
	end

	local function Update(self)
		if not s.active then return end
		if not s.result then
			s.job:Step()
			if s.job.err then
				s.active = false
				SCREENMAN:SystemMessage("Foot Guide: " .. s.job.err)
				self:visible(false)
				return
			end
			s.result = s.job.result
			if not s.result then return end
		end
		if not s.holds then Finish(self) end

		local rows = s.result.rows
		local now = s.pos:GetMusicSecondsVisible()
		local cur = s.cur or 0
		if rows[cur] and rows[cur].time > now then cur, s.laneStart, s.badgeStart = 0, 1, 1 end
		while rows[cur + 1] and rows[cur + 1].time <= now do cur = cur + 1 end
		s.cur = cur

		if s.usePanel then
			local P = self:GetChild("Panel")
			if Config.ShowPad then UpdatePanelPad(rows, cur) end
			if Config.ShowLane then UpdateLane(P, rows, now) end
		else
			local ok, err = pcall(UpdateBadges, self:GetChild("Badges"), rows, now)
			if not ok then
				lua.ReportScriptError("FootGuide: badges disabled: " .. tostring(err))
				UsePanel(self, true)
			end
		end
	end

	local function OnGameplay()
		local screen = SCREENMAN:GetTopScreen()
		return screen and screen:GetName() == "ScreenGameplay"
	end

	af.ModuleCommand = function(self)
		Start(self)
		self:SetUpdateFunction(Update)
	end
	af.CurrentSongChangedMessageCommand = function(self)
		-- Courses: the next song's chart needs analysing.
		if OnGameplay() then Start(self) end
	end
	af.FootGuideToggledMessageCommand = function(self)
		if OnGameplay() then Start(self) end
	end
	af.ScreenChangedMessageCommand = function(self)
		if not OnGameplay() then
			s.active, s.job = false, nil
			self:visible(false)
		end
	end

	return af
end

-- ---------------------------------------------------------------------------
-- Ctrl+F: keyboard shortcut that turns the guide off, or back on (On Notes),
-- for everyone playing.

local ctrlHeld = {}

local function ToggleInput(event)
	if not event or not event.DeviceInput then return false end
	local button = event.DeviceInput.button
	if button == "DeviceButton_left ctrl" or button == "DeviceButton_right ctrl" then
		ctrlHeld[button] = (event.type ~= "InputEventType_Release")
	elseif button == "DeviceButton_f" and event.type == "InputEventType_FirstPress"
	and (ctrlHeld["DeviceButton_left ctrl"] or ctrlHeld["DeviceButton_right ctrl"]) then
		local anyOn = false
		for _, pn in ipairs(GAMESTATE:GetHumanPlayers()) do
			if FootGuideSettings.IsOn(pn) then anyOn = true end
		end
		for _, pn in ipairs(GAMESTATE:GetHumanPlayers()) do
			FootGuideSettings.SetMode(pn, anyOn and "off" or "notes")
		end
		SCREENMAN:SystemMessage("Foot Guide " .. (anyOn and "OFF" or "ON") .. "  (Ctrl+F to toggle)")
	end
	return false
end

local listeningOn = nil
local function ListenForToggle()
	local screen = SCREENMAN:GetTopScreen()
	-- Register once per screen, or a single press would toggle twice.
	if screen and screen ~= listeningOn then
		listeningOn = screen
		ctrlHeld = {}
		screen:AddInputCallback(ToggleInput)
	end
end

-- ---------------------------------------------------------------------------
-- "Trainer" mode: send the player to ScreenFootGuideTrainer instead of
-- ScreenGameplay by wrapping Simply Love's screen-branch functions.

local TRAINER_SCREEN = "ScreenFootGuideTrainer"

local function WantsTrainer()
	if GAMESTATE:IsCourseMode() then return false end
	for _, pn in ipairs(GAMESTATE:GetHumanPlayers()) do
		if FootGuideSettings.Mode(pn) == "trainer" then return true end
	end
	return false
end

if Branch then
	FootGuideOriginalBranch = FootGuideOriginalBranch or {}
	for _, name in ipairs({ "GameplayScreen", "AfterSelectMusic" }) do
		local original = FootGuideOriginalBranch[name] or Branch[name]
		if original then
			FootGuideOriginalBranch[name] = original
			Branch[name] = function(...)
				local nextScreen = original(...)
				if nextScreen == "ScreenGameplay" and WantsTrainer() then return TRAINER_SCREEN end
				return nextScreen
			end
		end
	end
end

-- ---------------------------------------------------------------------------

local Trainer = LoadPart("Trainer.lua")
Trainer = Trainer and Trainer({
	Solver = Solver, Config = Config, StartAnalysis = StartAnalysis, TECHS = TECHS,
	PadDef = PadDef, SetupPad = SetupPad, Arrow = Arrow, FootColor = FootColor,
	ROTATION = ROTATION, TechColor = TechColor, WarnColor = WarnColor,
	LeftColor = LeftColor, RightColor = RightColor,
})

local t = {}
t["ScreenSelectMusic"] = Def.ActorFrame{
	ModuleCommand = function(self) ListenForToggle() end,
}
t["ScreenGameplay"] = Def.ActorFrame{
	ModuleCommand = function(self) ListenForToggle() end,
	GameplayOverlay(PLAYER_1),
	GameplayOverlay(PLAYER_2),
}
if Trainer then t[TRAINER_SCREEN] = Trainer end
return t
