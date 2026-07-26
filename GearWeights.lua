GearWeights = {}
local GW = GearWeights

local scanTable = {}

--------------------------------------------------------------------------------
-- Base64 (standalone, no external library dependency)
--------------------------------------------------------------------------------

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64Lookup, b64Chars = {}, {}
for i = 1, #B64_CHARS do
	local ch = B64_CHARS:sub(i, i)
	b64Lookup[ch] = i - 1
	b64Chars[i - 1] = ch
end

local function Base64Encode(data)
	local out = {}
	local len = #data
	local i = 1
	while i <= len do
		local b1 = data:byte(i)
		local b2 = data:byte(i + 1)
		local b3 = data:byte(i + 2)

		local n1 = math.floor(b1 / 4)
		local n2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
		local n3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
		local n4 = b3 and (b3 % 64) or nil

		table.insert(out, b64Chars[n1])
		table.insert(out, b64Chars[n2])
		table.insert(out, n3 and b64Chars[n3] or "=")
		table.insert(out, n4 and b64Chars[n4] or "=")

		i = i + 3
	end
	return table.concat(out)
end

local function Base64Decode(data)
	data = data:gsub("[^A-Za-z0-9%+%/%=]", "")
	local out = {}
	local i = 1
	local len = #data
	while i <= len do
		local s1, s2, s3, s4 = data:sub(i, i), data:sub(i + 1, i + 1), data:sub(i + 2, i + 2), data:sub(i + 3, i + 3)
		local c1, c2 = b64Lookup[s1] or 0, b64Lookup[s2] or 0
		local c3, c4 = b64Lookup[s3], b64Lookup[s4]

		table.insert(out, string.char(c1 * 4 + math.floor(c2 / 16)))
		if s3 ~= "" and s3 ~= "=" then
			table.insert(out, string.char((c2 % 16) * 16 + math.floor((c3 or 0) / 4)))
		end
		if s4 ~= "" and s4 ~= "=" then
			table.insert(out, string.char(((c3 or 0) % 4) * 64 + (c4 or 0)))
		end
		i = i + 4
	end
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- Flat JSON (this format is always a single-level object of number values,
-- so a full JSON parser isn't needed)
--------------------------------------------------------------------------------

local function FlatJsonEncode(tbl)
	local parts = {}
	for k, v in pairs(tbl) do
		table.insert(parts, string.format('"%s":%s', k, tostring(v)))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function FlatJsonDecode(str)
	local result = {}
	for key, val in str:gmatch('"([%w_]+)"%s*:%s*(-?[%d%.]+)') do
		result[key] = tonumber(val)
	end
	return result
end

--------------------------------------------------------------------------------
-- bisbeard.com stat weight import/export mapping
--
-- Maps bisbeard's camelCase keys to the friendly stat label the game itself
-- provides via GetItemStats() discovery. Anything not yet discovered on your
-- gear stays "pending" and is applied automatically the first time you
-- encounter that stat, rather than guessing a raw key name that might be wrong.
--------------------------------------------------------------------------------

local bisbeardKeyToLabel = {
	intellect = "Intellect",
	strength = "Strength",
	agility = "Agility",
	stamina = "Stamina",
	spirit = "Spirit",
	spellPower = "Spell Power",
	spellDamage = "Spell Power", -- same unified stat as spellPower in this era
	healingPower = "Bonus Healing",
	critRating = "Critical Strike Rating",
	hasteRating = "Haste Rating",
	hitRating = "Hit Rating",
	resilienceRating = "Resilience Rating",
	mp5 = "Mana Per 5 Sec.",
	hp5 = "Health Per 5 Sec.",
	weaponDps = "Damage Per Second",
	rangedDps = "Ranged Damage Per Second",
	attackPower = "Attack Power",
	rangedAttackPower = "Ranged Attack Power",
	feralAttackPower = "Feral Attack Power",
	armorPenetration = "Armor Penetration Rating",
	spellPenetration = "Spell Penetration",
	expertise = "Expertise Rating",
	armor = "Armor",
	defense = "Defense Rating",
	dodge = "Dodge Rating",
	parry = "Parry Rating",
	block = "Block Rating",
	blockValue = "Block Value",
	shieldBlockValue = "Block Value",
	fireResist = "Fire Resistance",
	arcaneResist = "Arcane Resistance",
	shadowResist = "Shadow Resistance",
	frostResist = "Frost Resistance",
	natureResist = "Nature Resistance",
	-- health, mana, and the per-school spell power fields aren't mapped: they
	-- don't correspond to real GetItemStats() keys on this client as far as
	-- I've confirmed, so they're intentionally skipped rather than guessed.
}

-- Only these stats are ever shown on the Stat Weights tab, importable from a
-- bisbeard.com export, or counted toward a score - matches bisbeard's basic
-- (non-"Advanced Mode") stat list exactly. Anything else GetItemStats() finds
-- on a real item (Armor, Defense/Dodge/Parry/Block, PvE Power, etc.) is
-- discovered internally but never surfaced or weighted, since the user
-- manages weights via manual entry or bisbeard export and doesn't want extra
-- stats appearing that aren't part of that source of truth.
GW.CANONICAL_STAT_LABELS = {
	["Strength"] = true, ["Agility"] = true, ["Stamina"] = true, ["Intellect"] = true, ["Spirit"] = true,
	["Critical Strike Rating"] = true, ["Hit Rating"] = true, ["Haste Rating"] = true, ["Resilience Rating"] = true,
	["Mana Per 5 Sec."] = true, ["Health Per 5 Sec."] = true,
	["Attack Power"] = true, ["Spell Power"] = true, ["Bonus Healing"] = true,
	["Armor Penetration Rating"] = true, ["Spell Penetration"] = true, ["Expertise Rating"] = true,
	["Fire Resistance"] = true, ["Arcane Resistance"] = true, ["Shadow Resistance"] = true,
	["Frost Resistance"] = true, ["Nature Resistance"] = true,
}

function GW.IsCanonicalStatKey(key)
	local known = GearWeightsDB and GearWeightsDB.knownStats
	local label = known and known[key]
	return label ~= nil and GW.CANONICAL_STAT_LABELS[label] == true
end

local slotsForEquipLoc = {
	INVTYPE_HEAD = { INVSLOT_HEAD },
	INVTYPE_NECK = { INVSLOT_NECK },
	INVTYPE_SHOULDER = { INVSLOT_SHOULDER },
	INVTYPE_CHEST = { INVSLOT_CHEST },
	INVTYPE_ROBE = { INVSLOT_CHEST },
	INVTYPE_WAIST = { INVSLOT_WAIST },
	INVTYPE_LEGS = { INVSLOT_LEGS },
	INVTYPE_FEET = { INVSLOT_FEET },
	INVTYPE_WRIST = { INVSLOT_WRIST },
	INVTYPE_HAND = { INVSLOT_HAND },
	INVTYPE_FINGER = { INVSLOT_FINGER1, INVSLOT_FINGER2 },
	INVTYPE_TRINKET = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 },
	INVTYPE_CLOAK = { INVSLOT_BACK },
	INVTYPE_WEAPON = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
	INVTYPE_SHIELD = { INVSLOT_OFFHAND },
	INVTYPE_HOLDABLE = { INVSLOT_OFFHAND },
	INVTYPE_2HWEAPON = { INVSLOT_MAINHAND },
	INVTYPE_WEAPONMAINHAND = { INVSLOT_MAINHAND },
	INVTYPE_WEAPONOFFHAND = { INVSLOT_OFFHAND },
	INVTYPE_RANGED = { INVSLOT_RANGED },
	INVTYPE_RANGEDRIGHT = { INVSLOT_RANGED },
	INVTYPE_THROWN = { INVSLOT_RANGED },
	INVTYPE_RELIC = { INVSLOT_RANGED },
}

local slotLabels = {
	[INVSLOT_FINGER1] = "Ring 1", [INVSLOT_FINGER2] = "Ring 2",
	[INVSLOT_TRINKET1] = "Trinket 1", [INVSLOT_TRINKET2] = "Trinket 2",
	[INVSLOT_MAINHAND] = "Main Hand", [INVSLOT_OFFHAND] = "Off Hand",
}

local otherWeaponSlot = { [INVSLOT_MAINHAND] = INVSLOT_OFFHAND, [INVSLOT_OFFHAND] = INVSLOT_MAINHAND }

-- Shared with GearWeightsUI.lua (Settings tab checklist) and the character
-- pane ctrl+click handler below, so both stay in sync with one list.
GW.SLOT_LOCK_LABEL = {
	[INVSLOT_HEAD] = "Head", [INVSLOT_NECK] = "Neck", [INVSLOT_SHOULDER] = "Shoulder",
	[INVSLOT_BACK] = "Back", [INVSLOT_CHEST] = "Chest", [INVSLOT_WRIST] = "Wrist",
	[INVSLOT_HAND] = "Hands", [INVSLOT_WAIST] = "Waist", [INVSLOT_LEGS] = "Legs",
	[INVSLOT_FEET] = "Feet", [INVSLOT_FINGER1] = "Ring 1", [INVSLOT_FINGER2] = "Ring 2",
	[INVSLOT_TRINKET1] = "Trinket 1", [INVSLOT_TRINKET2] = "Trinket 2",
	[INVSLOT_MAINHAND] = "Main Hand", [INVSLOT_OFFHAND] = "Off Hand", [INVSLOT_RANGED] = "Ranged",
}
GW.LOCKABLE_SLOT_ORDER = {
	INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_BACK, INVSLOT_CHEST,
	INVSLOT_WRIST, INVSLOT_HAND, INVSLOT_WAIST, INVSLOT_LEGS, INVSLOT_FEET,
	INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2,
	INVSLOT_MAINHAND, INVSLOT_OFFHAND, INVSLOT_RANGED,
}

-- Ctrl+click an upgrade item shown in the /gw window (Instance Loot or the
-- dungeon/raid ranking list) to toggle "ignore upgrades here" for whichever
-- slot(s) that item would occupy - for a piece you're deliberately keeping
-- (set bonus, a proc not captured by stat weights) even though it scores as
-- a downgrade. Deliberately not on the character pane - the loot list is
-- where you're actually looking at the candidate item.
function GW.ToggleSlotLockForItem(itemLink)
	if not itemLink then return end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)
	if not equipLoc or equipLoc == "" then return end

	local slots = (equipLoc == "INVTYPE_2HWEAPON") and { INVSLOT_MAINHAND } or slotsForEquipLoc[equipLoc]
	if not slots or #slots == 0 then return end

	local allLocked = true
	for _, slotId in ipairs(slots) do
		if not GW.IsSlotLocked(slotId) then
			allLocked = false
			break
		end
	end
	local newLocked = not allLocked
	for _, slotId in ipairs(slots) do
		GW.SetSlotLocked(slotId, newLocked)
	end

	local labelParts = {}
	for _, slotId in ipairs(slots) do
		table.insert(labelParts, GW.SLOT_LOCK_LABEL[slotId] or tostring(slotId))
	end
	local label = table.concat(labelParts, " / ")
	if newLocked then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: " .. label .. " is now |cffff4444locked|r - upgrades here will be scored but not counted.")
	else
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: " .. label .. " is now |cff00ff00unlocked|r.")
	end
end

-- A 2H weapon occupies both hands, so the Off Hand slot reading "empty" while
-- one's equipped doesn't mean it's actually free to equip into right now -
-- it's blocked, not available. Without this check, any Off Hand-capable item
-- (shields, one-hand weapons, held items) would score as a free "slot empty"
-- upgrade even though equipping it would first require replacing the 2H.
local function IsMainHandTwoHanded()
	local mhLink = GetInventoryItemLink("player", INVSLOT_MAINHAND)
	if not mhLink then return false end
	local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
	return mhEquipLoc == "INVTYPE_2HWEAPON"
end

--------------------------------------------------------------------------------
-- Class usability check so unusable items don't get scored
--------------------------------------------------------------------------------

local usabilityCache = {}
local proficiencySet

-- Confirmed via a real Chronomancer's Skills pane: Ascension's classless
-- system reports UnitClass() as the custom class name itself (e.g.
-- "CHRONOMANCER"), a token the client's built-in IsEquippableItem() has no
-- proficiency rules for - it was silently defaulting to "usable" for
-- everything regardless of real armor/weapon type, on every custom class.
-- The Skills pane (Weapon Skills / Armor Proficiencies sections) is the real,
-- server-granted source of truth instead, and it's queryable live via the
-- same API that panel is built from - no hand-maintained per-class table,
-- works for every current and future custom class automatically.
local function BuildProficiencySet()
	local set = {}
	local currentHeader
	for i = 1, GetNumSkillLines() do
		local name, isHeader = GetSkillLineInfo(i)
		if isHeader then
			currentHeader = name
		elseif currentHeader == "Weapon Skills" or currentHeader == "Armor Proficiencies" then
			set[name] = true
		end
	end
	return set
end

-- Item subtype strings mostly match skill line names directly (e.g.
-- "Daggers", "Staves", "Cloth"), except the One-/Two-Handed weapon split
-- (both share a single skill, e.g. "Two-Handed Swords" -> "Swords") and a
-- couple of naming quirks that vary by client - checked as extra candidates
-- rather than assumed, since guessing the exact string wrong would silently
-- break usability detection again.
local subTypeSkillCandidates = {
	["One-Handed Axes"] = { "Axes" },
	["Two-Handed Axes"] = { "Axes" },
	["One-Handed Swords"] = { "Swords" },
	["Two-Handed Swords"] = { "Swords" },
	["One-Handed Maces"] = { "Maces" },
	["Two-Handed Maces"] = { "Maces" },
	["Plate"] = { "Plate Mail", "Plate" },
}

local function HasProficiencyFor(itemSubType)
	if not proficiencySet then proficiencySet = BuildProficiencySet() end
	local candidates = subTypeSkillCandidates[itemSubType]
	if candidates then
		for _, name in ipairs(candidates) do
			if proficiencySet[name] then return true end
		end
		return false
	end
	return proficiencySet[itemSubType] == true
end

-- Relics (Libram/Idol/Totem/Sigil) aren't gated by a skill line at all - they
-- carry an explicit "Classes: X, Y" line in their own tooltip text instead,
-- so that's the one case that still needs an actual tooltip scan.
local relicScanTip
local function IsRelicUsable(itemLink)
	if not relicScanTip then
		relicScanTip = CreateFrame("GameTooltip", "GearWeightsUsabilityScanTooltip", nil, "GameTooltipTemplate")
		relicScanTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	relicScanTip:ClearLines()
	local ok = pcall(relicScanTip.SetHyperlink, relicScanTip, itemLink)
	if not ok then return true end
	local localizedClass = UnitClass("player")
	for i = 1, relicScanTip:NumLines() do
		local fs = _G["GearWeightsUsabilityScanTooltipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text and strfind(text, "^Classes:") and not strfind(text, localizedClass, 1, true) then
			return false
		end
	end
	return true
end

-- Unique-Equipped isn't exposed by GetItemStats()/GetItemInfo() at all, so
-- this is the other case that needs a real tooltip scan. Returns the max
-- number of copies of this exact item that can be equipped at once (1 for
-- plain "Unique"/"Unique-Equipped", or the printed count for e.g. some
-- heirlooms' "Unique-Equipped: <name> (2)"), or nil if it isn't unique at all.
local uniqueCapCache = {}
local uniqueScanTip
function GW.GetItemUniqueCap(itemLink)
	if not itemLink then return nil end
	local cached = uniqueCapCache[itemLink]
	if cached ~= nil then return cached or nil end

	if not uniqueScanTip then
		uniqueScanTip = CreateFrame("GameTooltip", "GearWeightsUniqueScanTooltip", nil, "GameTooltipTemplate")
		uniqueScanTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	uniqueScanTip:ClearLines()
	local ok = pcall(uniqueScanTip.SetHyperlink, uniqueScanTip, itemLink)
	local cap
	if ok then
		for i = 1, uniqueScanTip:NumLines() do
			local fs = _G["GearWeightsUniqueScanTooltipTextLeft" .. i]
			local text = fs and fs:GetText()
			if text then
				if text == ITEM_UNIQUE_EQUIPPABLE or text == ITEM_UNIQUE then
					cap = 1
					break
				end
				local count = text:match("^Unique%-Equipped.*%((%d+)%)$") or text:match("^Unique .*%((%d+)%)$")
				if count then
					cap = tonumber(count)
					break
				end
			end
		end
	end
	uniqueCapCache[itemLink] = cap or false
	return cap
end

-- Given a Unique-Equipped candidate item and the slots it could occupy,
-- returns the subset actually available to compare against: every slot,
-- unless you already own `cap` or more copies of an item sharing its exact
-- name (matched by name - the same heuristic the game itself effectively
-- uses) - in which case only the slot(s) already holding that name are real
-- options, since equipping this one into any other slot would put you over
-- the limit. Second return value is true when this narrowed the choice, so
-- callers can note "would be an upgrade, but blocked by Unique-Equip" for
-- the slots that got excluded.
function GW.GetUniqueEligibleSlots(itemLink, slots)
	-- Only equip types with more than one physical slot (rings, trinkets,
	-- weapons) can even have this conflict - a single-slot type never has an
	-- "other slot" to wrongly compare against, so skip the tooltip scan
	-- entirely there rather than paying its cost on every piece of gear.
	if #slots <= 1 then return slots, false end

	local cap = GW.GetItemUniqueCap(itemLink)
	if not cap then return slots, false end
	local itemName = GetItemInfo(itemLink)
	if not itemName then return slots, false end

	local sameNameSlots = {}
	for _, slotId in ipairs(slots) do
		local equippedLink = GetInventoryItemLink("player", slotId)
		if equippedLink then
			if equippedLink == itemLink then
				table.insert(sameNameSlots, slotId)
			else
				local equippedName = GetItemInfo(equippedLink)
				if equippedName == itemName then table.insert(sameNameSlots, slotId) end
			end
		end
	end

	if #sameNameSlots >= cap then
		return sameNameSlots, (#sameNameSlots < #slots)
	end
	return slots, false
end

function GW.IsItemUsable(itemLink, knownEquipLoc)
	if not itemLink then return true end

	local cached = usabilityCache[itemLink]
	if cached ~= nil then return cached end

	local equipLoc = knownEquipLoc
	local itemSubType
	if equipLoc == nil then
		_, _, _, _, _, _, itemSubType, _, equipLoc = GetItemInfo(itemLink)
	else
		_, _, _, _, _, _, itemSubType = GetItemInfo(itemLink)
	end

	-- Only weapon/armor slots have a real proficiency to check - bags,
	-- tabards, shirts etc. use INVTYPE_BAG/TABARD/BODY, which aren't in
	-- slotsForEquipLoc, so they fall through and stay usable.
	local usable = true
	if equipLoc == "INVTYPE_RELIC" then
		usable = IsRelicUsable(itemLink)
	elseif slotsForEquipLoc[equipLoc] and itemSubType and itemSubType ~= "Miscellaneous" then
		usable = HasProficiencyFor(itemSubType)
	end

	usabilityCache[itemLink] = usable
	return usable
end

--------------------------------------------------------------------------------
-- Saved Variables / Profiles
--------------------------------------------------------------------------------

local function EnsureDB()
	GearWeightsDB = GearWeightsDB or {}
	GearWeightsDB.profiles = GearWeightsDB.profiles or {}
	GearWeightsDB.knownStats = GearWeightsDB.knownStats or {}
	GearWeightsDB.pendingImports = GearWeightsDB.pendingImports or {}
end

function GW.GetCurrentSpecId()
	if SpecializationUtil and SpecializationUtil.GetActiveSpecialization then
		local ok, id = pcall(SpecializationUtil.GetActiveSpecialization)
		if ok and id then return id end
	end
	return 0
end

function GW.GetCurrentSpecName()
	local id = GW.GetCurrentSpecId()
	if id == 0 then return "Default" end
	if SpecializationUtil and SpecializationUtil.GetSpecializationInfo then
		local ok, name = pcall(SpecializationUtil.GetSpecializationInfo, id)
		if ok and name then return name end
	end
	return "Spec " .. tostring(id)
end

function GW.GetActiveProfile()
	EnsureDB()
	local specId = GW.GetCurrentSpecId()
	GearWeightsDB.profiles[specId] = GearWeightsDB.profiles[specId] or { weights = {} }
	return GearWeightsDB.profiles[specId]
end

function GW.GetKnownStats()
	EnsureDB()
	return GearWeightsDB.knownStats
end

--------------------------------------------------------------------------------
-- Stat discovery + scoring
--------------------------------------------------------------------------------

local function RegisterDiscoveredStats(stats)
	EnsureDB()
	for key, value in pairs(stats) do
		if type(key) == "string" and type(value) == "number" and not GearWeightsDB.knownStats[key] then
			local label = _G[key]
			if type(label) ~= "string" then label = key end
			GearWeightsDB.knownStats[key] = label

			-- If an earlier import was waiting on this exact stat to show up, apply it now.
			for specId, pending in pairs(GearWeightsDB.pendingImports) do
				if pending[label] ~= nil then
					GearWeightsDB.profiles[specId] = GearWeightsDB.profiles[specId] or { weights = {} }
					GearWeightsDB.profiles[specId].weights[key] = pending[label]
					pending[label] = nil
				end
			end
		end
	end
end

function GW.GetItemStats(itemLink)
	if not itemLink then return nil end
	wipe(scanTable)
	local ok = pcall(GetItemStats, itemLink, scanTable)
	if not ok or next(scanTable) == nil then return nil end
	RegisterDiscoveredStats(scanTable)
	return scanTable
end

function GW.GetItemScore(itemLink)
	local stats = GW.GetItemStats(itemLink)
	if not stats then return nil end
	local profile = GW.GetActiveProfile()
	local score = 0
	for key, value in pairs(stats) do
		if type(value) == "number" and GW.IsCanonicalStatKey(key) then
			local w = profile.weights[key]
			if w then score = score + value * w end
		end
	end
	return score, stats
end

--------------------------------------------------------------------------------
-- Import / Export (bisbeard.com stat weight format)
--------------------------------------------------------------------------------

-- Returns: ok, appliedCount, pendingCount, skippedCount  (or ok=false, errorMessage)
function GW.ImportWeights(base64Str)
	EnsureDB()
	local ok, jsonStr = pcall(Base64Decode, base64Str)
	if not ok or jsonStr == "" then
		return false, "Couldn't decode that as base64."
	end
	local data = FlatJsonDecode(jsonStr)
	if not next(data) then
		return false, "No recognizable weight data found in that string."
	end

	local profile = GW.GetActiveProfile()
	local known = GW.GetKnownStats()
	local labelToKey = {}
	for key, label in pairs(known) do labelToKey[label] = key end

	local specId = GW.GetCurrentSpecId()
	GearWeightsDB.pendingImports[specId] = GearWeightsDB.pendingImports[specId] or {}

	local applied, pending, skipped = 0, 0, 0
	for bisKey, value in pairs(data) do
		local label = bisbeardKeyToLabel[bisKey]
		if not label or not GW.CANONICAL_STAT_LABELS[label] then
			skipped = skipped + 1
		else
			local realKey = labelToKey[label]
			if realKey then
				profile.weights[realKey] = value
				applied = applied + 1
			else
				GearWeightsDB.pendingImports[specId][label] = value
				pending = pending + 1
			end
		end
	end

	return true, applied, pending, skipped
end

function GW.ExportWeights()
	local profile = GW.GetActiveProfile()
	local known = GW.GetKnownStats()

	local labelToBisKey = {}
	for bisKey, label in pairs(bisbeardKeyToLabel) do
		if not labelToBisKey[label] then labelToBisKey[label] = bisKey end
	end

	local out = {}
	for key, weight in pairs(profile.weights) do
		if weight and weight ~= 0 then
			local label = known[key]
			local bisKey = label and GW.CANONICAL_STAT_LABELS[label] and labelToBisKey[label]
			if bisKey then out[bisKey] = weight end
		end
	end

	return Base64Encode(FlatJsonEncode(out))
end

--------------------------------------------------------------------------------
-- Tooltip integration
--------------------------------------------------------------------------------

local function AppendComparisonLine(tooltip, prefix, score, equippedScore, ignoreReason)
	local diff = score - equippedScore
	-- Still shows the real comparison even when ignored - the point is to
	-- stop chasing upgrades here, not to hide whether this technically is one.
	local lockedNote = ignoreReason and ("  |cff888888(" .. ignoreReason .. ")|r") or ""
	if diff > 0.05 then
		tooltip:AddLine(string.format("%s|cff00ff00Upgrade (+%.1f)|r%s", prefix, diff, lockedNote))
	elseif diff < -0.05 then
		tooltip:AddLine(string.format("%s|cffff4444Downgrade (%.1f)|r%s", prefix, diff, lockedNote))
	else
		tooltip:AddLine(prefix .. "|cffffff00Sidegrade (~equal)|r" .. lockedNote)
	end
end

-- Returns score, bestDiff, usable. bestDiff is nil if the item isn't equippable,
-- or the best-case score difference vs whatever it could replace, otherwise.
-- usable is false if your class can't use this item at all (score/diff also nil
-- in that case). Used by the instance loot list; tooltips use their own more
-- detailed breakdown above.
function GW.GetBestUpgradeDiff(itemLink)
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)

	if not GW.IsItemUsable(itemLink, equipLoc) then
		return nil, nil, false
	end

	local score = GW.GetItemScore(itemLink)
	if not score then return nil end

	if not equipLoc then return score, nil end

	if equipLoc == "INVTYPE_2HWEAPON" then
		if GW.GetSlotIgnoreReason(INVSLOT_MAINHAND) then return score, nil end
		local mhLink = GetInventoryItemLink("player", INVSLOT_MAINHAND)
		local ohLink = GetInventoryItemLink("player", INVSLOT_OFFHAND)
		local comboScore = (mhLink and GW.GetItemScore(mhLink) or 0) + (ohLink and GW.GetItemScore(ohLink) or 0)
		return score, score - comboScore
	end

	local slots = slotsForEquipLoc[equipLoc]
	if not slots or #slots == 0 then return score, nil end

	-- Unique-Equipped items can't have a second copy equipped once you're at
	-- the cap - if so, only the slot(s) already holding a copy of the exact
	-- same item are actually replaceable; comparing against an unrelated item
	-- in some other slot would suggest an upgrade you couldn't actually equip.
	slots = GW.GetUniqueEligibleSlots(itemLink, slots)

	local bestDiff
	for _, slotId in ipairs(slots) do
		if not GW.GetSlotIgnoreReason(slotId) then
			local equippedLink = GetInventoryItemLink("player", slotId)
			local diff
			if not equippedLink then
				if not (slotId == INVSLOT_OFFHAND and IsMainHandTwoHanded()) then
					diff = score
				end
			elseif equippedLink ~= itemLink then
				local equippedScore = GW.GetItemScore(equippedLink)
				if equippedScore then diff = score - equippedScore end
			end
			if diff and (not bestDiff or diff > bestDiff) then
				bestDiff = diff
			end
		end
	end

	return score, bestDiff
end

local function AppendScoreLines(tooltip, itemLink)
	if not itemLink then return end

	if not GW.IsItemUsable(itemLink) then
		tooltip:AddLine(" ")
		tooltip:AddLine("GearWeights: |cff888888Unusable by your class|r", 0.4, 0.75, 1.0)
		tooltip:Show()
		return
	end

	local score = GW.GetItemScore(itemLink)
	if not score then return end

	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)

	tooltip:AddLine(" ")
	tooltip:AddLine(string.format("GearWeights: %.1f", score), 0.4, 0.75, 1.0)

	if not equipLoc then
		tooltip:Show()
		return
	end

	-- A 2H weapon replaces both the main hand and off hand, so compare it against
	-- the combined score of whatever is currently in both slots, not just one.
	if equipLoc == "INVTYPE_2HWEAPON" then
		if GetInventoryItemLink("player", INVSLOT_MAINHAND) == itemLink then
			tooltip:Show()
			return
		end
		local mhLink = GetInventoryItemLink("player", INVSLOT_MAINHAND)
		local ohLink = GetInventoryItemLink("player", INVSLOT_OFFHAND)
		local mhIgnoreReason = GW.GetSlotIgnoreReason(INVSLOT_MAINHAND)
		if not mhLink and not ohLink then
			tooltip:AddLine(mhIgnoreReason and ("|cff888888Upgrade (weapon slots empty) (" .. mhIgnoreReason .. ")|r") or "|cff00ff00Upgrade (weapon slots empty)|r")
		else
			local comboScore = (mhLink and GW.GetItemScore(mhLink) or 0) + (ohLink and GW.GetItemScore(ohLink) or 0)
			AppendComparisonLine(tooltip, "Main Hand + Off Hand combo: ", score, comboScore, mhIgnoreReason)
		end
		tooltip:Show()
		return
	end

	local slots = slotsForEquipLoc[equipLoc]
	if not slots or #slots == 0 then
		tooltip:Show()
		return
	end

	-- If this item is already equipped in one of its own slots (e.g. this is
	-- your currently-worn ring, shown via shift-hover compare), comparing it
	-- against whatever's in the *other* ring/trinket/weapon slot is a real
	-- number but a misleading one here - it looks like it's judging this item
	-- against the thing you're actually considering, when it isn't. Just show
	-- the plain score instead of a comparison that isn't about that decision.
	for _, slotId in ipairs(slots) do
		if GetInventoryItemLink("player", slotId) == itemLink then
			tooltip:Show()
			return
		end
	end

	-- Unique-Equipped: if you already own this item's cap worth of copies
	-- elsewhere, the slot(s) NOT already holding a copy of it aren't real
	-- options - equipping it there would put you over the limit. Still show
	-- what it would have scored, just don't call it a real Upgrade there.
	local eligibleSlots, uniqueNarrowed = GW.GetUniqueEligibleSlots(itemLink, slots)
	local uniqueEligible = {}
	for _, s in ipairs(eligibleSlots) do uniqueEligible[s] = true end

	for _, slotId in ipairs(slots) do
		local equippedLink = GetInventoryItemLink("player", slotId)
		local label = slotLabels[slotId]
		local prefix = label and (label .. ": ") or ""
		local slotBlockedBy2H = slotId == INVSLOT_OFFHAND and IsMainHandTwoHanded()
		local slotIgnoreReason = GW.GetSlotIgnoreReason(slotId)
		if uniqueNarrowed and not uniqueEligible[slotId] and equippedLink and equippedLink ~= itemLink then
			local equippedScore = GW.GetItemScore(equippedLink)
			if equippedScore then
				local diff = score - equippedScore
				local wouldBeNote = diff > 0.05 and string.format(" - would be +%.1f", diff) or ""
				tooltip:AddLine(prefix .. "|cff888888Blocked by Unique-Equip limit" .. wouldBeNote .. "|r")
			end
		elseif not equippedLink then
			if slotBlockedBy2H then
				tooltip:AddLine(prefix .. "|cff888888Blocked by 2H Main Hand|r")
			elseif slotIgnoreReason then
				tooltip:AddLine(prefix .. "|cff888888Upgrade (slot empty) (" .. slotIgnoreReason .. ")|r")
			else
				tooltip:AddLine(prefix .. "|cff00ff00Upgrade (slot empty)|r")
			end
		elseif equippedLink ~= itemLink then
			local equippedScore = GW.GetItemScore(equippedLink)
			if equippedScore then
				AppendComparisonLine(tooltip, prefix, score, equippedScore, slotIgnoreReason)
			end
		end

		-- Weapons are a two-piece system: also show what the Main Hand + Off Hand
		-- total would be with this item in this slot, alongside whatever's
		-- currently in the other hand - unless that other hand holds a 2H,
		-- which can't actually be paired with anything.
		local otherSlot = otherWeaponSlot[slotId]
		if otherSlot and not slotBlockedBy2H then
			local otherLink = GetInventoryItemLink("player", otherSlot)
			if otherLink ~= itemLink then
				local otherScore = otherLink and GW.GetItemScore(otherLink) or 0
				tooltip:AddLine(string.format("  |cff888888Main Hand + Off Hand combo: %.1f|r", score + otherScore))
			end
		end
	end

	tooltip:Show()
end

local function HookTooltip(tooltip)
	hooksecurefunc(tooltip, "SetBagItem", function(self, bag, slot)
		local link = GetContainerItemLink(bag, slot)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetInventoryItem", function(self, unit, slotId)
		local link = GetInventoryItemLink(unit, slotId)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetHyperlink", function(self, link)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetMerchantItem", function(self, index)
		local link = GetMerchantItemLink(index)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetLootItem", function(self, slot)
		local link = GetLootSlotLink(slot)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetLootRollItem", function(self, rollId)
		local link = GetLootRollItemLink(rollId)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetAuctionItem", function(self, auctionType, index)
		local link = GetAuctionItemLink(auctionType, index)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetQuestItem", function(self, itemType, index)
		local link = GetQuestItemLink(itemType, index)
		AppendScoreLines(self, link)
	end)
	hooksecurefunc(tooltip, "SetQuestLogItem", function(self, itemType, index)
		local link = GetQuestLogItemLink(itemType, index)
		AppendScoreLines(self, link)
	end)
end

-- The shift-hover comparison tooltips (showing your currently equipped item)
-- use this method in addition to the ones covered by HookTooltip.
local function HookCompareTooltip(tooltip)
	HookTooltip(tooltip)
	hooksecurefunc(tooltip, "SetHyperlinkCompareItem", function(self, link)
		-- The link argument here is the hovered (new) item, not what this tooltip
		-- actually displays. This tooltip shows the currently equipped item, so
		-- ask it directly rather than scoring the wrong item.
		local _, actualLink = self:GetItem()
		AppendScoreLines(self, actualLink or link)
	end)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

-- On a heavily custom server, the loot table itself may be generated
-- server-side and arrive a moment after LOOT_OPENED fires, rather than being
-- fully populated the instant the event triggers like on a stock server -
-- so a single immediate GetItemInfo pass can miss items whose link isn't
-- resolved yet. Keep re-warming for a bit after the window opens to catch
-- those instead of only trying once.
local lootWarmFrame = CreateFrame("Frame")
lootWarmFrame:Hide()
local lootWarmElapsed, lootWarmTotal = 0, 0
lootWarmFrame:SetScript("OnUpdate", function(self, elapsed)
	lootWarmElapsed = lootWarmElapsed + elapsed
	lootWarmTotal = lootWarmTotal + elapsed
	if lootWarmElapsed < 0.25 then return end
	lootWarmElapsed = 0
	for i = 1, GetNumLootItems() do
		local link = GetLootSlotLink(i)
		if link then GetItemInfo(link) end
	end
	if lootWarmTotal > 1.5 then
		self:Hide()
	end
end)

local function WarmLootCache()
	for i = 1, GetNumLootItems() do
		local link = GetLootSlotLink(i)
		if link then GetItemInfo(link) end
	end
	lootWarmElapsed, lootWarmTotal = 0, 0
	lootWarmFrame:Show()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_SLOT_CLEARED")
frame:RegisterEvent("START_LOOT_ROLL")
frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == "GearWeights" then
		EnsureDB()
	elseif event == "PLAYER_LOGIN" then
		HookTooltip(GameTooltip)
		HookTooltip(ItemRefTooltip)
		if ShoppingTooltip1 then HookCompareTooltip(ShoppingTooltip1) end
		if ShoppingTooltip2 then HookCompareTooltip(ShoppingTooltip2) end

		-- Prime stat discovery from currently equipped gear.
		for slotId = 1, 19 do
			local link = GetInventoryItemLink("player", slotId)
			if link then GW.GetItemStats(link) end
		end
	elseif event == "LOOT_OPENED" or event == "LOOT_SLOT_CLEARED" then
		-- Kick off the item data request for everything in the loot window the
		-- moment it opens, not when you actually hover something. GetItemInfo
		-- doesn't block - it just returns nil and lets the fetch happen in the
		-- background - so by the time your mouse gets there it's usually
		-- already cached, instead of stalling the tooltip on a fresh drop.
		WarmLootCache()
	elseif event == "START_LOOT_ROLL" then
		local link = GetLootRollItemLink(arg1)
		if link then GetItemInfo(link) end
	end
end)

local function DumpItemDiagnostics(itemLink)
	if not itemLink then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: no item to dump. Shift-click an item into the chat box after /gw dump, or hover it and use /gw dumphover.")
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("GearWeights dump for: " .. itemLink)

	DEFAULT_CHAT_FRAME:AddMessage("-- GetItemStats() --")
	local stats = {}
	local ok = pcall(GetItemStats, itemLink, stats)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage("  GetItemStats() errored on this item.")
	elseif next(stats) == nil then
		DEFAULT_CHAT_FRAME:AddMessage("  (empty)")
	else
		for k, v in pairs(stats) do
			DEFAULT_CHAT_FRAME:AddMessage("  " .. tostring(k) .. " = " .. tostring(v))
		end
	end

	DEFAULT_CHAT_FRAME:AddMessage("-- Usability --")
	local playerClass, classToken = UnitClass("player")
	DEFAULT_CHAT_FRAME:AddMessage("  UnitClass(player) = " .. tostring(playerClass) .. " (" .. tostring(classToken) .. ")")
	local _, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink)
	DEFAULT_CHAT_FRAME:AddMessage("  equipLoc = " .. tostring(equipLoc))
	DEFAULT_CHAT_FRAME:AddMessage("  itemType = " .. tostring(itemType) .. ", itemSubType = " .. tostring(itemSubType))
	local okEquip, isEquippable = pcall(IsEquippableItem, itemLink)
	DEFAULT_CHAT_FRAME:AddMessage("  IsEquippableItem() = " .. tostring(isEquippable) .. " (ok=" .. tostring(okEquip) .. ")")
	DEFAULT_CHAT_FRAME:AddMessage("  GW.IsItemUsable() = " .. tostring(GW.IsItemUsable(itemLink)))

	DEFAULT_CHAT_FRAME:AddMessage("-- Tooltip text --")
	local scanTip = _G["GearWeightsScanTooltip"]
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "GearWeightsScanTooltip", nil, "GameTooltipTemplate")
		scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	scanTip:ClearLines()
	scanTip:SetHyperlink(itemLink)
	for i = 1, scanTip:NumLines() do
		local leftText = _G["GearWeightsScanTooltipTextLeft" .. i]
		local rightText = _G["GearWeightsScanTooltipTextRight" .. i]
		local l = leftText and leftText:GetText()
		local r = rightText and rightText:GetText()
		if l or r then
			DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. tostring(l) .. (r and (" | " .. r) or ""))
		end
	end
end

SLASH_GEARWEIGHTS1 = "/gw"
SLASH_GEARWEIGHTS2 = "/gearweights"
SlashCmdList["GEARWEIGHTS"] = function(msg)
	msg = msg or ""
	if msg == "dumphover" then
		local _, link = GameTooltip:GetItem()
		DumpItemDiagnostics(link)
	elseif strsub(msg, 1, 4) == "dump" then
		local link = strtrim(strsub(msg, 5))
		if link == "" then link = nil end
		DumpItemDiagnostics(link)
	elseif msg == "diag" then
		if GW.BuildInstanceLootList then GW.BuildInstanceLootList(function() end) end
		local zoneName, instanceType, difficultyIndex, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceMapID = GetInstanceInfo()
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights diag:")
		DEFAULT_CHAT_FRAME:AddMessage("  GetInstanceInfo(): zoneName=" .. tostring(zoneName)
			.. " instanceType=" .. tostring(instanceType)
			.. " difficultyIndex=" .. tostring(difficultyIndex)
			.. " difficultyName=" .. tostring(difficultyName)
			.. " instanceMapID=" .. tostring(instanceMapID))
		DEFAULT_CHAT_FRAME:AddMessage("  GetRealZoneText()=" .. tostring(GetRealZoneText()))
		DEFAULT_CHAT_FRAME:AddMessage("  GetSubZoneText()=" .. tostring(GetSubZoneText()))
		DEFAULT_CHAT_FRAME:AddMessage("  GetMinimapZoneText()=" .. tostring(GetMinimapZoneText and GetMinimapZoneText()))

		local modulesToCheck = {
			"AtlasLoot", "AtlasLoot_Cache", "AtlasLoot_OriginalWoW", "AtlasLoot_BurningCrusade",
			"AtlasLoot_WrathoftheLichKing", "AtlasLoot_Crafting_OriginalWoW", "AtlasLoot_Crafting_TBC",
			"AtlasLoot_Crafting_Wrath", "AtlasLoot_Vanity", "AtlasLoot_WorldEvents",
		}
		DEFAULT_CHAT_FRAME:AddMessage("  AddOn load state:")
		for _, name in ipairs(modulesToCheck) do
			local loaded = IsAddOnLoaded(name)
			DEFAULT_CHAT_FRAME:AddMessage("    " .. name .. " = " .. (loaded and "|cff00ff00loaded|r" or "|cffff4444NOT loaded|r"))
		end

		if not AtlasLoot_Data then
			DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot_Data global does not exist at all (AtlasLoot may not be loaded).")
		else
			local count = 0
			for _ in pairs(AtlasLoot_Data) do count = count + 1 end
			DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot_Data exists with " .. count .. " zone entries.")
			local direct = AtlasLoot_Data["TheStockade"]
			if direct then
				DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot_Data[\"TheStockade\"] exists directly. Its .Name = \"" .. tostring(direct.Name) .. "\" (length " .. strlen(tostring(direct.Name)) .. "), Type=" .. tostring(direct.Type))
				DEFAULT_CHAT_FRAME:AddMessage("  GetRealZoneText() length = " .. strlen(tostring(GetRealZoneText())))
			else
				DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot_Data[\"TheStockade\"] key does not exist at all.")
			end
		end

		DEFAULT_CHAT_FRAME:AddMessage("  -- Kam's Walking Stick (2280) resolution test --")
		DEFAULT_CHAT_FRAME:AddMessage("    ItemIDsDatabase[2280] exists: " .. tostring(ItemIDsDatabase and ItemIDsDatabase[2280] ~= nil))
		if ItemIDsDatabase and ItemIDsDatabase[2280] then
			for k, v in pairs(ItemIDsDatabase[2280]) do
				DEFAULT_CHAT_FRAME:AddMessage("      [" .. tostring(k) .. "] = " .. tostring(v))
			end
		end
		if GetItemDifficultyID then
			local ok4, resolved4 = pcall(GetItemDifficultyID, 2280, 4)
			DEFAULT_CHAT_FRAME:AddMessage("    GetItemDifficultyID(2280, 4) = " .. tostring(resolved4) .. " (ok=" .. tostring(ok4) .. ")")
			if ok4 and resolved4 then
				local itemName, itemLink = GetItemInfo(resolved4)
				DEFAULT_CHAT_FRAME:AddMessage("    GetItemInfo(" .. tostring(resolved4) .. ") right now: name=" .. tostring(itemName) .. " link=" .. tostring(itemLink))

				local scoreByNumber = GW.GetItemScore and GW.GetItemScore(resolved4)
				DEFAULT_CHAT_FRAME:AddMessage("    GetItemScore(numeric ID " .. tostring(resolved4) .. ") = " .. tostring(scoreByNumber))

				if itemLink then
					local scoreByLink = GW.GetItemScore and GW.GetItemScore(itemLink)
					DEFAULT_CHAT_FRAME:AddMessage("    GetItemScore(actual link) = " .. tostring(scoreByLink))

					local rawStats = {}
					local ok5 = pcall(GetItemStats, itemLink, rawStats)
					DEFAULT_CHAT_FRAME:AddMessage("    Raw GetItemStats(actual link): ok=" .. tostring(ok5) .. " entries=" .. tostring(next(rawStats) ~= nil))
					for k, v in pairs(rawStats) do
						DEFAULT_CHAT_FRAME:AddMessage("      " .. tostring(k) .. " = " .. tostring(v))
					end
				else
					DEFAULT_CHAT_FRAME:AddMessage("    itemLink was nil, can't test GetItemStats with it.")
				end
			end
		else
			DEFAULT_CHAT_FRAME:AddMessage("    GetItemDifficultyID function does not exist globally.")
		end

		local zoneData
		if AtlasLoot_Data then
			for key, data in pairs(AtlasLoot_Data) do
				if data.Name == (GetRealZoneText() or zoneName) then
					zoneData = data
					DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot zone match: key=" .. tostring(key) .. " Type=" .. tostring(data.Type))
					break
				end
			end
		end
		local atlasLoot = GW.GetAtlasLootAddon and GW.GetAtlasLootAddon()
		if not zoneData then
			DEFAULT_CHAT_FRAME:AddMessage("  No AtlasLoot_Data match found for this zone name.")
		elseif atlasLoot and atlasLoot.Difficulties and atlasLoot.Difficulties[zoneData.Type] then
			DEFAULT_CHAT_FRAME:AddMessage("  AtlasLoot.Difficulties[" .. zoneData.Type .. "] entries:")
			for _, tier in ipairs(atlasLoot.Difficulties[zoneData.Type]) do
				local matches = (tier[1] == difficultyName) and " <-- MATCHES difficultyName" or ""
				DEFAULT_CHAT_FRAME:AddMessage("    \"" .. tostring(tier[1]) .. "\" = " .. tostring(tier[2]) .. matches)
			end
		end
	elseif msg == "questdiag" then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights quest reward diag:")
		DEFAULT_CHAT_FRAME:AddMessage("  MAX_NUM_ITEMS = " .. tostring(MAX_NUM_ITEMS))
		DEFAULT_CHAT_FRAME:AddMessage("  QuestInfo_ShowRewards = " .. tostring(type(_G.QuestInfo_ShowRewards)))
		DEFAULT_CHAT_FRAME:AddMessage("  QuestInfoFrame = " .. tostring(type(_G.QuestInfoFrame)))
		DEFAULT_CHAT_FRAME:AddMessage("  QuestInfoFrame.questLog = " .. tostring(QuestInfoFrame and QuestInfoFrame.questLog))
		DEFAULT_CHAT_FRAME:AddMessage("  GW.IsQuestRewardGlowEnabled() = " .. tostring(GW.IsQuestRewardGlowEnabled and GW.IsQuestRewardGlowEnabled()))
		DEFAULT_CHAT_FRAME:AddMessage("  GW.IsQuestVendorGlowEnabled() = " .. tostring(GW.IsQuestVendorGlowEnabled and GW.IsQuestVendorGlowEnabled()))
		for i = 1, (MAX_NUM_ITEMS or 6) do
			local item = _G["QuestInfoItem" .. i]
			if item then
				local visible = item:IsVisible()
				local okId, id = pcall(item.GetID, item)
				DEFAULT_CHAT_FRAME:AddMessage("  QuestInfoItem" .. i .. ": exists, visible=" .. tostring(visible)
					.. ", type=" .. tostring(item.type) .. ", GetID()=" .. tostring(okId and id or "error"))
				if item.type then
					local getLinkFn = (QuestInfoFrame.questLog and GetQuestLogItemLink or GetQuestItemLink)
					local okLink, link = pcall(getLinkFn, item.type, item:GetID())
					DEFAULT_CHAT_FRAME:AddMessage("    link = " .. tostring(okLink and link or ("error: " .. tostring(link))))
					if okLink and link then
						local okSell, sellPrice = pcall(function() return select(11, GetItemInfo(link)) end)
						local okUpg, score, diff, usable = pcall(GW.GetBestUpgradeDiff, link)
						DEFAULT_CHAT_FRAME:AddMessage("    sellPrice=" .. tostring(okSell and sellPrice)
							.. " score=" .. tostring(okUpg and score)
							.. " diff=" .. tostring(okUpg and diff) .. " usable=" .. tostring(okUpg and usable))
					end
				end
			else
				DEFAULT_CHAT_FRAME:AddMessage("  QuestInfoItem" .. i .. ": does not exist")
			end
		end
	elseif msg == "bossdiag" then
		if GW.DumpBossAndGlowDiag then GW.DumpBossAndGlowDiag() end
	elseif msg == "vendordiag" then
		if not MerchantFrame or not MerchantFrame:IsShown() then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: open a merchant window first.")
		else
			local n = GetMerchantNumItems()
			DEFAULT_CHAT_FRAME:AddMessage("-- Vendor diag: " .. tostring(n) .. " items --")
			for i = 1, n do
				local link = GetMerchantItemLink(i)
				local name, _, price, stack, numAvailable, isUsable, extendedCost = GetMerchantItemInfo(i)
				DEFAULT_CHAT_FRAME:AddMessage(string.format(
					"  [%d] %s  price=%s  stack=%s  extendedCost=%s  link=%s",
					i, tostring(name), tostring(price), tostring(stack), tostring(extendedCost), tostring(link)))
				if extendedCost then
					local costKinds = GetMerchantItemCostInfo(i)
					DEFAULT_CHAT_FRAME:AddMessage("      costKinds=" .. tostring(costKinds))
					for j = 1, (costKinds or 0) do
						local costTexture, costAmount, costLink, currencyName = GetMerchantItemCostItem(i, j)
						DEFAULT_CHAT_FRAME:AddMessage(string.format(
							"      cost %d: amount=%s link=%s currencyName=%s texture=%s",
							j, tostring(costAmount), tostring(costLink), tostring(currencyName), tostring(costTexture)))
					end
				end
			end
		end
	else
		if GearWeightsUI_Toggle then GearWeightsUI_Toggle() end
	end
end
