local GW = GearWeights

local ROW_HEIGHT = 22
local VISIBLE_ROWS = 14
local rowPool = {}

local mainFrame, specLabel, scrollFrame, content
local statsPanel, lootPanel, settingsPanel
local statsTabBtn, lootTabBtn, settingsTabBtn
local lockedSlotChecks

local CATEGORY_ORDER = { "Primary", "Secondary", "Offensive", "Resistances", "Other" }

local function CategoryForLabel(label)
	if label == "Strength" or label == "Agility" or label == "Stamina"
		or label == "Intellect" or label == "Spirit" then
		return "Primary"
	end
	if strfind(label, "Resistance") then
		return "Resistances"
	end
	if strfind(label, "Rating") or strfind(label, "Per 5") then
		return "Secondary"
	end
	if strfind(label, "Power") or strfind(label, "Penetration") or strfind(label, "Expertise")
		or label == "Bonus Healing" then
		return "Offensive"
	end
	return "Other"
end

--------------------------------------------------------------------------------
-- Tab 1: Stat Weights
--------------------------------------------------------------------------------

local function CreateRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(340, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	local header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("LEFT", 2, 0)
	header:SetTextColor(1, 0.82, 0)
	row.header = header

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", 12, 0)
	label:SetWidth(220)
	label:SetJustifyH("LEFT")
	row.label = label

	local edit = CreateFrame("EditBox", nil, row)
	edit:SetSize(70, ROW_HEIGHT - 4)
	edit:SetPoint("RIGHT", -4, 0)
	edit:SetAutoFocus(false)
	edit:SetFontObject("GameFontHighlight")
	edit:SetJustifyH("RIGHT")
	edit:SetTextInsets(4, 6, 0, 0)
	edit:SetNumeric(false)
	edit:SetMaxLetters(10)
	edit:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	edit:SetBackdropColor(0, 0, 0, 0.6)
	row.edit = edit

	edit:SetScript("OnEditFocusLost", function(self)
		if row.statKey then
			local val = tonumber(self:GetText())
			local profile = GW.GetActiveProfile()
			profile.weights[row.statKey] = val
			if GW.NotifyWeightsChanged then GW.NotifyWeightsChanged() end
		end
	end)
	edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	return row
end

local function SetRowAsHeader(row, text)
	row.header:SetText(text)
	row.header:Show()
	row.label:Hide()
	row.edit:Hide()
	row.statKey = nil
end

local function SetRowAsStat(row, key, label, weight)
	row.header:Hide()
	row.label:Show()
	row.label:SetText(label)
	row.edit:Show()
	row.edit:SetText(weight and tostring(weight) or "")
	row.statKey = key
end

local function RefreshRows()
	local known = GW.GetKnownStats()
	local profile = GW.GetActiveProfile()

	local byCategory = {}
	for _, cat in ipairs(CATEGORY_ORDER) do
		byCategory[cat] = {}
	end
	for key, label in pairs(known) do
		if GW.CANONICAL_STAT_LABELS[label] then
			local cat = CategoryForLabel(label)
			table.insert(byCategory[cat], { key = key, label = label })
		end
	end
	for _, list in pairs(byCategory) do
		table.sort(list, function(a, b) return a.label < b.label end)
	end

	local items = {}
	for _, cat in ipairs(CATEGORY_ORDER) do
		local list = byCategory[cat]
		if #list > 0 then
			table.insert(items, { isHeader = true, text = cat })
			for _, entry in ipairs(list) do
				table.insert(items, entry)
			end
		end
	end

	content:SetHeight(math.max(#items * ROW_HEIGHT, VISIBLE_ROWS * ROW_HEIGHT))

	for i, item in ipairs(items) do
		local row = rowPool[i]
		if not row then
			row = CreateRow(i)
			rowPool[i] = row
		end
		if item.isHeader then
			SetRowAsHeader(row, item.text)
		else
			SetRowAsStat(row, item.key, item.label, profile.weights[item.key])
		end
		row:Show()
	end

	for i = #items + 1, #rowPool do
		rowPool[i]:Hide()
	end

	specLabel:SetText("Profile: " .. GW.GetCurrentSpecName())
end

--------------------------------------------------------------------------------
-- Import / Export popup
--------------------------------------------------------------------------------

local importExportFrame

local function CreateImportExportFrame()
	local f = CreateFrame("Frame", "GearWeightsImportExportFrame", UIParent)
	f:SetSize(420, 300)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:EnableMouse(true)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	f.title = title

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
	f.hint = hint

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() f:Hide() end)

	local scroll = CreateFrame("ScrollFrame", "GearWeightsImportExportScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 20, -70)
	scroll:SetPoint("BOTTOMRIGHT", -34, 50)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject("ChatFontNormal")
	edit:SetWidth(354)
	edit:SetAutoFocus(true)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	scroll:SetScrollChild(edit)
	f.edit = edit

	local actionButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	actionButton:SetSize(140, 22)
	actionButton:SetPoint("BOTTOM", 0, 16)
	f.actionButton = actionButton

	return f
end

local function ShowExportPopup()
	if not importExportFrame then importExportFrame = CreateImportExportFrame() end
	local f = importExportFrame
	f.title:SetText("Export Stat Weights")
	f.hint:SetText("Ctrl+C to copy")
	f.edit:SetText(GW.ExportWeights())
	f.edit:SetScript("OnTextChanged", nil)
	f.actionButton:SetText("Close")
	f.actionButton:SetScript("OnClick", function() f:Hide() end)
	f:Show()
	f.edit:SetFocus()
	f.edit:HighlightText()
end

local function ShowImportPopup()
	if not importExportFrame then importExportFrame = CreateImportExportFrame() end
	local f = importExportFrame
	f.title:SetText("Import Stat Weights")
	f.hint:SetText("Paste a bisbeard.com export string, then click Import")
	f.edit:SetText("")
	f.actionButton:SetText("Import")
	f.actionButton:SetScript("OnClick", function()
		local text = strtrim(f.edit:GetText())
		local ok, a, b, c = GW.ImportWeights(text)
		if ok then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"GearWeights: imported %d stat(s), %d pending until seen on gear, %d unrecognized.", a, b, c))
			RefreshRows()
			if GW.NotifyWeightsChanged then GW.NotifyWeightsChanged() end
			f:Hide()
		else
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights import failed: " .. tostring(a))
		end
	end)
	f:Show()
	f.edit:SetFocus()
end

--------------------------------------------------------------------------------
-- Tab 2: Instance Loot
--------------------------------------------------------------------------------

local LOOT_ROW_HEIGHT = 20
local lootRowPool = {}
local lootContent, lootScrollFrame, lootStatusText
local lootRescan, lootHeaderBoss, lootHeaderScore, lootHeaderDiff
local pendingRetryCounts = {}
local PENDING_GIVEUP_THRESHOLD = 2
local lastFilteredEntries = nil
local lastAllBossNames = {}

-- Out-of-instance dungeon/raid ranking sub-panel (swapped in place of the
-- current-zone loot list when you're not actually in an instance).
local dungeonRankPanel, dungeonRankScrollFrame, dungeonRankContent, dungeonRankStatusText
local dungeonRankRowPool = {}
local RefreshDungeonRankPanel
local lastZoneNameForSticky = nil
local stickyTargetBossName = nil
local shiningItemIds = {}
local defeatedBosses = {}

local function GetItemIDFromLink(link)
	if not link then return nil end
	local id = link:match("item:(%d+)")
	return id and tonumber(id)
end

-- Same "genuine upgrade" criteria used everywhere else (diff > 0.05), but for
-- an arbitrary item link rather than only ones AtlasLoot recognizes as
-- boss-specific - used to decide whether to glow it, whatever it is or
-- wherever it came from (instance, world, quest reward).
local function IsItemLinkAnUpgrade(itemLink)
	if not itemLink then return false end
	local _, diff, usable = GW.GetBestUpgradeDiff(itemLink)
	if usable == false then return false end
	return diff ~= nil and diff > 0.05
end

local function CreateLootRow(index)
	local row = CreateFrame("Frame", nil, lootContent)
	row:SetSize(400, LOOT_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * LOOT_ROW_HEIGHT)

	local header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("LEFT", 2, 0)
	header:SetTextColor(1, 0.82, 0)
	row.header = header

	local itemBtn = CreateFrame("Button", nil, row)
	itemBtn:SetPoint("LEFT", 12, 0)
	itemBtn:SetSize(245, LOOT_ROW_HEIGHT)
	local itemText = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	itemText:SetAllPoints(itemBtn)
	itemText:SetJustifyH("LEFT")
	itemBtn.text = itemText
	local defR, defG, defB = itemText:GetTextColor()
	itemText.defaultColor = { defR, defG, defB }
	itemBtn:SetScript("OnEnter", function(self)
		if row.itemLink then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(row.itemLink)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click to link in chat, Alt+Click to add to AtlasLoot WishList, Ctrl+Click to lock/unlock this slot", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end
	end)
	itemBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	itemBtn:SetScript("OnClick", function()
		if not row.itemLink then return end
		if IsControlKeyDown() then
			GW.ToggleSlotLockForItem(row.itemLink)
		elseif IsAltKeyDown() then
			GW.AddToAtlasLootWishlist(row.entry)
		elseif ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
			ChatEdit_InsertLink(row.itemLink)
		end
	end)
	row.itemBtn = itemBtn

	local scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	scoreText:SetPoint("LEFT", itemBtn, "RIGHT", 4, 0)
	scoreText:SetWidth(45)
	scoreText:SetJustifyH("RIGHT")
	row.scoreText = scoreText

	local diffText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	diffText:SetPoint("LEFT", scoreText, "RIGHT", 6, 0)
	diffText:SetWidth(110)
	diffText:SetJustifyH("LEFT")
	row.diffText = diffText

	-- A little shine on the item name when it's an upgrade that actually just
	-- dropped in this instance (vs. just being possible from the database),
	-- so it stands out instead of needing to scan the whole list.
	row.shineElapsed = 0
	row:SetScript("OnUpdate", function(self, elapsed)
		if not self.shining then return end
		self.shineElapsed = self.shineElapsed + elapsed
		local pulse = 0.5 + 0.5 * math.sin(self.shineElapsed * 4)
		local dc = self.itemBtn.text.defaultColor
		self.itemBtn.text:SetTextColor(
			dc[1] + (1 - dc[1]) * pulse,
			dc[2] + (0.85 - dc[2]) * pulse,
			dc[3] + (0.1 - dc[3]) * pulse
		)
	end)

	return row
end

local function SetLootRowAsHeader(row, text, isCurrentTarget, isDefeated)
	if isDefeated then
		row.header:SetText("|cffff4444" .. text .. " (Defeated)|r")
	elseif isCurrentTarget then
		row.header:SetText(text .. " |cff00ccff(Current Target)|r")
	else
		row.header:SetText(text)
	end
	row.header:Show()
	row.itemBtn:Hide()
	row.scoreText:Hide()
	row.diffText:Hide()
	row.itemLink = nil
	row.entry = nil
	row.shining = false
end

local function SetLootRowAsNoLoot(row)
	row.header:SetText("|cff888888No loot to show|r")
	row.header:Show()
	row.itemBtn:Hide()
	row.scoreText:Hide()
	row.diffText:Hide()
	row.itemLink = nil
	row.entry = nil
	row.shining = false
end

local function SetLootRowAsItem(row, entry)
	row.header:Hide()
	row.itemBtn:Show()
	row.scoreText:Show()
	row.diffText:Show()

	local itemName = GetItemInfo(entry.itemLink)
	row.itemBtn.text:SetText(itemName or entry.itemLink)
	row.itemLink = entry.itemLink
	row.entry = entry

	local itemID = GetItemIDFromLink(entry.itemLink)
	row.shining = itemID ~= nil and shiningItemIds[itemID] or false
	if not row.shining then
		local dc = row.itemBtn.text.defaultColor
		row.itemBtn.text:SetTextColor(dc[1], dc[2], dc[3])
	end

	if entry.unusable then
		row.scoreText:SetText("")
		row.diffText:SetText("|cff888888Unusable by your class|r")
		return
	end

	row.scoreText:SetText(string.format("%.1f", entry.score))
	if entry.diff and entry.diff > 0.05 then
		row.diffText:SetText(string.format("|cff00ff00Upgrade (+%.1f)|r", entry.diff))
	elseif entry.diff and entry.diff < -0.05 then
		row.diffText:SetText(string.format("|cffff4444Downgrade (%.1f)|r", entry.diff))
	elseif entry.diff then
		row.diffText:SetText("|cffffff00Sidegrade|r")
	else
		row.diffText:SetText("")
	end
end

local DUNGEON_RANK_ROW_HEIGHT = 20
-- Session-only (not saved) - collapsed by default every fresh login/reload,
-- but remembers what you've expanded for the rest of that session, since
-- this is never written to SavedVariables.
local dungeonRankCollapsed = { dungeon = true, raid = true, vendor = true }
-- Session-only, keyed by zoneKey - which zones are expanded to show their
-- individual upgrade items rather than just the summary count.
local dungeonRankExpanded = {}

-- "zone" (default: grouped by dungeon/raid, as above) or "slot" (grouped by
-- equip slot, every upgrade for that slot sorted best-to-worst regardless of
-- which zone it drops in).
local dungeonRankViewMode = "zone"
local dungeonRankSlotCollapsed = {}

-- Where an item actually drops (Ring1 vs Ring2, MH vs OH) doesn't matter for
-- browsing prospects - GetBestUpgradeDiff already picks whichever of those
-- slots gives the best diff, so group by the general category instead.
local EQUIP_LOC_TO_SLOT_CATEGORY = {
	INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder",
	INVTYPE_CLOAK = "Back", INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest",
	INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands", INVTYPE_WAIST = "Waist",
	INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet",
	INVTYPE_FINGER = "Ring", INVTYPE_TRINKET = "Trinket",
	INVTYPE_WEAPON = "One-Hand Weapon", INVTYPE_2HWEAPON = "Two-Hand Weapon",
	INVTYPE_WEAPONMAINHAND = "Main Hand", INVTYPE_WEAPONOFFHAND = "Off Hand",
	INVTYPE_SHIELD = "Shield", INVTYPE_HOLDABLE = "Held In Off-hand",
	INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Thrown",
	INVTYPE_RELIC = "Relic",
}
local SLOT_CATEGORY_ORDER = {
	"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
	"Ring", "Trinket", "One-Hand Weapon", "Two-Hand Weapon", "Main Hand", "Off Hand",
	"Shield", "Held In Off-hand", "Ranged", "Thrown", "Relic", "Other",
}
-- Same collapsed-by-default rule as the zone-mode categories above.
for _, category in ipairs(SLOT_CATEGORY_ORDER) do
	dungeonRankSlotCollapsed[category] = true
end

local function GetSlotCategory(itemLink)
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)
	return EQUIP_LOC_TO_SLOT_CATEGORY[equipLoc] or "Other"
end

-- All rows share ONE column split, not a per-row one - otherwise every row's
-- counts column lands at a different x position depending on that row's own
-- name length, which is what "not organized into columns" actually was.
-- The shared split itself is still measured from content (the longest name
-- across all current rows, then the longest counts text with what's left),
-- so it still grows properly as the window widens.
local DUNGEON_COLUMN_GAP = 8
local DUNGEON_COLUMN_MARGIN = 8 -- 4px left + 4px right

-- rows: array of { row = <frame>, isColumnRow = bool } - only isColumnRow
-- entries participate in the shared split; header-style rows stay full width.
local function LayoutDungeonRowColumnsShared(rowEntries, totalWidth)
	local totalAvailable = (totalWidth or 360) - DUNGEON_COLUMN_MARGIN - DUNGEON_COLUMN_GAP
	if totalAvailable < 40 then totalAvailable = 40 end

	local maxNameNeeded, maxCountsNeeded = 0, 0
	for _, entry in ipairs(rowEntries) do
		if entry.isColumnRow then
			maxNameNeeded = math.max(maxNameNeeded, entry.row.nameText:GetStringWidth() or 0)
			maxCountsNeeded = math.max(maxCountsNeeded, entry.row.countsText:GetStringWidth() or 0)
		end
	end

	local nameWidth = math.min(maxNameNeeded, totalAvailable)
	local countsWidth = math.min(maxCountsNeeded, math.max(totalAvailable - nameWidth, 0))

	for _, entry in ipairs(rowEntries) do
		if entry.isColumnRow then
			local row = entry.row
			row.nameText:ClearAllPoints()
			row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
			row.nameText:SetWidth(math.max(nameWidth, 1))

			row.countsText:ClearAllPoints()
			row.countsText:SetPoint("LEFT", row.nameText, "RIGHT", DUNGEON_COLUMN_GAP, 0)
			row.countsText:SetWidth(math.max(countsWidth, 1))
		end
	end
end

local function SetDungeonRowFullWidthName(row)
	row.nameText:ClearAllPoints()
	row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.nameText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.countsText:ClearAllPoints()
	row.countsText:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.countsText:SetWidth(1)
end

local function CreateDungeonRankRow(index)
	local row = CreateFrame("Button", nil, dungeonRankContent)
	local width = (dungeonRankScrollFrame and dungeonRankScrollFrame:GetWidth() or 0)
	row:SetSize(width > 0 and width or 360, DUNGEON_RANK_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * DUNGEON_RANK_ROW_HEIGHT)

	local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nameText:SetJustifyH("LEFT")
	nameText:SetWordWrap(false)
	row.nameText = nameText

	local countsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	countsText:SetJustifyH("LEFT")
	countsText:SetWordWrap(false)
	row.countsText = countsText

	-- Only shown/positioned for vendor rows - a real icon + its own hover
	-- hitbox (separate from the row's own item-tooltip hover), so a vendor
	-- price can show the exact same icon and tooltip as the bottom-bar
	-- currency tracker instead of plain text.
	local priceIcon = row:CreateTexture(nil, "ARTWORK")
	priceIcon:SetSize(14, 14)
	priceIcon:SetPoint("LEFT", countsText, "RIGHT", 6, 0)
	priceIcon:Hide()
	row.priceIcon = priceIcon

	local priceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	priceText:SetJustifyH("LEFT")
	priceText:SetWordWrap(false)
	priceText:SetPoint("LEFT", priceIcon, "RIGHT", 4, 0)
	row.priceText = priceText

	local priceHitbox = CreateFrame("Frame", nil, row)
	priceHitbox:SetPoint("TOPLEFT", priceIcon, "TOPLEFT", 0, 0)
	priceHitbox:SetPoint("BOTTOMRIGHT", priceText, "BOTTOMRIGHT", 0, 0)
	priceHitbox:EnableMouse(true)
	priceHitbox:Hide()
	row.priceHitbox = priceHitbox

	return row
end

-- Renders a vendor item's cost after the diff (countsText) using a real icon
-- + hover tooltip where possible - the same icon/tooltip as the bottom-bar
-- Mark of Triumph tracker for that currency specifically - rather than plain
-- text, since neither is otherwise interactive or visually distinct at a glance.
-- sharedMode skips the per-row anchor below - used in the zone view, where a
-- later pass aligns every vendor row's icon to one shared position instead
-- (countsText there is diff-only text of near-identical width, so per-row
-- natural width just introduces a few pixels of jitter row to row; the slot
-- view's countsText also embeds a variable-length source location, where
-- per-row natural width is the correct behavior instead).
local function SetDungeonRowPrice(row, itemLink, sharedMode)
	if not sharedMode then
		-- countsText's box can be much wider than its actual text (the shared
		-- column layout pass stretches it to match the widest row in the
		-- current view), so anchor to the real rendered text width instead of
		-- the box's right edge - otherwise the icon ends up positioned past
		-- where the visible text actually ends, often off the row entirely.
		row.priceIcon:ClearAllPoints()
		row.priceIcon:SetPoint("LEFT", row.countsText, "LEFT", row.countsText:GetStringWidth() + 6, 0)
	end

	local parts, status = GW.GetVendorPriceParts(itemLink)
	if not parts then
		row.priceIcon:Hide()
		row.priceHitbox:Hide()
		if status == "special" then
			row.priceText:SetText("|cff888888costs a special currency (amount not shown)|r")
		elseif status == "free" then
			row.priceText:SetText("|cff00ff00Free|r")
		else
			row.priceText:SetText("|cff888888price unknown - visit vendor|r")
		end
		return
	end

	local primary = parts[1]
	local extra = {}
	for i = 2, #parts do
		local p = parts[i]
		if p.kind == "copper" then
			table.insert(extra, GetCoinTextureString(p.amount))
		else
			local name = p.itemLink and GetItemInfo(p.itemLink) or p.name or "?"
			table.insert(extra, string.format("%d %s", p.amount, name))
		end
	end
	local extraText = #extra > 0 and ("  " .. table.concat(extra, ", ")) or ""

	if primary.kind == "markOfTriumph" then
		local _, icon = GW.GetMarkOfTriumphInfo()
		row.priceIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		row.priceIcon:Show()
		row.priceText:SetText(tostring(primary.amount) .. extraText)
		row.priceHitbox:Show()
		row.priceHitbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GW.ShowMarkOfTriumphTooltip()
			GameTooltip:Show()
		end)
		row.priceHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
	elseif primary.kind == "item" and primary.itemLink then
		local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(primary.itemLink)
		row.priceIcon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
		row.priceIcon:Show()
		row.priceText:SetText(tostring(primary.amount) .. extraText)
		row.priceHitbox:Show()
		row.priceHitbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(primary.itemLink)
			GameTooltip:Show()
		end)
		row.priceHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
	else
		row.priceIcon:Hide()
		row.priceHitbox:Hide()
		local primaryText = primary.kind == "copper" and GetCoinTextureString(primary.amount)
			or string.format("%d %s", primary.amount, primary.name or "?")
		row.priceText:SetText(primaryText .. extraText)
	end
end

local CATEGORY_LABEL = { dungeon = "Dungeons", raid = "Raids", vendor = "Vendors" }

local function SetDungeonRankRowAsHeader(row, category, count, itemTotal)
	local arrow = dungeonRankCollapsed[category] and "+" or "-"
	local label = CATEGORY_LABEL[category] or category
	SetDungeonRowFullWidthName(row)
	row.nameText:SetText(string.format("|cffffff00[%s] %s (%d %s, %d %s)|r", arrow, label,
		count, count == 1 and "location" or "locations",
		itemTotal, itemTotal == 1 and "item" or "items"))
	row.countsText:SetText("")
	row.priceIcon:Hide()
	row.priceHitbox:Hide()
	row.priceText:SetText("")
	row:EnableMouse(true)
	row:SetScript("OnEnter", nil)
	row:SetScript("OnLeave", nil)
	row:SetScript("OnClick", function()
		dungeonRankCollapsed[category] = not dungeonRankCollapsed[category]
		RefreshDungeonRankPanel()
	end)
end

local CATEGORY_COLOR = { dungeon = "|cff40c0ff", raid = "|cffff6060", vendor = "|cffffcc00" }

local function SetDungeonRankRowAsItem(row, result)
	local categoryColor = CATEGORY_COLOR[result.category] or "|cffffffff"
	local arrow = dungeonRankExpanded[result.zoneKey] and "[-]" or "[+]"
	row.nameText:SetText("   " .. arrow .. " " .. categoryColor .. result.zoneName .. "|r")

	local parts = {}
	if GW.IsDungeonRankTierEnabled("normal") then table.insert(parts, "N:" .. result.normal) end
	if GW.IsDungeonRankTierEnabled("heroic") then table.insert(parts, "H:" .. result.heroic) end
	if GW.IsDungeonRankTierEnabled("mythic") then table.insert(parts, "M:" .. result.mythic) end
	row.countsText:SetText(table.concat(parts, "  ") .. string.format("  |cffffff00(%d total)|r", result.total))
	row.priceIcon:Hide()
	row.priceHitbox:Hide()
	row.priceText:SetText("")

	row:EnableMouse(true)
	row:SetScript("OnEnter", nil)
	row:SetScript("OnLeave", nil)
	row:SetScript("OnClick", function()
		dungeonRankExpanded[result.zoneKey] = not dungeonRankExpanded[result.zoneKey]
		RefreshDungeonRankPanel()
	end)
end

local TIER_LABEL = { normal = "Normal", heroic = "Heroic", mythic = "Mythic" }

local function SetDungeonRankRowAsBossHeader(row, bossName)
	SetDungeonRowFullWidthName(row)
	row.nameText:SetText("      |cffffd200" .. (bossName or "Unknown") .. "|r")
	row.countsText:SetText("")
	row.priceIcon:Hide()
	row.priceHitbox:Hide()
	row.priceText:SetText("")
	row:EnableMouse(false)
	row:SetScript("OnClick", nil)
	row:SetScript("OnEnter", nil)
	row:SetScript("OnLeave", nil)
end

local function SetDungeonRankRowAsSubItem(row, item)
	local itemName = GetItemInfo(item.itemLink)
	row.nameText:SetText("            |cffffffff" .. (itemName or item.itemLink) .. "|r")
	if item.isVendorItem then
		row.countsText:SetText(string.format("|cff00ff00+%.1f|r", item.diff))
		SetDungeonRowPrice(row, item.itemLink, true)
	else
		row.countsText:SetText(string.format("|cff00ff00+%.1f|r  |cff888888(%s)|r",
			item.diff, TIER_LABEL[item.tier] or item.tier))
		row.priceIcon:Hide()
		row.priceHitbox:Hide()
		row.priceText:SetText("")
	end

	row:EnableMouse(true)
	row:SetScript("OnClick", function()
		if IsControlKeyDown() then
			GW.ToggleSlotLockForItem(item.itemLink)
		elseif ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
			ChatEdit_InsertLink(item.itemLink)
		end
	end)
	row:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(item.itemLink)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function SetDungeonRankRowAsSlotHeader(row, category, count)
	local arrow = dungeonRankSlotCollapsed[category] and "+" or "-"
	SetDungeonRowFullWidthName(row)
	row.nameText:SetText(string.format("|cffffff00[%s] %s (%d)|r", arrow, category, count))
	row.countsText:SetText("")
	row.priceIcon:Hide()
	row.priceHitbox:Hide()
	row.priceText:SetText("")
	row:EnableMouse(true)
	row:SetScript("OnEnter", nil)
	row:SetScript("OnLeave", nil)
	row:SetScript("OnClick", function()
		dungeonRankSlotCollapsed[category] = not dungeonRankSlotCollapsed[category]
		RefreshDungeonRankPanel()
	end)
end

-- Same as a zone-mode sub-item row, but shows where it drops (zone/boss)
-- instead of assuming that's already obvious from a parent zone row.
local function SetDungeonRankRowAsSlotItem(row, item)
	local itemName = GetItemInfo(item.itemLink)
	local categoryColor = CATEGORY_COLOR[item.category] or "|cffffffff"
	row.nameText:SetText("   " .. categoryColor .. (itemName or item.itemLink) .. "|r")
	local source = item.bossName and (item.zoneName .. " - " .. item.bossName) or item.zoneName
	if item.category == "vendor" then
		row.countsText:SetText(string.format("|cff00ff00+%.1f|r  |cff888888%s|r", item.diff, source or "?"))
		SetDungeonRowPrice(row, item.itemLink)
	else
		row.countsText:SetText(string.format("|cff00ff00+%.1f|r  |cff888888%s (%s)|r",
			item.diff, source or "?", TIER_LABEL[item.tier] or item.tier))
		row.priceIcon:Hide()
		row.priceHitbox:Hide()
		row.priceText:SetText("")
	end

	row:EnableMouse(true)
	row:SetScript("OnClick", function()
		if IsControlKeyDown() then
			GW.ToggleSlotLockForItem(item.itemLink)
		elseif ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
			ChatEdit_InsertLink(item.itemLink)
		end
	end)
	row:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(item.itemLink)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local dungeonRankPollFrame = CreateFrame("Frame")
dungeonRankPollFrame:Hide()

RefreshDungeonRankPanel = function()
	if GW.RefreshWeaponBaselineDisplay then GW.RefreshWeaponBaselineDisplay() end
	local state = GW.GetDungeonRankScanState()
	local cached = GW.GetCachedDungeonRanking()

	if state.inProgress then
		if state.total > 0 then
			dungeonRankStatusText:SetText(string.format("|cffffff00Scanning dungeons and raids... %d/%d|r", state.processed, state.total))
		else
			dungeonRankStatusText:SetText("|cffffff00Scanning dungeons and raids...|r")
		end
		dungeonRankPollFrame:Show()
	else
		dungeonRankPollFrame:Hide()
		if not cached then
			dungeonRankStatusText:SetText("No scan yet - click Scan All Dungeons/Raids below.")
		elseif not (GW.IsDungeonRankTierEnabled("normal") or GW.IsDungeonRankTierEnabled("heroic") or GW.IsDungeonRankTierEnabled("mythic")) then
			dungeonRankStatusText:SetText("Tick at least one difficulty above to see results.")
		else
			local currentSpec = GW.GetCurrentSpecId and GW.GetCurrentSpecId()
			local staleNote = (cached.specId and currentSpec and cached.specId ~= currentSpec)
				and " |cffff8800(spec changed since this scan)|r" or ""
			dungeonRankStatusText:SetText(string.format("%d zone%s with upgrades%s", #cached.results,
				#cached.results == 1 and "" or "s", staleNote))
		end
	end

	local results = cached and cached.results or {}
	local items = {}

	if dungeonRankViewMode == "slot" then
		-- Flatten every already-scanned item (regardless of zone) into slot
		-- buckets, best upgrade first - a pure re-organization of cached scan
		-- data, no rescanning involved.
		local bySlot = {}
		for _, result in ipairs(results) do
			for _, entry in ipairs(result.items) do
				local category = GetSlotCategory(entry.itemLink)
				bySlot[category] = bySlot[category] or {}
				table.insert(bySlot[category], {
					itemLink = entry.itemLink, diff = entry.diff, tier = entry.tier,
					zoneName = result.zoneName,
					bossName = (result.category ~= "vendor") and entry.bossName or nil,
					category = result.category,
				})
			end
		end
		for _, category in ipairs(SLOT_CATEGORY_ORDER) do
			local list = bySlot[category]
			if list and #list > 0 then
				table.sort(list, function(a, b) return a.diff > b.diff end)
				table.insert(items, { isSlotHeader = true, category = category, count = #list })
				if not dungeonRankSlotCollapsed[category] then
					for _, entry in ipairs(list) do
						table.insert(items, {
							isSlotItem = true, itemLink = entry.itemLink, diff = entry.diff, tier = entry.tier,
							zoneName = entry.zoneName, bossName = entry.bossName, category = entry.category,
						})
					end
				end
			end
		end
	else
		local byCategory = { dungeon = {}, raid = {}, vendor = {} }
		for _, result in ipairs(results) do
			local bucket = byCategory[result.category]
			if bucket then table.insert(bucket, result) end
		end

		local function AppendZoneRows(list)
			for _, r in ipairs(list) do
				table.insert(items, r)
				if dungeonRankExpanded[r.zoneKey] then
					if r.category == "vendor" then
						-- AtlasLoot models a vendor's stock as "boss" pages (Page 1,
						-- Page 2...), but that's just pagination of the same shop,
						-- not a meaningful grouping - list every item flat instead,
						-- highest upgrade first. Sort a copy rather than r.items
						-- itself, since that's the shared cached scan data reused
						-- by other view modes (e.g. View by Slot).
						local vendorItems = {}
						for _, entry in ipairs(r.items) do table.insert(vendorItems, entry) end
						table.sort(vendorItems, function(a, b) return a.diff > b.diff end)
						for _, entry in ipairs(vendorItems) do
							table.insert(items, { isSubItem = true, itemLink = entry.itemLink, diff = entry.diff, tier = entry.tier, isVendorItem = true })
						end
					else
						-- Group the zone's items by boss (preserving first-seen
						-- order), same grouping style as the current-zone
						-- Instance Loot list.
						local byBoss, bossOrder = {}, {}
						for _, entry in ipairs(r.items) do
							local bossName = entry.bossName or "Unknown"
							if not byBoss[bossName] then
								byBoss[bossName] = {}
								table.insert(bossOrder, bossName)
							end
							table.insert(byBoss[bossName], entry)
						end
						for _, bossName in ipairs(bossOrder) do
							table.insert(items, { isBossHeader = true, bossName = bossName })
							local bossEntries = byBoss[bossName]
							table.sort(bossEntries, function(a, b) return a.diff > b.diff end)
							for _, entry in ipairs(bossEntries) do
								table.insert(items, { isSubItem = true, itemLink = entry.itemLink, diff = entry.diff, tier = entry.tier })
							end
						end
					end
				end
			end
		end

		for _, category in ipairs({ "dungeon", "raid", "vendor" }) do
			local list = byCategory[category]
			if #list > 0 then
				local itemTotal = 0
				for _, r in ipairs(list) do itemTotal = itemTotal + r.total end
				table.insert(items, { isHeader = true, category = category, count = #list, itemTotal = itemTotal })
				if not dungeonRankCollapsed[category] then AppendZoneRows(list) end
			end
		end
	end

	local rowWidth = dungeonRankScrollFrame:GetWidth()
	if rowWidth and rowWidth > 0 then
		dungeonRankContent:SetWidth(rowWidth)
	end
	dungeonRankContent:SetHeight(math.max(#items * DUNGEON_RANK_ROW_HEIGHT, VISIBLE_ROWS * DUNGEON_RANK_ROW_HEIGHT))

	local rowEntries = {}
	local vendorPriceRows = {}
	for i, item in ipairs(items) do
		local row = dungeonRankRowPool[i]
		if not row then
			row = CreateDungeonRankRow(i)
			dungeonRankRowPool[i] = row
		end
		if rowWidth and rowWidth > 0 then
			row:SetWidth(rowWidth)
		end
		local isColumnRow = true
		if item.isHeader then
			SetDungeonRankRowAsHeader(row, item.category, item.count, item.itemTotal)
			isColumnRow = false
		elseif item.isBossHeader then
			SetDungeonRankRowAsBossHeader(row, item.bossName)
			isColumnRow = false
		elseif item.isSubItem then
			SetDungeonRankRowAsSubItem(row, item)
			if item.isVendorItem then table.insert(vendorPriceRows, row) end
		elseif item.isSlotHeader then
			SetDungeonRankRowAsSlotHeader(row, item.category, item.count)
			isColumnRow = false
		elseif item.isSlotItem then
			SetDungeonRankRowAsSlotItem(row, item)
		else
			SetDungeonRankRowAsItem(row, item)
		end
		table.insert(rowEntries, { row = row, isColumnRow = isColumnRow })
		row:Show()
	end
	for i = #items + 1, #dungeonRankRowPool do
		dungeonRankRowPool[i]:Hide()
	end

	-- Now that every row's text content is set, lay out ONE shared column
	-- split across all of them, so the counts column lines up at the same
	-- x position on every row instead of each row picking its own.
	LayoutDungeonRowColumnsShared(rowEntries, rowWidth)

	-- Zone-view vendor rows only ever show a short diff value in countsText,
	-- so align every price icon to the widest one instead of each row's own
	-- (near-identical but not pixel-identical) natural text width - gives a
	-- clean lined-up column instead of a few pixels of jitter row to row.
	local maxCountsWidth = 0
	for _, row in ipairs(vendorPriceRows) do
		maxCountsWidth = math.max(maxCountsWidth, row.countsText:GetStringWidth() or 0)
	end
	for _, row in ipairs(vendorPriceRows) do
		row.priceIcon:ClearAllPoints()
		row.priceIcon:SetPoint("LEFT", row.countsText, "LEFT", maxCountsWidth + 6, 0)
	end
end

dungeonRankPollFrame:SetScript("OnUpdate", function(self, elapsed)
	self.elapsed = (self.elapsed or 0) + elapsed
	if self.elapsed < 0.3 then return end
	self.elapsed = 0
	RefreshDungeonRankPanel()
end)

-- Groups the (already boss-contiguous) filtered entries into boss groups,
-- then - if Target Loot is on - pins whichever boss you last targeted (that's
-- actually in this zone) to the top. That pin is sticky: it only changes when
-- you target a *different* known boss, not when you lose target or target an
-- add, so it doesn't jump around mid-fight. If that boss has no items worth
-- showing, it still gets pinned with a "No loot to show" line instead of just
-- disappearing. Bosses already killed this run drop to the bottom of the
-- list in red, out of the way, instead of competing with ones still alive.
-- Doesn't touch the underlying scan data, so this just re-orders the same
-- results instead of re-scanning.
local function RenderLootRows()
	local filtered = lastFilteredEntries or {}
	local targetLootEnabled = GW.IsTargetLootEnabled()

	if targetLootEnabled and UnitExists("target") then
		local targetName = UnitName("target")
		if targetName and lastAllBossNames[targetName] and not defeatedBosses[targetName] then
			stickyTargetBossName = targetName
		end
	end
	local pinnedBossName = targetLootEnabled and stickyTargetBossName or nil
	if pinnedBossName and defeatedBosses[pinnedBossName] then
		pinnedBossName = nil
	end

	local groups, groupByName = {}, {}
	for _, entry in ipairs(filtered) do
		local group = groupByName[entry.bossName]
		if not group then
			group = { bossName = entry.bossName, entries = {} }
			groupByName[entry.bossName] = group
			table.insert(groups, group)
		end
		table.insert(group.entries, entry)
	end
	for _, group in ipairs(groups) do
		table.sort(group.entries, function(a, b) return a.diff > b.diff end)
	end

	local orderedGroups = groups
	if pinnedBossName then
		local pinnedGroup = groupByName[pinnedBossName]
		if not pinnedGroup and lastAllBossNames[pinnedBossName] then
			-- A real boss in this zone, just with nothing worth showing right now.
			pinnedGroup = { bossName = pinnedBossName, entries = {}, noLoot = true }
		end
		if pinnedGroup then
			orderedGroups = { pinnedGroup }
			for _, group in ipairs(groups) do
				if group.bossName ~= pinnedBossName then
					table.insert(orderedGroups, group)
				end
			end
		end
	end

	-- Move defeated bosses to the very end, preserving relative order otherwise.
	local aliveGroups, deadGroups = {}, {}
	for _, group in ipairs(orderedGroups) do
		if defeatedBosses[group.bossName] then
			table.insert(deadGroups, group)
		else
			table.insert(aliveGroups, group)
		end
	end
	for _, group in ipairs(deadGroups) do
		table.insert(aliveGroups, group)
	end
	orderedGroups = aliveGroups

	local items = {}
	for _, group in ipairs(orderedGroups) do
		local isDefeated = defeatedBosses[group.bossName] or false
		table.insert(items, { isHeader = true, text = group.bossName, isCurrentTarget = (group.bossName == pinnedBossName), isDefeated = isDefeated })
		if group.noLoot then
			table.insert(items, { isNoLoot = true })
		else
			for _, entry in ipairs(group.entries) do
				table.insert(items, entry)
			end
		end
	end

	lootContent:SetHeight(math.max(#items * LOOT_ROW_HEIGHT, VISIBLE_ROWS * LOOT_ROW_HEIGHT))

	for i, item in ipairs(items) do
		local row = lootRowPool[i]
		if not row then
			row = CreateLootRow(i)
			lootRowPool[i] = row
		end
		if item.isHeader then
			SetLootRowAsHeader(row, item.text, item.isCurrentTarget, item.isDefeated)
		elseif item.isNoLoot then
			SetLootRowAsNoLoot(row)
		else
			SetLootRowAsItem(row, item)
		end
		row:Show()
	end
	for i = #items + 1, #lootRowPool do
		lootRowPool[i]:Hide()
	end
end

local function RefreshLootRows(onDone)
	lootStatusText:SetText("|cffffff00Scanning...|r")

	GW.BuildInstanceLootList(function(status, rawList, zoneName, pendingIds)
		rawList = rawList or {}

		-- Only show genuine upgrades - hide downgrades, sidegrades, unusable
		-- items, and non-equippable trophy/quest items alike.
		local filtered = {}
		for _, entry in ipairs(rawList) do
			if entry.diff and entry.diff > 0.05 then
				table.insert(filtered, entry)
			end
		end
		lastFilteredEntries = filtered

		if zoneName ~= lastZoneNameForSticky then
			stickyTargetBossName = nil
			defeatedBosses = {}
			lastZoneNameForSticky = zoneName
		end
		if status == "ok" then
			local allBossNames = {}
			for _, entry in ipairs(rawList) do
				allBossNames[entry.bossName] = true
			end
			lastAllBossNames = allBossNames
		else
			lastAllBossNames = {}
			stickyTargetBossName = nil
		end

		if status == "notInInstance" then
			lootScrollFrame:Hide()
			lootHeaderBoss:Hide()
			lootHeaderScore:Hide()
			lootHeaderDiff:Hide()
			lootRescan:Hide()
			lootStatusText:SetText("")
			dungeonRankPanel:Show()
			RefreshDungeonRankPanel()
			if onDone then onDone() end
			return
		end

		dungeonRankPanel:Hide()
		lootScrollFrame:Show()
		lootHeaderBoss:Show()
		lootHeaderScore:Show()
		lootHeaderDiff:Show()
		lootRescan:Show()

		if status == "noData" then
			lootStatusText:SetText("No AtlasLoot data found for '" .. tostring(zoneName)
				.. "' yet - AtlasLoot's data may still be loading. Try Rescan Instance in a few seconds.")
		else
			local text = string.format("%s: %d upgrade%s (scanned %d item%s)",
				zoneName, #filtered, #filtered == 1 and "" or "s", #rawList, #rawList == 1 and "" or "s")

			-- Some pending items never resolve (likely invalid/removed IDs in
			-- AtlasLoot's data, not actually loading) - only call it "loading"
			-- the first couple of times; after that, be honest that it's stuck.
			if pendingIds and #pendingIds > 0 then
				local stillLoading, gaveUp = 0, 0
				for _, id in ipairs(pendingIds) do
					pendingRetryCounts[id] = (pendingRetryCounts[id] or 0) + 1
					if pendingRetryCounts[id] > PENDING_GIVEUP_THRESHOLD then
						gaveUp = gaveUp + 1
					else
						stillLoading = stillLoading + 1
					end
				end
				if stillLoading > 0 then
					text = text .. string.format(" |cffffff00- loading %d more...|r", stillLoading)
				end
				if gaveUp > 0 then
					text = text .. string.format(" |cff888888- %d item(s) unavailable|r", gaveUp)
				end
			end
			lootStatusText:SetText(text)
		end

		RenderLootRows()

		if onDone then onDone() end
	end)
end

local lootEventFrame = CreateFrame("Frame")
lootEventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
lootEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
lootEventFrame:SetScript("OnEvent", function(self, event)
	if not (lootPanel and lootPanel:IsShown()) then return end
	if event == "PLAYER_TARGET_CHANGED" then
		-- Just re-order the existing results around the new target, not a
		-- rescan - the underlying loot data hasn't changed.
		RenderLootRows()
	else
		RefreshLootRows()
	end
end)

-- Glowing the actual Blizzard loot button too, not just the GW window row -
-- ElvUI and DragonUI (checked directly) both leave LootFrame/LootButtonN as
-- the real Blizzard objects and only re-skin or reposition them, so hooking
-- the same LootFrame_UpdateButton ElvUI itself uses works underneath either.
local GLOW_COLOR_UPGRADE = { 1, 0.85, 0.1 }
-- A distinct color from the upgrade glow, used on quest reward choices when
-- none of the options are an upgrade - highlights whichever one sells for
-- the most instead, so there's still a clear "best pick" among the choices.
local GLOW_COLOR_VENDOR = { 0.3, 0.75, 1.0 }

-- A slow, wide "shine" rather than a fast subtle blink - a big enough alpha
-- swing and a wide enough overlay that it actually catches your eye instead
-- of needing to be looked for.
local lootButtonGlows = {}
local function GetOrCreateButtonGlow(button)
	local glow = lootButtonGlows[button]
	if glow then return glow end
	glow = button:CreateTexture(nil, "OVERLAY")
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", -8, 8)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 8, -8)
	glow:Hide()
	lootButtonGlows[button] = glow
	return glow
end

local lootGlowElapsed = 0
local lootGlowPulseFrame = CreateFrame("Frame")
lootGlowPulseFrame:Hide()
lootGlowPulseFrame:SetScript("OnUpdate", function(self, elapsed)
	lootGlowElapsed = lootGlowElapsed + elapsed
	local pulse = 0.55 + 0.45 * math.abs(math.sin(lootGlowElapsed * 1.3))
	for _, glow in pairs(lootButtonGlows) do
		if glow:IsShown() then
			glow:SetAlpha(pulse)
		end
	end
end)

local function ShowButtonGlow(button, color)
	local glow = GetOrCreateButtonGlow(button)
	glow:SetTexture(color[1], color[2], color[3], 0.9)
	glow:Show()
	lootGlowElapsed = 0
	lootGlowPulseFrame:Show()
end

local function HideButtonGlow(button)
	local glow = lootButtonGlows[button]
	if glow then glow:Hide() end
end

-- Mirrors the slot math ElvUI's own skin uses for LootFrame_UpdateButton, so
-- a given on-screen button index resolves to the right underlying loot slot.
local function RefreshLootButtonGlow(index)
	local button = _G["LootButton" .. index]
	if not button or not LootFrame then return end

	local numLootItems = LootFrame.numLootItems or 0
	local numLootToShow = LOOTFRAME_NUMBUTTONS
	if numLootItems > LOOTFRAME_NUMBUTTONS then
		numLootToShow = numLootToShow - 1
	end
	local slot = (numLootToShow * ((LootFrame.page or 1) - 1)) + index

	local shouldGlow = false
	if index <= numLootToShow and slot <= numLootItems and LootSlotIsItem(slot) then
		local id = GetItemIDFromLink(GetLootSlotLink(slot))
		shouldGlow = id ~= nil and shiningItemIds[id] == true
	end

	if shouldGlow then
		ShowButtonGlow(button, GLOW_COLOR_UPGRADE)
	else
		HideButtonGlow(button)
	end
end

local function RefreshAllLootButtonGlows()
	for index = 1, LOOTFRAME_NUMBUTTONS do
		RefreshLootButtonGlow(index)
	end
end

hooksecurefunc("LootFrame_UpdateButton", RefreshLootButtonGlow)

-- Quest reward buttons get the same glow treatment as loot buttons.
--
-- Originally hooked Blizzard's QuestInfo_ShowRewards (the function ElvUI's
-- own skin hooks for the same buttons), but confirmed via live testing that
-- it never actually fires on this client - whatever custom UI draws the
-- reward panel here doesn't route through it, even though the function
-- still exists as a global. So instead of depending on any specific internal
-- function being the one responsible, just refresh directly off the quest
-- lifecycle events themselves, with a brief repeating re-check afterward in
-- case the buttons populate a moment after the event fires.
local function RefreshQuestRewardGlows()
	if not (MAX_NUM_ITEMS and QuestInfoFrame) then return end

	local questRewardGlow = GW.IsQuestRewardGlowEnabled()
	local choices = {}

	for i = 1, MAX_NUM_ITEMS do
		local item = _G["QuestInfoItem" .. i]
		if item then
			local itemType, itemIndex = item.type, item:GetID()
			local link = itemType
				and (QuestInfoFrame.questLog and GetQuestLogItemLink or GetQuestItemLink)(itemType, itemIndex)
			local isUpgrade = questRewardGlow and link and IsItemLinkAnUpgrade(link)

			if isUpgrade then
				ShowButtonGlow(item, GLOW_COLOR_UPGRADE)
			else
				HideButtonGlow(item)
			end

			if itemType == "choice" and link then
				local _, _, numItems = GetQuestItemInfo(itemType, itemIndex)
				local sellPrice = select(11, GetItemInfo(link)) or 0
				table.insert(choices, { button = item, sellValue = sellPrice * (numItems or 1), isUpgrade = isUpgrade })
			end
		end
	end

	-- Both signals are independent - a trivial upgrade shouldn't hide a much
	-- more lucrative option sitting right next to it. Only skip the vendor
	-- glow when the highest-value choice is already the upgrade, since it's
	-- already glowing gold - no need to show both on one item.
	if questRewardGlow and GW.IsQuestVendorGlowEnabled() and #choices > 1 then
		local best
		for _, choice in ipairs(choices) do
			if choice.sellValue > 0 and (not best or choice.sellValue > best.sellValue) then
				best = choice
			end
		end
		if best and not best.isUpgrade then
			ShowButtonGlow(best.button, GLOW_COLOR_VENDOR)
		end
	end
end

local questRewardWarmElapsed, questRewardWarmTotal = 0, 0
local questRewardWarmFrame = CreateFrame("Frame")
questRewardWarmFrame:Hide()
questRewardWarmFrame:SetScript("OnUpdate", function(self, elapsed)
	questRewardWarmElapsed = questRewardWarmElapsed + elapsed
	questRewardWarmTotal = questRewardWarmTotal + elapsed
	if questRewardWarmElapsed < 0.2 then return end
	questRewardWarmElapsed = 0
	RefreshQuestRewardGlows()
	if questRewardWarmTotal > 1.5 then
		self:Hide()
	end
end)

local questRewardWatcher = CreateFrame("Frame")
questRewardWatcher:RegisterEvent("QUEST_GREETING")
questRewardWatcher:RegisterEvent("QUEST_DETAIL")
questRewardWatcher:RegisterEvent("QUEST_PROGRESS")
questRewardWatcher:RegisterEvent("QUEST_COMPLETE")
questRewardWatcher:SetScript("OnEvent", function()
	RefreshQuestRewardGlows()
	questRewardWarmElapsed, questRewardWarmTotal = 0, 0
	questRewardWarmFrame:Show()
end)

-- Shared upgrade check for anything that might drop: prefer the AtlasLoot
-- boss-recognized list (respects the "instance loot" glow toggle), fall back
-- to direct scoring for anything else (respects the "world drops" toggle).
local function BuildInstanceUpgradeIdSet()
	local instanceUpgradeIds = {}
	for _, entry in ipairs(lastFilteredEntries or {}) do
		local id = GetItemIDFromLink(entry.itemLink)
		if id then instanceUpgradeIds[id] = true end
	end
	return instanceUpgradeIds
end

local function ShouldItemGlow(link, id, instanceUpgradeIds)
	if instanceUpgradeIds[id] then
		return GW.IsInstanceGlowEnabled()
	end
	return GW.IsWorldDropGlowEnabled() and IsItemLinkAnUpgrade(link)
end

-- If anything in the loot window scores as a genuine upgrade, flag it so it
-- shines - any drop anywhere (instance, world, quest), not just items
-- AtlasLoot recognizes as boss-specific. Only a handful of items are ever in
-- a loot window at once, so scoring each one directly here is cheap - no
-- different from what already happens per-item on tooltip hover. Cleared
-- again once loot closes.
local lootDropWatchFrame = CreateFrame("Frame")
lootDropWatchFrame:RegisterEvent("LOOT_OPENED")
lootDropWatchFrame:RegisterEvent("LOOT_CLOSED")
lootDropWatchFrame:SetScript("OnEvent", function(self, event)
	if event == "LOOT_OPENED" then
		local instanceUpgradeIds = BuildInstanceUpgradeIdSet()

		local foundAny = false
		for i = 1, GetNumLootItems() do
			local link = GetLootSlotLink(i)
			local id = GetItemIDFromLink(link)
			if id and ShouldItemGlow(link, id, instanceUpgradeIds) then
				shiningItemIds[id] = true
				foundAny = true
			end
		end

		-- The Blizzard loot frame may have already finished its own update
		-- pass before shiningItemIds was populated just now, so force a
		-- pass ourselves instead of only relying on the hook firing again.
		RefreshAllLootButtonGlows()

		if foundAny and lootPanel and lootPanel:IsShown() then
			RenderLootRows()
		end
	elseif event == "LOOT_CLOSED" then
		for _, glow in pairs(lootButtonGlows) do
			glow:Hide()
		end
		lootGlowPulseFrame:Hide()
		if next(shiningItemIds) then
			shiningItemIds = {}
			if lootPanel and lootPanel:IsShown() then
				RenderLootRows()
			end
		end
	end
end)

-- Need/Greed/Pass roll popups are a separate loot path from the loot window -
-- LOOT_OPENED never fires for someone who's only rolling on another group
-- member's drop (they never open the corpse themselves), so this has to be
-- driven by START_LOOT_ROLL independently rather than reusing LOOT_OPENED.
local function RefreshLootRollGlow()
	-- Stock frames (DragonUI only repositions these, confirmed via its own
	-- source - doesn't replace them). No confirmed inner icon element for
	-- these, so glow the whole box.
	for i = 1, (NUM_GROUP_LOOT_FRAMES or 4) do
		local frame = _G["GroupLootFrame" .. i]
		if frame then
			local shouldGlow = false
			if frame.rollID and frame:IsShown() then
				local link = GetLootRollItemLink(frame.rollID)
				local id = GetItemIDFromLink(link)
				shouldGlow = id ~= nil and shiningItemIds[id] == true
			end
			if shouldGlow then
				ShowButtonGlow(frame, GLOW_COLOR_UPGRADE)
			else
				HideButtonGlow(frame)
			end
		end
	end

	-- ElvUI replaces the roll frame entirely with its own ElvUI_GroupLootFrameN
	-- objects - confirmed via its actual source (Modules/Misc/LootRoll.lua):
	-- each one's icon button is created as CreateFrame("Button",
	-- "$parentIconFrame", frame), globally named ElvUI_GroupLootFrame{N}IconFrame,
	-- and carries .rollID/.link set directly on it. Glow just that icon button
	-- instead of the whole bar. Frames are created lazily in order (1, 2, 3...)
	-- and never destroyed, so stop at the first index that doesn't exist yet.
	for i = 1, 12 do
		local button = _G["ElvUI_GroupLootFrame" .. i .. "IconFrame"]
		if not button then break end
		local shouldGlow = false
		if button.rollID and button:IsVisible() then
			local id = GetItemIDFromLink(button.link)
			shouldGlow = id ~= nil and shiningItemIds[id] == true
		end
		if shouldGlow then
			ShowButtonGlow(button, GLOW_COLOR_UPGRADE)
		else
			HideButtonGlow(button)
		end
	end
end

local lootRollWarmElapsed, lootRollWarmTotal = 0, 0
local lootRollWarmFrame = CreateFrame("Frame")
lootRollWarmFrame:Hide()
lootRollWarmFrame:SetScript("OnUpdate", function(self, elapsed)
	lootRollWarmElapsed = lootRollWarmElapsed + elapsed
	lootRollWarmTotal = lootRollWarmTotal + elapsed
	if lootRollWarmElapsed < 0.2 then return end
	lootRollWarmElapsed = 0
	RefreshLootRollGlow()
	if lootRollWarmTotal > 1.5 then
		self:Hide()
	end
end)

local lootRollWatchFrame = CreateFrame("Frame")
lootRollWatchFrame:RegisterEvent("START_LOOT_ROLL")
lootRollWatchFrame:SetScript("OnEvent", function(self, event, rollId)
	local link = GetLootRollItemLink(rollId)
	local id = GetItemIDFromLink(link)
	if id then
		local instanceUpgradeIds = BuildInstanceUpgradeIdSet()
		if ShouldItemGlow(link, id, instanceUpgradeIds) then
			shiningItemIds[id] = true
			if lootPanel and lootPanel:IsShown() then RenderLootRows() end
		end
	end

	-- frame.rollID may not be populated the instant this event fires, so
	-- keep re-checking for a bit rather than only trying once.
	RefreshLootRollGlow()
	lootRollWarmElapsed, lootRollWarmTotal = 0, 0
	lootRollWarmFrame:Show()
end)

-- Tracks which of this zone's bosses have died this run, via the combat log
-- rather than relying on ever having targeted them - so the list still
-- updates correctly even if you never clicked on the boss yourself.
local bossDeathWatchFrame = CreateFrame("Frame")
bossDeathWatchFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
bossDeathWatchFrame:SetScript("OnEvent", function(self, event, timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName)
	if subevent ~= "UNIT_DIED" and subevent ~= "PARTY_KILL" then return end
	if destName and lastAllBossNames[destName] and not defeatedBosses[destName] then
		defeatedBosses[destName] = true
		if lootPanel and lootPanel:IsShown() then
			RenderLootRows()
		end
	end
end)

-- Temporary diagnostic: /gw bossdiag dumps the live state these two features
-- depend on, without needing to wait for an actual boss kill or item drop.
function GW.DumpBossAndGlowDiag()
	DEFAULT_CHAT_FRAME:AddMessage("GearWeights boss/glow diag:")
	DEFAULT_CHAT_FRAME:AddMessage("  lootPanel exists=" .. tostring(lootPanel ~= nil)
		.. " shown=" .. tostring(lootPanel and lootPanel:IsShown()))
	DEFAULT_CHAT_FRAME:AddMessage("  lastZoneNameForSticky=" .. tostring(lastZoneNameForSticky))
	local bossCount = 0
	for name in pairs(lastAllBossNames) do
		bossCount = bossCount + 1
		DEFAULT_CHAT_FRAME:AddMessage("    boss: " .. tostring(name) .. " defeated=" .. tostring(defeatedBosses[name] or false))
	end
	DEFAULT_CHAT_FRAME:AddMessage("  lastAllBossNames count=" .. bossCount)
	DEFAULT_CHAT_FRAME:AddMessage("  GW.IsInstanceGlowEnabled()=" .. tostring(GW.IsInstanceGlowEnabled and GW.IsInstanceGlowEnabled()))
	DEFAULT_CHAT_FRAME:AddMessage("  GW.IsWorldDropGlowEnabled()=" .. tostring(GW.IsWorldDropGlowEnabled and GW.IsWorldDropGlowEnabled()))
	local shiningCount = 0
	for id in pairs(shiningItemIds) do shiningCount = shiningCount + 1 end
	DEFAULT_CHAT_FRAME:AddMessage("  shiningItemIds count=" .. shiningCount)
	DEFAULT_CHAT_FRAME:AddMessage("  lastFilteredEntries count=" .. #(lastFilteredEntries or {}))
end

--------------------------------------------------------------------------------
-- Main frame + tab switching
--------------------------------------------------------------------------------

local function ShowStatsTab()
	lootPanel:Hide()
	settingsPanel:Hide()
	statsPanel:Show()
	statsTabBtn:Disable()
	lootTabBtn:Enable()
	settingsTabBtn:Enable()
	RefreshRows()
end

local function ShowLootTab()
	statsPanel:Hide()
	settingsPanel:Hide()
	lootPanel:Show()
	lootTabBtn:Disable()
	statsTabBtn:Enable()
	settingsTabBtn:Enable()
	RefreshLootRows()
end

local function ShowSettingsTab()
	statsPanel:Hide()
	lootPanel:Hide()
	settingsPanel:Show()
	settingsTabBtn:Disable()
	statsTabBtn:Enable()
	lootTabBtn:Enable()
	-- Locked slots can also change via ctrl+click on the character pane, so
	-- sync the checkboxes with current state each time this tab is shown.
	if lockedSlotChecks then
		for slotId, check in pairs(lockedSlotChecks) do
			check:SetChecked(GW.IsSlotLocked(slotId))
		end
	end
end

-- "Mark of Triumph" is most likely a currency (WotLK's badge-currency system,
-- the same mechanism as the real "Emblem of Triumph"), but falls back to a
-- bag-item count in case Ascension implemented it as an actual item instead -
-- covers both without guessing which one this server actually uses.
-- Returns count, icon, currencyIndex (currencyIndex is what
-- GameTooltip:SetCurrencyToken() needs for the real native tooltip).
local function FindCurrencyInfo(name)
	if not (GetCurrencyListSize and GetCurrencyListInfo) then return nil end
	for i = 1, GetCurrencyListSize() do
		local currName, isHeader, _, _, _, count, _, icon = GetCurrencyListInfo(i)
		if not isHeader and currName == name then
			return count, icon, i
		end
	end
	return nil
end

-- Returns count, icon, currencyIndex (currencyIndex is nil in the bag-item
-- fallback case). Exposed on GW so vendor price rows elsewhere in this file
-- can show the exact same icon and tooltip as the bottom-bar tracker.
function GW.GetMarkOfTriumphInfo()
	local count, icon, currencyIndex = FindCurrencyInfo("Mark of Triumph")
	if count then return count, icon, currencyIndex end
	if GetItemCount then
		local ok, itemCount = pcall(GetItemCount, "Mark of Triumph")
		if ok and itemCount and itemCount > 0 then
			local iconOk, itemIcon = pcall(GetItemIcon, "Mark of Triumph")
			return itemCount, iconOk and itemIcon or nil, nil
		end
	end
	return 0, nil, nil
end

-- Shared by the bottom-bar tracker and any vendor price row showing a Mark of
-- Triumph cost - assumes GameTooltip:SetOwner() was already called.
function GW.ShowMarkOfTriumphTooltip()
	local _, _, currencyIndex = GW.GetMarkOfTriumphInfo()
	if currencyIndex then
		GameTooltip:SetCurrencyToken(currencyIndex)
	else
		local _, itemLink = GetItemInfo("Mark of Triumph")
		if itemLink then
			GameTooltip:SetHyperlink(itemLink)
		else
			GameTooltip:AddLine("Mark of Triumph")
		end
	end
end

local MIN_FRAME_WIDTH, MIN_FRAME_HEIGHT = 460, 300
-- Reserved strip across the bottom of the window for the currency readout,
-- so tab content (which used to reach all the way to y=0) can't scroll or
-- grow text over top of it.
local BOTTOM_BAR_HEIGHT = 30

local function CreateMainFrame()
	local f = CreateFrame("Frame", "GearWeightsFrame", UIParent)
	GearWeightsDB = GearWeightsDB or {}
	local size = GearWeightsDB.frameSize
	f:SetSize(size and size.width or 460, size and size.height or 440)
	local pos = GearWeightsDB.framePosition
	if pos then
		f:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
	else
		f:SetPoint("CENTER")
	end
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		GearWeightsDB.framePosition = { point = point, relativePoint = relativePoint, x = x, y = y }
	end)
	f:SetResizable(true)
	f:SetMinResize(MIN_FRAME_WIDTH, MIN_FRAME_HEIGHT)
	f:SetMaxResize(900, 800)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()

	local sizer = CreateFrame("Button", nil, f)
	sizer:SetSize(16, 16)
	sizer:SetPoint("BOTTOMRIGHT", -6, 6)
	sizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	sizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	sizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	sizer:SetScript("OnMouseDown", function()
		f:StartSizing("BOTTOMRIGHT")
	end)
	sizer:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		GearWeightsDB.frameSize = { width = f:GetWidth(), height = f:GetHeight() }
	end)

	local currencyIcon = f:CreateTexture(nil, "ARTWORK")
	currencyIcon:SetSize(18, 18)
	currencyIcon:SetPoint("BOTTOMLEFT", 14, 10)

	local currencyText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	currencyText:SetPoint("LEFT", currencyIcon, "RIGHT", 4, 0)

	local currencyHitbox = CreateFrame("Frame", nil, f)
	currencyHitbox:SetPoint("TOPLEFT", currencyIcon, "TOPLEFT", 0, 0)
	currencyHitbox:SetPoint("BOTTOMRIGHT", currencyText, "BOTTOMRIGHT", 0, 0)
	currencyHitbox:EnableMouse(true)
	currencyHitbox:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GW.ShowMarkOfTriumphTooltip()
		GameTooltip:Show()
	end)
	currencyHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local clickHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	clickHint:SetPoint("LEFT", currencyText, "RIGHT", 16, 0)
	clickHint:SetPoint("RIGHT", -30, 0)
	clickHint:SetJustifyH("RIGHT")
	clickHint:SetWordWrap(false)
	clickHint:SetText("Alt+Click item: add to WishList  |  Ctrl+Click item: lock/unlock slot")

	local function RefreshCurrencyText()
		local count, icon = GW.GetMarkOfTriumphInfo()
		currencyIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		currencyText:SetText(tostring(count))
	end
	RefreshCurrencyText()
	f:HookScript("OnShow", RefreshCurrencyText)

	local currencyWatcher = CreateFrame("Frame", nil, f)
	currencyWatcher:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
	currencyWatcher:RegisterEvent("BAG_UPDATE")
	currencyWatcher:SetScript("OnEvent", RefreshCurrencyText)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("GearWeights")

	local version = GetAddOnMetadata("GearWeights", "Version")
	if version then
		local versionText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
		versionText:SetPoint("TOPRIGHT", -30, -12)
		versionText:SetText("v" .. version)
	end

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() f:Hide() end)

	lootTabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	lootTabBtn:SetSize(95, 22)
	lootTabBtn:SetPoint("TOP", title, "BOTTOM", -101, -10)
	lootTabBtn:SetText("Instance Loot")
	lootTabBtn:SetScript("OnClick", ShowLootTab)

	statsTabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	statsTabBtn:SetSize(95, 22)
	statsTabBtn:SetPoint("LEFT", lootTabBtn, "RIGHT", 6, 0)
	statsTabBtn:SetText("Stat Weights")
	statsTabBtn:SetScript("OnClick", ShowStatsTab)

	settingsTabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	settingsTabBtn:SetSize(95, 22)
	settingsTabBtn:SetPoint("LEFT", statsTabBtn, "RIGHT", 6, 0)
	settingsTabBtn:SetText("Settings")
	settingsTabBtn:SetScript("OnClick", ShowSettingsTab)

	--------------------------------------------------------------------
	-- Stats panel
	--------------------------------------------------------------------
	statsPanel = CreateFrame("Frame", nil, f)
	statsPanel:SetPoint("TOPLEFT", 0, -66)
	statsPanel:SetPoint("BOTTOMRIGHT", 0, BOTTOM_BAR_HEIGHT)

	specLabel = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	specLabel:SetPoint("TOP", 0, -4)

	local rescan = CreateFrame("Button", nil, statsPanel, "UIPanelButtonTemplate")
	rescan:SetSize(150, 22)
	rescan:SetPoint("BOTTOM", 0, 16)
	rescan:SetText("Rescan Equipped Gear")
	rescan:SetScript("OnClick", function()
		rescan:Disable()
		rescan:SetText("Scanning...")
		local delayFrame = CreateFrame("Frame")
		local elapsed = 0
		delayFrame:SetScript("OnUpdate", function(self, delta)
			elapsed = elapsed + delta
			if elapsed >= 0.4 then
				self:SetScript("OnUpdate", nil)
				for slotId = 1, 19 do
					local link = GetInventoryItemLink("player", slotId)
					if link then GW.GetItemStats(link) end
				end
				RefreshRows()
				rescan:SetText("Rescan Equipped Gear")
				rescan:Enable()
			end
		end)
	end)

	local importBtn = CreateFrame("Button", nil, statsPanel, "UIPanelButtonTemplate")
	importBtn:SetSize(80, 22)
	importBtn:SetPoint("RIGHT", rescan, "LEFT", -6, 0)
	importBtn:SetText("Import")
	importBtn:SetScript("OnClick", ShowImportPopup)

	local exportBtn = CreateFrame("Button", nil, statsPanel, "UIPanelButtonTemplate")
	exportBtn:SetSize(80, 22)
	exportBtn:SetPoint("LEFT", rescan, "RIGHT", 6, 0)
	exportBtn:SetText("Export")
	exportBtn:SetScript("OnClick", ShowExportPopup)

	scrollFrame = CreateFrame("ScrollFrame", "GearWeightsScrollFrame", statsPanel, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", 20, -20)
	scrollFrame:SetPoint("BOTTOMRIGHT", -34, 48)

	content = CreateFrame("Frame", nil, scrollFrame)
	content:SetSize(340, VISIBLE_ROWS * ROW_HEIGHT)
	scrollFrame:SetScrollChild(content)

	local headerLabel = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headerLabel:SetPoint("BOTTOMLEFT", scrollFrame, "TOPLEFT", 0, 4)
	headerLabel:SetText("Stat")
	local headerWeight = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headerWeight:SetPoint("BOTTOMRIGHT", scrollFrame, "TOPRIGHT", -4, 4)
	headerWeight:SetText("Weight")

	--------------------------------------------------------------------
	-- Loot panel
	--------------------------------------------------------------------
	lootPanel = CreateFrame("Frame", nil, f)
	lootPanel:SetPoint("TOPLEFT", 0, -66)
	lootPanel:SetPoint("BOTTOMRIGHT", 0, BOTTOM_BAR_HEIGHT)
	lootPanel:Hide()

	lootStatusText = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	lootStatusText:SetPoint("TOP", 0, -6)
	lootStatusText:SetWidth(420)
	lootStatusText:SetJustifyH("CENTER")

	lootRescan = CreateFrame("Button", nil, lootPanel, "UIPanelButtonTemplate")
	lootRescan:SetSize(150, 22)
	lootRescan:SetPoint("BOTTOM", 0, 16)
	lootRescan:SetText("Rescan Instance")
	lootRescan:SetScript("OnClick", function()
		lootRescan:Disable()
		lootRescan:SetText("Scanning...")
		RefreshLootRows(function()
			lootRescan:SetText("Rescan Instance")
			lootRescan:Enable()
		end)
	end)

	lootScrollFrame = CreateFrame("ScrollFrame", "GearWeightsLootScrollFrame", lootPanel, "UIPanelScrollFrameTemplate")
	lootScrollFrame:SetPoint("TOPLEFT", 20, -46)
	lootScrollFrame:SetPoint("BOTTOMRIGHT", -34, 48)

	lootContent = CreateFrame("Frame", nil, lootScrollFrame)
	lootContent:SetSize(400, VISIBLE_ROWS * LOOT_ROW_HEIGHT)
	lootScrollFrame:SetScrollChild(lootContent)

	lootHeaderBoss = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	lootHeaderBoss:SetPoint("BOTTOMLEFT", lootScrollFrame, "TOPLEFT", 2, 4)
	lootHeaderBoss:SetText("Boss / Item")
	lootHeaderScore = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	lootHeaderScore:SetPoint("BOTTOMRIGHT", lootScrollFrame, "TOPRIGHT", -110, 4)
	lootHeaderScore:SetText("Score")
	lootHeaderDiff = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	lootHeaderDiff:SetPoint("BOTTOMRIGHT", lootScrollFrame, "TOPRIGHT", -4, 4)
	lootHeaderDiff:SetText("vs Equipped")

	--------------------------------------------------------------------
	-- Out-of-instance dungeon/raid ranking panel (swapped in for the loot
	-- list + headers above when you're not in an instance)
	--------------------------------------------------------------------
	dungeonRankPanel = CreateFrame("Frame", nil, lootPanel)
	dungeonRankPanel:SetPoint("TOPLEFT", lootPanel, "TOPLEFT", 18, -26)
	dungeonRankPanel:SetPoint("BOTTOMRIGHT", lootPanel, "BOTTOMRIGHT", -18, 4)
	dungeonRankPanel:Hide()

	local tierChecks = {}
	local function CreateTierCheck(tier, label, anchorTo)
		local check = CreateFrame("CheckButton", nil, dungeonRankPanel, "UICheckButtonTemplate")
		check:SetSize(18, 18)
		if anchorTo then
			check:SetPoint("LEFT", anchorTo, "RIGHT", 60, 0)
		else
			check:SetPoint("TOPLEFT", 2, -2)
		end
		check:SetChecked(GW.IsDungeonRankTierEnabled(tier))
		check:SetScript("OnClick", function(self)
			GW.SetDungeonRankTierEnabled(tier, self:GetChecked() and true or false)
			RefreshDungeonRankPanel()
			GW.RunDungeonRankingScan(RefreshDungeonRankPanel)
		end)
		local text = dungeonRankPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", check, "RIGHT", 2, 0)
		text:SetText(label)
		tierChecks[tier] = check
		return check
	end

	local normalCheck = CreateTierCheck("normal", "Normal")
	local heroicCheck = CreateTierCheck("heroic", "Heroic", normalCheck)
	CreateTierCheck("mythic", "Mythic", heroicCheck)

	--------------------------------------------------------------------
	-- Weapon baseline display - 3 slot icons (Two-Hand / Main Hand / Off
	-- Hand) mimicking the character pane's weapon slots, showing whichever
	-- setup is currently tracked as "equipped" for scoring purposes. Click
	-- any of them to lock/unlock the baseline (see GW.SetWeaponBaselineLocked
	-- in GearWeightsLoot.lua) - locking freezes it against temporary
	-- quest-required weapon swaps instead of always following live gear.
	--------------------------------------------------------------------
	local weaponSlotButtonIndex = 0
	local function CreateWeaponSlotButton(anchorTo)
		weaponSlotButtonIndex = weaponSlotButtonIndex + 1
		local button = CreateFrame("Button", "GearWeightsWeaponSlotButton" .. weaponSlotButtonIndex, dungeonRankPanel, "ItemButtonTemplate")
		button:SetSize(30, 30)
		if anchorTo then
			button:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
		else
			button:SetPoint("TOPRIGHT", -4, -4)
		end
		return button
	end

	local weaponBaselineTwoHandButton = CreateWeaponSlotButton()
	local weaponBaselineMainHandButton = CreateWeaponSlotButton(weaponBaselineTwoHandButton)
	local weaponBaselineOffHandButton = CreateWeaponSlotButton(weaponBaselineMainHandButton)
	local weaponSlotButtons = { weaponBaselineTwoHandButton, weaponBaselineMainHandButton, weaponBaselineOffHandButton }

	local weaponBaselineLockIcon = dungeonRankPanel:CreateTexture(nil, "OVERLAY")
	weaponBaselineLockIcon:SetSize(14, 14)
	weaponBaselineLockIcon:SetPoint("BOTTOMRIGHT", weaponBaselineOffHandButton, "TOPRIGHT", 2, 2)
	weaponBaselineLockIcon:SetTexture("Interface\\BUTTONS\\LockButton-Locked-Up")
	weaponBaselineLockIcon:Hide()

	local function RefreshWeaponBaselineDisplay()
		local mh, oh = GW.GetWeaponBaselineLinks()
		local is2H = false
		if mh then
			local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mh)
			is2H = mhEquipLoc == "INVTYPE_2HWEAPON"
		end

		local function SetSlotIcon(button, link)
			if link then
				local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(link)
				SetItemButtonTexture(button, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
			else
				SetItemButtonTexture(button, nil)
			end
			button.link = link
		end

		SetSlotIcon(weaponBaselineTwoHandButton, is2H and mh or nil)
		SetSlotIcon(weaponBaselineMainHandButton, (not is2H) and mh or nil)
		SetSlotIcon(weaponBaselineOffHandButton, (not is2H) and oh or nil)

		weaponBaselineLockIcon:SetShown(GW.IsWeaponBaselineLocked())
	end
	GW.RefreshWeaponBaselineDisplay = RefreshWeaponBaselineDisplay

	local function ToggleWeaponBaselineLock()
		GW.SetWeaponBaselineLocked(not GW.IsWeaponBaselineLocked())
		RefreshWeaponBaselineDisplay()
		if GW.NotifyWeightsChanged then GW.NotifyWeightsChanged() end
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: weapon baseline is now " ..
			(GW.IsWeaponBaselineLocked()
				and "|cffff4444locked|r - won't change until you unlock it"
				or "|cff00ff00dynamic|r - follows whatever you have equipped"))
	end

	local weaponSlotLabels = { "Two-Hand Weapon", "Main Hand", "Off Hand" }
	for i, button in ipairs(weaponSlotButtons) do
		button:SetScript("OnClick", ToggleWeaponBaselineLock)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			if self.link then
				GameTooltip:SetHyperlink(self.link)
			else
				GameTooltip:AddLine(weaponSlotLabels[i])
				GameTooltip:AddLine("Empty", 0.6, 0.6, 0.6)
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(GW.IsWeaponBaselineLocked()
				and "|cffff4444Locked|r - click to unlock (follow equipped gear again)"
				or "|cff00ff00Dynamic|r - click to lock this as your comparison weapon(s)")
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	RefreshWeaponBaselineDisplay()

	local viewBySlotCheck = CreateFrame("CheckButton", nil, dungeonRankPanel, "UICheckButtonTemplate")
	viewBySlotCheck:SetSize(18, 18)
	viewBySlotCheck:SetPoint("TOPLEFT", 0, -24)
	viewBySlotCheck:SetChecked(dungeonRankViewMode == "slot")
	viewBySlotCheck:SetScript("OnClick", function(self)
		dungeonRankViewMode = self:GetChecked() and "slot" or "zone"
		RefreshDungeonRankPanel()
	end)
	local viewBySlotLabel = dungeonRankPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	viewBySlotLabel:SetPoint("LEFT", viewBySlotCheck, "RIGHT", 2, 0)
	viewBySlotLabel:SetText("View by Slot (best upgrade per slot, highest to lowest)")

	-- Stacked on its own row below the checkboxes rather than sharing a row
	-- with them - a fixed-width button sharing a row with variable-width
	-- checkbox labels doesn't reliably fit once the window is resized narrow.
	local dungeonRankRescan = CreateFrame("Button", nil, dungeonRankPanel, "UIPanelButtonTemplate")
	dungeonRankRescan:SetSize(170, 20)
	dungeonRankRescan:SetPoint("TOPLEFT", 0, -46)
	dungeonRankRescan:SetText("Scan All Dungeons/Raids")
	dungeonRankRescan:SetScript("OnClick", function()
		GW.RunDungeonRankingScan(RefreshDungeonRankPanel)
		RefreshDungeonRankPanel()
	end)

	dungeonRankStatusText = dungeonRankPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dungeonRankStatusText:SetPoint("TOPLEFT", 2, -72)
	dungeonRankStatusText:SetPoint("RIGHT", -2, 0)
	dungeonRankStatusText:SetJustifyH("LEFT")

	dungeonRankScrollFrame = CreateFrame("ScrollFrame", "GearWeightsDungeonRankScrollFrame", dungeonRankPanel, "UIPanelScrollFrameTemplate")
	dungeonRankScrollFrame:SetPoint("TOPLEFT", 2, -92)
	dungeonRankScrollFrame:SetPoint("BOTTOMRIGHT", -34, 2)

	dungeonRankContent = CreateFrame("Frame", nil, dungeonRankScrollFrame)
	dungeonRankContent:SetSize(360, VISIBLE_ROWS * DUNGEON_RANK_ROW_HEIGHT)
	dungeonRankScrollFrame:SetScrollChild(dungeonRankContent)

	-- Re-lay-out columns whenever the window (and so this scrollframe) is
	-- resized, instead of staying stuck at whatever width existed on creation.
	dungeonRankScrollFrame:SetScript("OnSizeChanged", function()
		if dungeonRankPanel:IsShown() then RefreshDungeonRankPanel() end
	end)

	--------------------------------------------------------------------
	-- Settings panel
	--------------------------------------------------------------------
	settingsPanel = CreateFrame("Frame", nil, f)
	settingsPanel:SetPoint("TOPLEFT", 0, -66)
	settingsPanel:SetPoint("BOTTOMRIGHT", 0, BOTTOM_BAR_HEIGHT)
	settingsPanel:Hide()

	-- Unlike the other two tabs, this content is a static fixed set (not
	-- data-driven), but it can still be taller than the window once resized
	-- smaller - needs to scroll instead of just overflowing past the bottom.
	local settingsScrollFrame = CreateFrame("ScrollFrame", "GearWeightsSettingsScrollFrame", settingsPanel, "UIPanelScrollFrameTemplate")
	settingsScrollFrame:SetPoint("TOPLEFT", 4, -4)
	settingsScrollFrame:SetPoint("BOTTOMRIGHT", -28, 4)

	local settingsContent = CreateFrame("Frame", nil, settingsScrollFrame)
	settingsContent:SetSize(400, 560)
	settingsScrollFrame:SetScrollChild(settingsContent)

	local settingsHeader = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	settingsHeader:SetPoint("TOPLEFT", 12, -10)
	settingsHeader:SetText("Instance Loot")

	local function CreateSettingsCheckbox(anchorTo, yOffset, label, getFn, setFn, onChanged)
		local check = CreateFrame("CheckButton", nil, settingsContent, "UICheckButtonTemplate")
		if anchorTo then
			check:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)
		else
			check:SetPoint("TOPLEFT", 16, yOffset)
		end
		check:SetSize(20, 20)
		check:SetChecked(getFn())
		check:SetScript("OnClick", function(self)
			setFn(self:GetChecked() and true or false)
			if onChanged then onChanged() end
		end)
		local text = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", check, "RIGHT", 2, 0)
		text:SetText(label)
		return check
	end

	local autoPopupCheck = CreateSettingsCheckbox(settingsHeader, -8,
		"Auto-show upgrades when zoning into an instance",
		GW.IsAutoPopupEnabled, GW.SetAutoPopupEnabled)

	local targetLootCheck = CreateSettingsCheckbox(autoPopupCheck, -24,
		"Target Loot - pin your current target's boss to the top",
		GW.IsTargetLootEnabled, GW.SetTargetLootEnabled, RenderLootRows)

	local glowHeader = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	glowHeader:SetPoint("TOPLEFT", targetLootCheck, "BOTTOMLEFT", 0, -30)
	glowHeader:SetText("Glow Effects")

	local glowInstanceCheck = CreateSettingsCheckbox(glowHeader, -8,
		"Glow boss/instance loot when it drops",
		GW.IsInstanceGlowEnabled, GW.SetInstanceGlowEnabled)

	local glowWorldCheck = CreateSettingsCheckbox(glowInstanceCheck, -24,
		"Glow world drops that are upgrades",
		GW.IsWorldDropGlowEnabled, GW.SetWorldDropGlowEnabled)

	local glowQuestCheck = CreateSettingsCheckbox(glowWorldCheck, -24,
		"Glow quest rewards that are upgrades",
		GW.IsQuestRewardGlowEnabled, GW.SetQuestRewardGlowEnabled)

	local glowQuestVendorCheck = CreateSettingsCheckbox(glowQuestCheck, -24,
		"Glow highest-value quest reward when no choice is an upgrade",
		GW.IsQuestVendorGlowEnabled, GW.SetQuestVendorGlowEnabled)

	local lockedSlotsHeader = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	lockedSlotsHeader:SetPoint("TOPLEFT", glowQuestVendorCheck, "BOTTOMLEFT", 0, -30)
	lockedSlotsHeader:SetText("Locked Slots")

	local lockedSlotsHint = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	lockedSlotsHint:SetPoint("TOPLEFT", lockedSlotsHeader, "BOTTOMLEFT", 0, -2)
	lockedSlotsHint:SetText("Ctrl+click an upgrade item in the Instance Loot list to toggle - locked slots are still scored, just never counted as an upgrade.")
	lockedSlotsHint:SetWidth(370)
	lockedSlotsHint:SetJustifyH("LEFT")

	local LOCKED_SLOT_COLUMNS = 2
	local LOCKED_SLOT_COL_WIDTH = 190
	local LOCKED_SLOT_ROW_HEIGHT = 22
	lockedSlotChecks = {}
	for i, slotId in ipairs(GW.LOCKABLE_SLOT_ORDER) do
		local col = (i - 1) % LOCKED_SLOT_COLUMNS
		local row = math.floor((i - 1) / LOCKED_SLOT_COLUMNS)
		local check = CreateFrame("CheckButton", nil, settingsContent, "UICheckButtonTemplate")
		check:SetSize(18, 18)
		check:SetPoint("TOPLEFT", lockedSlotsHint, "BOTTOMLEFT", col * LOCKED_SLOT_COL_WIDTH, -20 - row * LOCKED_SLOT_ROW_HEIGHT)
		check:SetChecked(GW.IsSlotLocked(slotId))
		check:SetScript("OnClick", function(self)
			GW.SetSlotLocked(slotId, self:GetChecked() and true or false)
		end)
		local text = settingsContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", check, "RIGHT", 2, 0)
		text:SetText(GW.SLOT_LOCK_LABEL[slotId])
		lockedSlotChecks[slotId] = check
	end

	return f
end

function GearWeightsUI_Toggle()
	if not mainFrame then
		mainFrame = CreateMainFrame()
	end
	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		mainFrame:Show()
		ShowLootTab()
	end
end

-- Forces the main window open to the Instance Loot tab (used by the zone-in
-- auto-popup), rather than toggling like /gw does.
function GW.OpenInstanceLootTab()
	if not mainFrame then
		mainFrame = CreateMainFrame()
	end
	mainFrame:Show()
	ShowLootTab()
end
