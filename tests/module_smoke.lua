-- Runs FootGuide (module + settings script + trainer) inside a minimal fake
-- StepMania environment on a real chart, to catch runtime errors and check
-- behaviour without launching the game.
--   node test/run.js test/module_smoke.lua <songs root> </Songs/.../file.ssc> <StepsType_Dance_Single> <Difficulty_Hard> [mods]

local songsRoot, stepFile, stepsType, difficulty, mods = ARGS[1], ARGS[2], ARGS[3], ARGS[4], ARGS[5] or ""
local now = -2
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end end

-- ---------------------------------------------------------------- actors
local Actor = {}
Actor.__index = function(self, k)
	if Actor[k] then return Actor[k] end
	return function(self, ...) self.calls[k] = { ... } return self end
end
function Actor:GetChild(name)
	local c = self.childrenByName[name]
	if not c then error("GetChild('" .. tostring(name) .. "') not found under " .. tostring(self.name), 2) end
	return c
end
function Actor:SetUpdateFunction(f) self.update = f return self end
function Actor:visible(v) self.isVisible = v return self end
function Actor:settext(t) self.text = t return self end
-- positions are stored as px/py so they don't hide the x()/y() methods
function Actor:xy(x, y) self.px, self.py = x, y return self end
function Actor:x(x) self.px = x return self end
function Actor:y(y) self.py = y return self end
function Actor:diffusealpha(a) self.alpha = a return self end
function Actor:playcommand(name)
	local cmd = self.def[name .. "Command"]
	if cmd then cmd(self) end
	for _, c in ipairs(self.children) do c:playcommand(name) end
	return self
end
local function Instantiate(def)
	local obj = setmetatable({ calls = {}, childrenByName = {}, children = {}, def = def, name = def.Name }, Actor)
	for _, childDef in ipairs(def) do
		local child = Instantiate(childDef)
		obj.children[#obj.children+1] = child
		if child.name then obj.childrenByName[child.name] = child end
	end
	if def.InitCommand then def.InitCommand(obj) end
	return obj
end
local function Visible(a) return rawget(a, "isVisible") == true end
local function RunUpdates(a)
	if a.update then a.update(a, 1 / 60) end
	for _, c in ipairs(a.children) do RunUpdates(c) end
end

-- ---------------------------------------------------------------- globals
Def = setmetatable({}, { __index = function(_, cls) return function(t) t.Class = cls return t end end })
Color = { White = { 1, 1, 1, 1 }, Black = { 0, 0, 0, 1 } }
function color(s) return { 1, 1, 1, 1, hex = s } end
lua = { ReportScriptError = function(msg) error("ReportScriptError: " .. msg) end }
PLAYER_1, PLAYER_2 = "PlayerNumber_P1", "PlayerNumber_P2"
SCREEN_WIDTH, SCREEN_HEIGHT = 854, 480
_screen = { w = 854, h = 480, cx = 427, cy = 240 }
function ToEnumShortString(e) return (tostring(e):gsub("^[^_]*_", "")) end
local OLD = { expert = "Challenge", oni = "Challenge", smaniac = "Challenge", heavy = "Hard", maniac = "Hard",
	standard = "Medium", another = "Medium", trick = "Medium", light = "Easy", basic = "Easy" }
function OldStyleStringToDifficulty(d)
	local k = d:lower()
	return "Difficulty_" .. (OLD[k] or (k:sub(1, 1):upper() .. k:sub(2)))
end
function GetNotefieldX(pn) return pn == PLAYER_1 and 213 or 641 end
function SelectMusicOrCourse() return "ScreenSelectMusic" end
function GetNotefieldWidth() return stepsType:find("Double") and 512 or 256 end
SL = { P1 = { ActiveModifiers = { Mini = "0%", DataVisualizations = "None" } },
       P2 = { ActiveModifiers = { Mini = "0%", DataVisualizations = "None" } } }
THEME = {
	GetCurrentThemeDirectory = function() return ROOT end,
	GetPathS = function(_, a, b) return a .. " " .. b end,
	GetString = function(_, a, b) return b end,
}
local played = {}
local music = { starts = {}, stops = 0 }
SOUND = {
	PlayOnce = function(_, p) played[#played+1] = p end,
	PlayMusicPart = function(_, path, start, length) music.starts[#music.starts+1] = { path = path, start = start, length = length } end,
	StopMusic = function() music.stops = music.stops + 1 end,
}
local realNow = 0
function GetTimeSinceStart() return realNow end

function loadfile(path)
	local text = READ(path)
	if not text then return nil, "cannot read " .. path end
	return load(text, "@" .. path:gsub("^.*/mod/", ""))
end

local written = {}
RageFileUtil = { CreateRageFile = function()
	local f = {}
	function f:Open(path, mode)
		self.path = path
		if mode == 2 then written[path] = "" return true end
		self.text = written[path] or READ(songsRoot .. path)
		return self.text ~= nil
	end
	function f:Read() return self.text end
	function f:Write(str) written[self.path] = written[self.path] .. str end
	function f:Close() end
	function f:destroy() end
	return f
end }

local simText = READ(songsRoot .. stepFile)
assert(simText, "cannot read simfile " .. songsRoot .. stepFile)
local bpm = tonumber(simText:match("#BPMS:%s*[%d%.]+=([%d%.]+)"))
local timing = {
	GetElapsedTimeFromBeat = function(_, beat) return beat * 60 / bpm end,
	GetWarps = function() return {} end,
	GetFakes = function() return {} end,
}
local steps = {
	GetFilename = function() return stepFile end,
	GetStepsType = function() return stepsType end,
	GetDifficulty = function() return difficulty end,
	GetDescription = function() return "" end,
	GetTimingData = function() return timing end,
	GetMeter = function() return 9 end,
}
local tilt = 0
local songPosition = { GetMusicSecondsVisible = function() return now end }
local playerOptions = {
	UsingReverse = function() return mods:lower():find("reverse") ~= nil end,
	Tilt = function() return tilt end,
	Skew = function() return 0 end,
}
local playerState = {
	GetPlayerOptionsString = function() return mods end,
	GetPlayerOptions = function() return playerOptions end,
	GetSongPosition = function() return songPosition end,
}
local isDouble = stepsType:find("Double") ~= nil
GAMESTATE = {
	GetCurrentSteps = function() return steps end,
	GetCurrentSong = function() return {
		GetDisplayFullTitle = function() return "Test Song" end,
		GetMusicPath = function() return "/Songs/Test/test.ogg" end,
	} end,
	GetSongOptionsObject = function() return { MusicRate = function() return 1 end } end,
	IsHumanPlayer = function(_, pn) return pn == PLAYER_1 end,
	GetHumanPlayers = function() return { PLAYER_1 } end,
	GetNumPlayersEnabled = function() return 1 end,
	GetPlayerState = function() return playerState end,
	IsCourseMode = function() return false end,
	GetCurrentStyle = function() return {
		GetStepsType = function() return stepsType end,
		GetStyleType = function() return isDouble and "StyleType_OnePlayerTwoSides" or "StyleType_OnePlayerOneSide" end,
	} end,
}

-- A fake notefield: player at (213, 240), NoteField at y=-125, 64px per beat.
local ZERO_BASED = false   -- flip to test the other ArrowEffects column convention
local function NoteColX(col, n) return (col - (n + 1) / 2) * 64 end
ArrowEffects = {
	GetYOffset = function(_, col, beat) return (beat - now * bpm / 60) * 64 end,
	GetXPos = function(_, col, yOff)
		local n = isDouble and 8 or 4
		if ZERO_BASED then col = col + 1 end
		if col < 1 or col > n then return 0 end
		return NoteColX(col, n)
	end,
	GetYPos = function(_, col, yOff) return yOff end,
	GetAlpha = function() return 1 end,
}
local noteField = setmetatable({ calls = {}, childrenByName = {}, children = {}, def = {}, name = "NoteField" }, Actor)
function noteField:GetX() return 0 end
function noteField:GetY() return -125 end
function noteField:GetZoom() return 1 end
local playerAF = setmetatable({ calls = {}, childrenByName = { NoteField = noteField }, children = {}, def = {}, name = "PlayerP1" }, Actor)
function playerAF:GetX() return 213 end
function playerAF:GetY() return 240 end
function playerAF:GetZoom() return 1 end

local inputCallbacks = {}
local systemMessages = {}
local screenName = "ScreenGameplay"
local function NewScreen(name)
	screenName = name
	inputCallbacks = {}
	local screen = {
		GetName = function() return screenName end,
		AddInputCallback = function(_, fn) inputCallbacks[#inputCallbacks+1] = fn end,
		GetChild = function(_, n) return n == "PlayerP1" and playerAF or nil end,
	}
	function screen:SetNextScreenName(name) self.nextName = name return self end
	function screen:StartTransitioningScreen(msg)
		if msg == "SM_GoToNextScreen" then self.leftTo = self.nextName end
		return self
	end
	return screen
end
local topScreen = NewScreen("ScreenGameplay")
SCREENMAN = {
	GetTopScreen = function() return topScreen end,
	SystemMessage = function(_, msg) systemMessages[#systemMessages+1] = msg end,
}
local roots = {}
MESSAGEMAN = { Broadcast = function(_, msg)
	for _, r in ipairs(roots) do r:playcommand(msg .. "Message") end
end }
local function Send(event)
	local handled = false
	for _, fn in ipairs(inputCallbacks) do if fn(event) then handled = true end end
	return handled
end
local function Key(button, kind)
	Send({ type = "InputEventType_" .. kind, DeviceInput = { button = "DeviceButton_" .. button } })
end
local function CtrlF()
	Key("left ctrl", "FirstPress"); Key("f", "FirstPress"); Key("f", "Release"); Key("left ctrl", "Release")
end
-- A pad press: physical button + its menu meaning (pad Up/Down double as MenuUp/MenuDown).
local MENU_OF = { Left = "MenuLeft", Right = "MenuRight", Up = "MenuUp", Down = "MenuDown", Start = "Start", Back = "Back" }
local function Press(button, controller)
	return Send({ type = "InputEventType_FirstPress", button = button, GameButton = MENU_OF[button],
		PlayerNumber = PLAYER_1, controller = controller or "GameController_1", DeviceInput = { button = "x" } })
end

-- Simply Love's branch functions, which the module wraps for Trainer mode.
Branch = {
	GameplayScreen = function() return "ScreenGameplay" end,
	AfterSelectMusic = function() return "ScreenGameplay" end,
}

-- ---------------------------------------------------------------- load
-- Old save files: the previous version's global "on" is ignored, "P1=on" becomes On Notes.
written["/Save/FootGuide.txt"] = "on"
assert(loadfile(ROOT .. "Scripts/FootGuide-Settings.lua"))()   -- the theme loads Scripts/ first
check(FootGuideSettings.Mode(PLAYER_1) == "off", "bare 'on' from the first version should be ignored")
written["/Save/FootGuide.txt"] = "P1=on\nP2=off\n"
assert(loadfile(ROOT .. "Scripts/FootGuide-Settings.lua"))()
check(FootGuideSettings.Mode(PLAYER_1) == "notes", "P1=on should become On Notes")
written["/Save/FootGuide.txt"] = nil
assert(loadfile(ROOT .. "Scripts/FootGuide-Settings.lua"))()
check(FootGuideSettings.Mode(PLAYER_1) == "off", "default should be off")
print("settings: defaults + old save files ok")

local module = assert(loadfile(ROOT .. "Modules/FootGuide.lua"))()
check(module["ScreenSelectMusic"] and module["ScreenGameplay"] and module["ScreenFootGuideTrainer"], "missing screens")
local root = Instantiate(module["ScreenGameplay"])
roots[#roots+1] = root
local p1 = root:GetChild("FootGuideP1")
local badges = p1:GetChild("Badges")
local panel = p1:GetChild("Panel")

local function Frames(seconds)
	local frames = math.max(1, math.floor(seconds * 60 + 0.5))
	for _ = 1, frames do RunUpdates(root); now = now + 1 / 60 end
end
local function VisibleBadges()
	local list = {}
	for i = 1, 48 do
		local b = badges:GetChild("Badge" .. i)
		if Visible(b) then list[#list+1] = b end
	end
	return list
end

-- ---------------------------------------------------------------- off by default
root:playcommand("Module")
Frames(0.5)
check(not Visible(p1), "guide should start hidden")
print("gameplay: starts OFF ok")

-- ---------------------------------------------------------------- On Notes
local row = FootGuideSettings.OptionRow()
check(#row.Choices == 5 and row.Choices[2] == "On Notes", "row choices")
row:SaveSelections({ false, true, false, false, false }, PLAYER_1)   -- On Notes
now = -2
root:playcommand("Module")
Frames(0.2)
check(Visible(p1) and not Visible(panel), "On Notes should show badges, not the panel")
now = 20
Frames(1 / 60)
local vis = VisibleBadges()
check(#vis > 0, "no badges visible at t=20")
-- Every badge should sit exactly where the fake notefield draws a note.
local n = isDouble and 8 or 4
for _, b in ipairs(vis) do
	local letter = b:GetChild("Letter").text
	check(letter == "L" or letter == "R", "badge letter " .. tostring(letter))
	check(b.py >= 115 - 2, "badge above the receptors: y=" .. b.py)
	local onColumn = false
	for c = 1, n do if math.abs(b.px - (213 + NoteColX(c, n))) < 0.01 then onColumn = true end end
	check(onColumn, "badge x not on a column: " .. b.px)
end
print(("On Notes: %d badges at t=20, all on note columns, none above the receptors (y=115)"):format(#vis))
local notesCount = #vis

-- 0-based ArrowEffects columns are detected too.
ZERO_BASED = true
now = 20
root:playcommand("Module")
Frames(1 / 60)
for _, b in ipairs(VisibleBadges()) do
	local onColumn = false
	for c = 1, n do if math.abs(b.px - (213 + NoteColX(c, n))) < 0.01 then onColumn = true end end
	check(onColumn, "0-based columns: badge x not on a column: " .. b.px)
end
ZERO_BASED = false
print("On Notes: 0-based column convention detected ok")

-- ---------------------------------------------------------------- Tricky Only
row:SaveSelections({ false, false, true, false, false }, PLAYER_1)
now = 0
root:playcommand("Module")
local maxTricky, trickyFrames, frames = 0, 0, 0
for _ = 1, 60 * 60 do
	RunUpdates(root); now = now + 1 / 60
	local c = #VisibleBadges()
	maxTricky = math.max(maxTricky, c)
	frames = frames + 1
	if c > 0 then trickyFrames = trickyFrames + 1 end
end
check(Visible(p1), "Tricky Only hidden")
print(("Tricky Only: badges on screen %d%% of the first minute, at most %d at once (On Notes: %d at t=20)"):format(
	math.floor(100 * trickyFrames / frames), maxTricky, notesCount))

-- ---------------------------------------------------------------- tilted notefield -> panel
row:SaveSelections({ false, true, false, false, false }, PLAYER_1)
tilt = -0.3
now = 5
root:playcommand("Module")
Frames(0.1)
check(Visible(panel), "tilted perspective should fall back to the panel")
check(systemMessages[#systemMessages]:find("side panel"), "no fallback message")
tilt = 0
print("Tilt: falls back to side panel ok")

-- ---------------------------------------------------------------- Side Panel
row:SaveSelections({ false, false, false, true, false }, PLAYER_1)
now = 10
root:playcommand("Module")
Frames(1)
check(Visible(panel), "Side Panel hidden")
check((panel:GetChild("Summary").text or ""):find("Crossovers"), "panel summary missing")
print("Side Panel: " .. panel:GetChild("Summary").text:gsub("\n", " | "))

-- ---------------------------------------------------------------- Ctrl+F
root:playcommand("Module")   -- registers the Ctrl+F listener on this screen
CtrlF()
check(not Visible(p1), "Ctrl+F should turn the guide off")
CtrlF()
check(FootGuideSettings.Mode(PLAYER_1) == "notes", "Ctrl+F should turn it back on as On Notes")
print("Ctrl+F: off/on ok, saved=" .. written["/Save/FootGuide.txt"]:gsub("\n", " "))

-- ---------------------------------------------------------------- Trainer routing
check(Branch.GameplayScreen() == "ScreenGameplay", "should play normally when not in Trainer mode")
row:SaveSelections({ false, false, false, false, true }, PLAYER_1)
check(Branch.GameplayScreen() == "ScreenFootGuideTrainer", "Trainer mode should route to the trainer")
check(Branch.AfterSelectMusic() == "ScreenFootGuideTrainer", "Trainer mode from song select")
check(not written["/Save/FootGuide.txt"]:find("trainer"), "Trainer mode should not be saved to disk")
print("Trainer routing: ok (not persisted)")

-- ---------------------------------------------------------------- Trainer screen
topScreen = NewScreen("ScreenFootGuideTrainer")
local troot = Instantiate(module["ScreenFootGuideTrainer"])
roots[#roots+1] = troot
troot:playcommand("Module")
local tp = troot:GetChild("TrainerP1")
for _ = 1, 600 do
	RunUpdates(troot)
	if Visible(tp:GetChild("Menu")) then break end
end
check(Visible(tp:GetChild("Menu")), "trainer menu never appeared")
local menuItems = {}
for i = 1, 9 do
	local item = tp:GetChild("Menu"):GetChild("Item" .. i)
	if Visible(item) then menuItems[#menuItems+1] = item:GetChild("Label").text .. " - " .. item:GetChild("Detail").text end
end
print("Trainer sections:\n    " .. table.concat(menuItems, "\n    "))
check(#menuItems >= 1 and menuItems[1]:find("Whole chart"), "whole chart item")

check(Press("Back") == true and topScreen.leftTo == "ScreenPlayerOptions", "Back in the menu should go to Player Options")
topScreen.leftTo = nil   -- (the fake screen stays, so the rest of the test can continue)
Press("Down"); Press("Up")
check(Press("Start") == true, "Start should begin a section")
local drill = tp:GetChild("Drill")
check(Visible(drill), "drill not shown")
print("Trainer first instruction: " .. drill:GetChild("Instruction").text)

local BUTTONS = { "Left", "Down", "Up", "Right" }
-- The pad glows the panels the current step needs (in either mode).
local function CurrentColumns()
	local cols = {}
	for c = 1, n do
		local glow = drill:GetChild("Pad"):GetChild("Panel" .. c):GetChild("Glow")
		if (rawget(glow, "alpha") or 0) >= 0.5 then cols[#cols+1] = c end
	end
	return cols
end
local wrong
for c = 1, math.min(n, 4) do
	local needed = false
	for _, x in ipairs(CurrentColumns()) do if x == c then needed = true end end
	if not needed then wrong = c break end
end
Press(BUTTONS[wrong])
check(drill:GetChild("Progress").text:find("Mistakes: 1"), "wrong panel should count a mistake")
local stepsDone = 0
for _ = 1, 3000 do
	if Visible(drill:GetChild("Result")) then break end
	for _, c in ipairs(CurrentColumns()) do
		Press(BUTTONS[(c - 1) % 4 + 1], c > 4 and "GameController_2" or "GameController_1")
	end
	stepsDone = stepsDone + 1
end
check(Visible(drill:GetChild("Result")), "section never finished")
print(("Trainer: finished section in %d steps -> %q | %s"):format(stepsDone, drill:GetChild("Result").text,
	drill:GetChild("Progress").text))
check(Press("Start") == true, "Start should repeat the section")
check(drill:GetChild("Progress").text:find("Mistakes: 0"), "repeat should reset mistakes")
check(Press("Back") == true, "Back in a drill should return to the menu, not leave")
check(Visible(tp:GetChild("Menu")), "Back should show the menu")
print("Trainer: restart/back ok; sounds played: " .. #played)

local function TFrames(seconds)
	for _ = 1, math.max(1, math.floor(seconds * 60 + 0.5)) do realNow = realNow + 1 / 60; RunUpdates(troot) end
end
local padAF = drill:GetChild("Pad")
local function FeetPos()
	local l, r = padAF:GetChild("FootL"), padAF:GetChild("FootR")
	return (l.px or 0) .. "," .. (l.py or 0) .. "|" .. (r.px or 0) .. "," .. (r.py or 0)
end
local function DoStep()
	for _, c in ipairs(CurrentColumns()) do
		Press(BUTTONS[(c - 1) % 4 + 1], c > 4 and "GameController_2" or "GameController_1")
	end
end

-- ---------------------------------------------------------------- step by step: whole chart
Press("Up"); Press("Up")   -- menu cursor to "Whole chart"
local menu = tp:GetChild("Menu")
check(menu:GetChild("Mode").text:find("STEP BY STEP"), "default mode should be step by step")
Press("Start")
local helps, animated, steps = {}, 0, 0
local crossFront, crossBehind, bodyTurns, legChecks = nil, nil, 0, 0
local body = padAF:GetChild("Body")
-- Each leg must run from a hip (near the middle of the body) to exactly one foot.
local function LegEnds(leg)
	local len = leg.calls.zoomto[2]
	local a = math.rad(leg.calls.rotationz[1] + 90)
	local dx, dy = math.cos(a) * len / 2, math.sin(a) * len / 2
	return { leg.px + dx, leg.py + dy }, { leg.px - dx, leg.py - dy }
end
local function LegsAttached()
	-- (both feet can be drawn at the same spot mid-footswitch, so check each leg reaches a foot)
	local feet = { padAF:GetChild("FootL"), padAF:GetChild("FootR") }
	for _, legName in ipairs({ "LegFront", "LegBack" }) do
		local e1, e2 = LegEnds(body:GetChild(legName))
		local reaches = false
		for _, foot in ipairs(feet) do
			for _, e in ipairs({ e1, e2 }) do
				if math.abs(e[1] - foot.px) < 0.01 and math.abs(e[2] - foot.py) < 0.01 then reaches = true end
			end
		end
		if not reaches then return false end
	end
	return true
end
local lastTorso
for _ = 1, 5000 do
	if Visible(drill:GetChild("Result")) then break end
	local help = drill:GetChild("Help").text or ""
	for line in help:gmatch("[^\n]+") do
		local key = line:match("^%(?(%a+)") or line
		helps[key] = helps[key] or line
		if line:find("^Crossover") and line:find("in front of") then crossFront = crossFront or line end
		if line:find("^Crossover") and line:find("behind") then crossBehind = crossBehind or line end
	end
	-- the demo loop must actually move the feet, and the body must follow them
	TFrames(0.1); local a = FeetPos()
	check(Visible(body), "body hidden in the trainer")
	if LegsAttached() then legChecks = legChecks + 1 end
	TFrames(0.6); local b = FeetPos()
	if LegsAttached() then legChecks = legChecks + 1 end
	if a ~= b then animated = animated + 1 end
	local torso = body:GetChild("Torso").calls.rotationz[1]
	if lastTorso and math.abs(torso - lastTorso) > 20 then bodyTurns = bodyTurns + 1 end
	lastTorso = torso
	DoStep()
	steps = steps + 1
end
check(Visible(drill:GetChild("Result")), "whole chart never finished")
check(animated > steps * 0.5, ("demo animation only moved on %d of %d steps"):format(animated, steps))
check(legChecks == 2 * steps, ("legs not attached to the feet on %d of %d frames checked"):format(2 * steps - legChecks, 2 * steps))
check(bodyTurns > 0, "the body never turned")
print(("Step by step, whole chart: %d steps, demo moved the feet on %d, body turned on %d; legs always attached to the feet"):format(
	steps, animated, bodyTurns))
print("  Explanations seen:")
for _, key in ipairs({ "Footswitch", "Crossover", "Bracket", "Jump", "Spin", "Body", "Still", "Doublestep", "Jack", "Hold", "Keep" }) do
	if helps[key] then print("    " .. helps[key]) end
end
if crossFront then print("    " .. crossFront) end
if crossBehind then print("    " .. crossBehind) end
check(helps["Crossover"], "no crossover explanation on a chart with crossovers")

-- ---------------------------------------------------------------- with music
Press("Back")
Press("Right")
check(menu:GetChild("Mode").text:find("WITH MUSIC"), "Left/Right should switch to music mode")
Press("Down")   -- the first tricky section
local startsBefore, stopsBefore = #music.starts, music.stops
Press("Start")
check(#music.starts == startsBefore + 1, "music should start with the section")
local first = music.starts[#music.starts]
check(first.path == "/Songs/Test/test.ogg", "wrong music file")
check(Visible(drill:GetChild("Lane")) and not Visible(drill:GetChild("List")), "music mode should show the lane")
-- Don't step: the music must stop when the first arrow reaches the line.
TFrames(3)
local heading = drill:GetChild("Lane"):GetChild("Heading").text
check(heading == "WAITING FOR YOUR STEP", "should be waiting at the line, got " .. tostring(heading))
check(music.stops > stopsBefore, "music should pause while waiting")
local laneNotes = 0
for k = 1, 32 do if Visible(drill:GetChild("Lane"):GetChild("Note" .. k)) then laneNotes = laneNotes + 1 end end
check(laneNotes > 0, "lane should show the waiting arrows")
print(("With music: started at %.2fs, paused at the first step (%d arrows in the lane)"):format(first.start, laneNotes))
DoStep()
check(#music.starts == startsBefore + 2, "music should resume after the step")
print(("With music: resumed at %.2fs after the step"):format(music.starts[#music.starts].start))
-- Keep up with the music: step just before each arrow arrives -> no more pauses.
local pausesBefore = music.stops
for _ = 1, 3000 do
	if Visible(drill:GetChild("Result")) then break end
	TFrames(1 / 60)
	if drill:GetChild("Lane"):GetChild("Heading").text == "WAITING FOR YOUR STEP" then DoStep()
	else
		-- step when the current arrow is within 0.1s of the line
		local Ln = drill:GetChild("Lane")
		local note1 = Ln:GetChild("Note1")
		if Visible(note1) and note1.py and note1.py <= 188 + 0.1 * 150 then DoStep() end
	end
end
check(Visible(drill:GetChild("Result")), "music section never finished")
print(("With music: finished (%s); pauses while keeping up: %d"):format(drill:GetChild("Result").text, music.stops - pausesBefore))
TFrames(1.5)
check(music.stops > pausesBefore, "music should stop after the section ends")

print("SMOKE OK")
