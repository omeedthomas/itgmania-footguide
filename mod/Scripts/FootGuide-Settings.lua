-- FootGuide settings, shared by the FootGuide module (Modules/FootGuide.lua)
-- and the "Foot Guide" row on Simply Love's Player Options screen.
--
-- Each player picks a mode:
--   off     - nothing
--   notes   - L/R badges on every arrow in the notefield
--   tricky  - badges only around crossovers, footswitches, brackets, etc.
--   panel   - the side panel (pad diagram + scrolling L/R lane)
--   trainer - go to the step-by-step trainer instead of playing the song
--
-- Modes are remembered in Save/FootGuide.txt, except "trainer", which only
-- lasts until the game is closed.

FootGuideSettings = (function()
	-- Mode for a player who has never changed the setting.
	local DEFAULT_MODE = "off"
	local STATE_FILE = "/Save/FootGuide.txt"

	local MODES   = { "off", "notes", "tricky", "panel", "trainer" }
	local CHOICES = { "Off", "On Notes", "Tricky Only", "Side Panel", "Trainer" }
	local VALID = {}
	for i, m in ipairs(MODES) do VALID[m] = i end

	local saved = nil    -- persisted modes { P1 = "...", P2 = "..." }
	local session = {}   -- modes for this session (may include "trainer")

	local function Short(pn)
		if pn == "P1" or pn == "P2" then return pn end
		return ToEnumShortString(pn)
	end

	local function Load()
		saved = { P1 = DEFAULT_MODE, P2 = DEFAULT_MODE }
		local f = RageFileUtil.CreateRageFile()
		if f:Open(STATE_FILE, 1) then
			local contents = f:Read() or ""
			for p, value in contents:gmatch("(P%d)%s*=%s*(%a+)") do
				value = value:lower()
				if value == "on" then value = "notes" end   -- older versions stored on/off
				if VALID[value] and value ~= "trainer" then saved[p] = value end
			end
			f:Close()
		end
		f:destroy()
	end

	local function Save()
		local f = RageFileUtil.CreateRageFile()
		if f:Open(STATE_FILE, 2) then
			f:Write(("P1=%s\nP2=%s\n"):format(saved.P1, saved.P2))
			f:Close()
		end
		f:destroy()
	end

	local M = {}

	function M.Mode(pn)
		if not saved then Load() end
		local p = Short(pn)
		return session[p] or saved[p] or DEFAULT_MODE
	end

	function M.IsOn(pn) return M.Mode(pn) ~= "off" end

	function M.SetMode(pn, mode)
		if not saved then Load() end
		if not VALID[mode] then return end
		local p = Short(pn)
		if M.Mode(p) == mode then return end
		session[p] = mode
		if mode ~= "trainer" and saved[p] ~= mode then
			saved[p] = mode
			Save()
		end
		MESSAGEMAN:Broadcast("FootGuideToggled", { Player = p })
	end

	-- OptionRow for metrics.ini:  LineFootGuide="lua,FootGuideSettings.OptionRow()"
	function M.OptionRow()
		return {
			Name = "FootGuide",
			LayoutType = "ShowAllInRow",
			SelectType = "SelectOne",
			OneChoiceForAllPlayers = false,
			ExportOnChange = true,
			Choices = CHOICES,
			LoadSelections = function(self, list, pn)
				list[VALID[M.Mode(pn)] or 1] = true
				return list
			end,
			SaveSelections = function(self, list, pn)
				for i, mode in ipairs(MODES) do
					if list[i] then M.SetMode(pn, mode) break end
				end
			end,
		}
	end

	return M
end)()
