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
	[INVSLOT_MAINHAND] = "Main-Hand", [INVSLOT_OFFHAND] = "Off-Hand",
}

-- Shared with GearWeightsUI.lua (Settings tab checklist) and the character
-- pane ctrl+click handler below, so both stay in sync with one list.
GW.SLOT_LOCK_LABEL = {
	[INVSLOT_HEAD] = "Head", [INVSLOT_NECK] = "Neck", [INVSLOT_SHOULDER] = "Shoulder",
	[INVSLOT_BACK] = "Back", [INVSLOT_CHEST] = "Chest", [INVSLOT_WRIST] = "Wrist",
	[INVSLOT_HAND] = "Hands", [INVSLOT_WAIST] = "Waist", [INVSLOT_LEGS] = "Legs",
	[INVSLOT_FEET] = "Feet", [INVSLOT_FINGER1] = "Ring 1", [INVSLOT_FINGER2] = "Ring 2",
	[INVSLOT_TRINKET1] = "Trinket 1", [INVSLOT_TRINKET2] = "Trinket 2",
	[INVSLOT_MAINHAND] = "Main-Hand", [INVSLOT_OFFHAND] = "Off-Hand", [INVSLOT_RANGED] = "Ranged",
}
-- Ordered to match the character pane's two-column paperdoll layout - the
-- first GW.LOCKABLE_SLOT_LEFT_COUNT entries are the left column (top to
-- bottom), the rest are the right column. See the Settings tab checkbox
-- layout in GearWeightsUI.lua, which fills column-major using that count.
GW.LOCKABLE_SLOT_LEFT_COUNT = 8
GW.LOCKABLE_SLOT_ORDER = {
	-- Left column
	INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_BACK, INVSLOT_CHEST,
	INVSLOT_WRIST, INVSLOT_MAINHAND, INVSLOT_OFFHAND,
	-- Right column
	INVSLOT_HAND, INVSLOT_WAIST, INVSLOT_LEGS, INVSLOT_FEET,
	INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2,
	INVSLOT_RANGED,
}

-- The four armor material types - used for the Settings tab's per-type
-- upgrade filter (GW.IsArmorTypeExcluded, GearWeightsLoot.lua) and to grey
-- out a type the player's class can't even wear (GW.CanUseArmorType below).
GW.ARMOR_TYPE_ORDER = { "Plate", "Mail", "Leather", "Cloth" }
GW.ARMOR_TYPE_SET = { Plate = true, Mail = true, Leather = true, Cloth = true }

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

-- A 2H weapon occupies both hands, so the Off-Hand slot reading "empty" while
-- one's equipped doesn't mean it's actually free to equip into right now -
-- it's blocked, not available. Without this check, any Off-Hand-capable item
-- (shields, one-hand weapons, held items) would score as a free "slot empty"
-- upgrade even though equipping it would first require replacing the 2H.
-- This is about real physical blocking right now, so it checks live equipped
-- gear directly - not the Main-Hand reference box, which can be locked to (or
-- still remembering) a 1H weapon while you're actually wielding a 2H live.
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

-- Exposed for the Settings tab's armor-type filter - same skill-proficiency
-- scan GW.IsItemUsable already uses for real items, just callable directly
-- with a known type name (e.g. "Plate") rather than needing an item link.
function GW.CanUseArmorType(armorType)
	return HasProficiencyFor(armorType)
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

-- Reputation-gated items (Settings tab's Reputations category) carry an
-- explicit "Requires <Faction> - <Standing>" red line in their own tooltip
-- text (e.g. "Requires Argent Dawn - Exalted") - read directly from there
-- rather than trying to infer the required standing from AtlasLoot's own
-- organization, which varies wildly between factions (see
-- REPUTATION_ZONE_LIST, GearWeightsLoot.lua - some list Friendly/Honored/
-- Revered/Exalted as top-level "boss" names, some as section headers, some
-- not at all). This also naturally skips anything AtlasLoot lists under a
-- faction's page that isn't actually reputation-gated, since such an item
-- simply won't have this line at all.
local reputationRequirementCache = {}
local reputationScanTip
function GW.GetItemReputationRequirement(itemLink)
	if not itemLink then return nil end
	local cached = reputationRequirementCache[itemLink]
	if cached ~= nil then
		if cached == false then return nil end
		return cached.factionName, cached.standing
	end

	if not reputationScanTip then
		reputationScanTip = CreateFrame("GameTooltip", "GearWeightsReputationScanTooltip", nil, "GameTooltipTemplate")
		reputationScanTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	reputationScanTip:ClearLines()
	local ok = pcall(reputationScanTip.SetHyperlink, reputationScanTip, itemLink)
	if not ok then
		reputationRequirementCache[itemLink] = false
		return nil
	end

	local factionName, standing
	for i = 1, reputationScanTip:NumLines() do
		local fs = _G["GearWeightsReputationScanTooltipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text then
			local matchedFaction, matchedStanding = text:match("^Requires (.+) %- (%a+)$")
			if matchedFaction and matchedStanding then
				for _, validStanding in ipairs(GW.REPUTATION_STANDING_ORDER) do
					if validStanding == matchedStanding then
						factionName, standing = matchedFaction, matchedStanding
						break
					end
				end
			end
		end
		if factionName then break end
	end

	if factionName then
		reputationRequirementCache[itemLink] = { factionName = factionName, standing = standing }
	else
		reputationRequirementCache[itemLink] = false
	end
	return factionName, standing
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
		local equippedLink = GW.GetEquippedLinkForScoring(slotId)
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

	-- Pre-1.26.44 versions kept profiles/pendingImports keyed only by specId,
	-- shared account-wide - so two different characters landing on the same
	-- numeric spec slot silently saw each other's stat weights. Detected by a
	-- numeric specId key sitting directly under profiles/pendingImports
	-- instead of under a characterKey layer; migrated into the currently
	-- active character's own bucket the first time this runs after
	-- upgrading - whichever character loads first keeps the existing data,
	-- every other character starts fresh (same reasoning as the weapon
	-- baseline's own migrations).
	local isLegacyProfiles = false
	for key in pairs(GearWeightsDB.profiles) do
		if type(key) == "number" then isLegacyProfiles = true; break end
	end
	if isLegacyProfiles then
		local legacy = GearWeightsDB.profiles
		GearWeightsDB.profiles = { [GW.GetCurrentCharacterKey()] = legacy }
	end

	local isLegacyPending = false
	for key in pairs(GearWeightsDB.pendingImports) do
		if type(key) == "number" then isLegacyPending = true; break end
	end
	if isLegacyPending then
		local legacy = GearWeightsDB.pendingImports
		GearWeightsDB.pendingImports = { [GW.GetCurrentCharacterKey()] = legacy }
	end
end

-- "CharacterName-RealmName" - used to scope stat-weight profiles and the
-- weapon baseline per-character (nested under per-spec), since two different
-- characters can otherwise land on the same numeric spec slot and would
-- silently share data without this.
function GW.GetCurrentCharacterKey()
	local name = UnitName("player") or "Unknown"
	local realm = GetRealmName() or "Unknown"
	return name .. "-" .. realm
end

function GW.GetCurrentSpecId()
	if SpecializationUtil and SpecializationUtil.GetActiveSpecialization then
		local ok, id = pcall(SpecializationUtil.GetActiveSpecialization)
		if ok and id then return id end
	end
	return 0
end

-- Ascension - Conquest of Azeroth allows 20 specialization slots per
-- character - used to enumerate every possible spec for the Settings tab's
-- cross-spec comparison checklist (GearWeightsUI.lua).
GW.SPEC_COUNT = 20

-- The player's own name for a spec slot (respects renames) - falls back to
-- "Spec N" if SpecializationUtil can't name it (e.g. never configured).
function GW.GetSpecName(id)
	if id == 0 then return "Default" end
	if SpecializationUtil and SpecializationUtil.GetSpecializationInfo then
		local ok, name = pcall(SpecializationUtil.GetSpecializationInfo, id)
		if ok and name then return name end
	end
	return "Spec " .. tostring(id)
end

function GW.GetCurrentSpecName()
	return GW.GetSpecName(GW.GetCurrentSpecId())
end

-- The stat-weight profile for an arbitrary spec (not necessarily the active
-- one) - used by the cross-spec tooltip comparison to score a candidate item
-- against a DIFFERENT spec's own weights, not whichever spec you're
-- currently playing. GW.GetActiveProfile is just this for the current spec.
function GW.GetProfileForSpec(specId)
	EnsureDB()
	local charKey = GW.GetCurrentCharacterKey()
	GearWeightsDB.profiles[charKey] = GearWeightsDB.profiles[charKey] or {}
	GearWeightsDB.profiles[charKey][specId] = GearWeightsDB.profiles[charKey][specId] or { weights = {} }
	return GearWeightsDB.profiles[charKey][specId]
end

function GW.GetActiveProfile()
	return GW.GetProfileForSpec(GW.GetCurrentSpecId())
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
			local charKey = GW.GetCurrentCharacterKey()
			local pendingForChar = GearWeightsDB.pendingImports[charKey]
			if pendingForChar then
				for specId, pending in pairs(pendingForChar) do
					if pending[label] ~= nil then
						GearWeightsDB.profiles[charKey] = GearWeightsDB.profiles[charKey] or {}
						GearWeightsDB.profiles[charKey][specId] = GearWeightsDB.profiles[charKey][specId] or { weights = {} }
						GearWeightsDB.profiles[charKey][specId].weights[key] = pending[label]
						pending[label] = nil
					end
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

-- specId is optional - omit it (or pass nil) to score against your current
-- active spec's weights, as every existing caller does; the cross-spec
-- tooltip comparison passes an explicit specId to score the same item
-- against a DIFFERENT spec's own saved weights instead.
function GW.GetItemScore(itemLink, specId)
	local stats = GW.GetItemStats(itemLink)
	if not stats then return nil end
	local profile = specId and GW.GetProfileForSpec(specId) or GW.GetActiveProfile()
	local score = 0
	for key, value in pairs(stats) do
		if type(value) == "number" and GW.IsCanonicalStatKey(key) then
			local w = profile.weights[key]
			if w then score = score + value * w end
		end
	end
	return score, stats
end

-- Per-stat breakdown of an item's score, relative to equippedLink instead of
-- absolute - e.g. an item with less Intellect than what you're already
-- wearing shows that stat as a NEGATIVE contribution, even though the item's
-- own tooltip states a positive Intellect value, because what matters for
-- "why is this an upgrade/downgrade" is the change, not the raw amount.
-- Falls back to the item's own absolute contribution per stat when
-- equippedLink is nil (nothing to compare against, e.g. an empty slot).
-- Includes stats equippedLink has that itemLink doesn't (shown as a pure
-- loss), so every line here still sums to the same total diff a comparison
-- line elsewhere on the tooltip states. Used for the tooltip's "where does
-- this number come from" breakdown; GW.GetItemScore above stays the fast,
-- single-number version for everywhere else (ranking scans, weapon
-- comparisons) that doesn't need this extra detail.
-- specId is optional, same meaning as GW.GetItemScore - scores both items
-- against a specific spec's weights instead of the active spec's, for the
-- cross-spec comparison.
function GW.GetItemScoreBreakdownVsEquipped(itemLink, equippedLink, specId)
	local rawCandidateStats = GW.GetItemStats(itemLink)
	if not rawCandidateStats then return nil end
	-- GW.GetItemStats reuses one shared scratch table across every call - a
	-- second call for equippedLink below would otherwise silently overwrite
	-- this same table, leaving candidateStats and equippedStats aliased to
	-- the exact same (now-equipped-only) data and every diff computing to 0.
	local candidateStats = {}
	for k, v in pairs(rawCandidateStats) do candidateStats[k] = v end
	local equippedStats = equippedLink and GW.GetItemStats(equippedLink) or nil
	local profile = specId and GW.GetProfileForSpec(specId) or GW.GetActiveProfile()
	local known = GW.GetKnownStats()

	local seen = {}
	local breakdown = {}
	local function considerKey(key)
		if seen[key] or not GW.IsCanonicalStatKey(key) then return end
		seen[key] = true
		local w = profile.weights[key]
		if not w or w == 0 then return end
		local candidateValue = type(candidateStats[key]) == "number" and candidateStats[key] or 0
		local equippedValue = (equippedStats and type(equippedStats[key]) == "number") and equippedStats[key] or 0
		local diffValue = candidateValue - equippedValue
		if diffValue == 0 then return end
		table.insert(breakdown, {
			label = known[key] or key,
			-- The item's own stat value where it has one, otherwise (a stat
			-- only the equipped item has) the loss itself, so the displayed
			-- number is never a misleading "+0".
			displayValue = candidateValue ~= 0 and candidateValue or diffValue,
			contribution = diffValue * w,
		})
	end
	for key in pairs(candidateStats) do considerKey(key) end
	if equippedStats then
		for key in pairs(equippedStats) do considerKey(key) end
	end
	table.sort(breakdown, function(a, b) return math.abs(a.contribution) > math.abs(b.contribution) end)
	return breakdown
end

--------------------------------------------------------------------------------
-- Import / Export (bisbeard.com stat weight format)
--------------------------------------------------------------------------------

-- specId is optional - defaults to your current active spec; the Stats
-- tab's spec picker passes an explicit one to import into a DIFFERENT spec's
-- profile without needing to actually switch to it.
-- Returns: ok, appliedCount, pendingCount, skippedCount  (or ok=false, errorMessage)
function GW.ImportWeights(base64Str, specId)
	EnsureDB()
	local ok, jsonStr = pcall(Base64Decode, base64Str)
	if not ok or jsonStr == "" then
		return false, "Couldn't decode that as base64."
	end
	local data = FlatJsonDecode(jsonStr)
	if not next(data) then
		return false, "No recognizable weight data found in that string."
	end

	specId = specId or GW.GetCurrentSpecId()
	local profile = GW.GetProfileForSpec(specId)
	local known = GW.GetKnownStats()
	local labelToKey = {}
	for key, label in pairs(known) do labelToKey[label] = key end

	local charKey = GW.GetCurrentCharacterKey()
	GearWeightsDB.pendingImports[charKey] = GearWeightsDB.pendingImports[charKey] or {}
	GearWeightsDB.pendingImports[charKey][specId] = GearWeightsDB.pendingImports[charKey][specId] or {}

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
				GearWeightsDB.pendingImports[charKey][specId][label] = value
				pending = pending + 1
			end
		end
	end

	return true, applied, pending, skipped
end

-- specId is optional, same meaning as GW.ImportWeights.
function GW.ExportWeights(specId)
	local profile = specId and GW.GetProfileForSpec(specId) or GW.GetActiveProfile()
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

-- Explicitly calls this out when a weapon candidate would flip which loadout
-- (Two-Hand vs Main-Hand+Off-Hand Combo) scores higher overall - easy to miss
-- from the individual comparison lines alone, especially when a Main-Hand or
-- Off-Hand candidate looks unremarkable on its own but tips the COMBO's
-- total past your tracked Two-Hand (or vice versa). Same flip check that
-- already drives the ranking list's own [!] marker (GW.CheckWeaponLoadoutFlip).
local function AppendLoadoutFlipNote(tooltip, replacingBox, score)
	local flipped, newBetter = GW.CheckWeaponLoadoutFlip(replacingBox, score)
	if not flipped then return end
	local newBetterLabel = newBetter == "twoHand" and "Two-Hand" or "Main-Hand + Off-Hand Combo"
	tooltip:AddLine(string.format("|cffff8800[!] This would make %s your better loadout|r", newBetterLabel))
end

-- Returns score, bestDiff, usable, flipsLoadout, equippedLink. bestDiff is
-- nil if the item isn't equippable, or the best-case score difference vs
-- whatever it could replace, otherwise. usable is false if your class can't
-- use this item at all (score/diff also nil in that case). flipsLoadout is
-- true only for a Main-Hand/Off-Hand/Two-Hand weapon candidate that would
-- change which of your two remembered weapon loadouts (2H, or Main-Hand +
-- Off-Hand combo) scores higher - see GW.CheckWeaponLoadoutFlip - since
-- that's an important signal a plain per-slot diff can miss entirely.
-- equippedLink is whichever item bestDiff was actually computed against (nil
-- for an empty slot or a 2H item, whose comparison is a combined score, not
-- a single link) - used by the tooltip's stat breakdown to show each stat's
-- contribution relative to what you're already wearing, not just the
-- candidate's own absolute numbers. Used by the instance loot list too.
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
		local flipsLoadout = GW.CheckWeaponLoadoutFlip("twoHand", score)
		return score, score - GW.GetTwoHandComparisonScore(), nil, flipsLoadout
	end

	local slots = slotsForEquipLoc[equipLoc]
	if not slots or #slots == 0 then return score, nil end

	-- Unique-Equipped items can't have a second copy equipped once you're at
	-- the cap - if so, only the slot(s) already holding a copy of the exact
	-- same item are actually replaceable; comparing against an unrelated item
	-- in some other slot would suggest an upgrade you couldn't actually equip.
	slots = GW.GetUniqueEligibleSlots(itemLink, slots)

	-- An excluded armor type (Cloth/Leather/Mail/Plate, Settings tab) is a
	-- property of this item, not any one slot - if set, the item is still
	-- scored (score already returned above) but never counted as a real
	-- upgrade, same as every slot below being individually locked.
	local armorIgnoreReason = GW.GetArmorTypeIgnoreReason(itemLink)

	local bestDiff, bestSlotId, bestEquippedLink
	if not armorIgnoreReason then
		for _, slotId in ipairs(slots) do
			if not GW.GetSlotIgnoreReason(slotId) then
				local equippedLink = GW.GetEquippedLinkForScoring(slotId)
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
					bestSlotId = slotId
					bestEquippedLink = equippedLink
				end
			end
		end
	end

	local flipsLoadout
	if bestSlotId == INVSLOT_MAINHAND then
		flipsLoadout = GW.CheckWeaponLoadoutFlip("mainHand", score)
	elseif bestSlotId == INVSLOT_OFFHAND then
		flipsLoadout = GW.CheckWeaponLoadoutFlip("offHand", score)
	end

	return score, bestDiff, nil, flipsLoadout, bestEquippedLink
end

--------------------------------------------------------------------------------
-- Cross-spec tooltip comparison (Settings tab: Spec Comparisons). Shows
-- whether a candidate item would also be an upgrade for OTHER specs, not
-- just whichever one you're actively playing - there's no live "currently
-- equipped" for a spec you're not standing in, so this reads a Blizzard
-- Equipment Set the user has explicitly assigned to that spec instead.
--
-- Equipment Sets only expose bare item IDs (GetEquipmentSetItemIDs), not the
-- full item link a live-equipped item has - so gems/enchants on that spec's
-- saved gear aren't reflected in its score, only the base item's own stats.
-- Good enough to catch a real upgrade, but not perfectly precise.
--
-- Weapon slots are treated as plain single-slot comparisons here (whatever
-- the Equipment Set has in Main-Hand/Off-Hand), unlike the active spec's own
-- Two-Hand vs Main-Hand+Off-Hand combo logic - there's no way to track which
-- of two loadouts a non-active spec would rather use, since that tracking is
-- itself driven by live equip-change events for whichever spec IS active.
--------------------------------------------------------------------------------

-- The item this Equipment Set has saved for a given inventory slot, as a
-- plain (unenchanted/ungemmed) item link - nil if the set doesn't exist,
-- doesn't have anything saved for that slot, or the item isn't cached yet.
function GW.GetEquipmentSetItemLink(setName, slotId)
	if not setName or not slotId then return nil end
	local ok, itemIDs = pcall(GetEquipmentSetItemIDs, setName)
	if not ok or not itemIDs then return nil end
	local itemID = itemIDs[slotId]
	if not itemID or itemID <= 0 then return nil end
	local _, itemLink = GetItemInfo(itemID)
	return itemLink
end

-- Same shape of result as GW.GetBestUpgradeDiff (score, diff, equippedLink),
-- but for a specific OTHER spec's Equipment Set instead of your live
-- inventory - picks whichever of the item's relevant slot(s) gives the best
-- diff, same idea as GW.GetBestUpgradeDiff's own slot loop, simplified
-- (no Unique-Equipped/armor-type narrowing - this is an approximate "would
-- this be worth it" check for a spec you're not standing in, not a strict
-- guarantee you could equip it that instant).
function GW.GetSpecComparisonForItem(itemLink, specId, setName)
	if not setName then return nil end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)
	if not equipLoc then return nil end

	local score = GW.GetItemScore(itemLink, specId)
	if not score then return nil end

	local slots = slotsForEquipLoc[equipLoc]
	if not slots or #slots == 0 then return nil end

	local bestDiff, bestEquippedLink, sawAnySlot
	for _, slotId in ipairs(slots) do
		local equippedLink = GW.GetEquipmentSetItemLink(setName, slotId)
		local diff
		if not equippedLink then
			diff = score
		elseif equippedLink ~= itemLink then
			local equippedScore = GW.GetItemScore(equippedLink, specId)
			if equippedScore then diff = score - equippedScore end
		end
		if diff then
			sawAnySlot = true
			if not bestDiff or diff > bestDiff then
				bestDiff = diff
				bestEquippedLink = equippedLink
			end
		end
	end
	if not sawAnySlot then return nil end

	return score, bestDiff, bestEquippedLink
end

-- Blizzard's native shift-compare (ShoppingTooltip1/2) always shows whatever
-- is physically equipped right now, which is the wrong reference the moment
-- you're wearing a 2H and considering a 1H item (or vice versa), or have a
-- box locked to something you're not currently wearing at all (a quest
-- weapon, say). These are a second, independent set of tooltips - not a
-- hijack of Blizzard's own - that show the actual tracked reference item(s)
-- instead, only while shift is held (matching the native compare gesture)
-- and only for the primary hover tooltip (not ItemRefTooltip or the
-- ShoppingTooltips themselves, to avoid stacking compare-tooltips-on-compare-tooltips).
local weaponReferenceTooltips = {}
local weaponReferenceTooltipCount = 0

local function ResetWeaponReferenceTooltips()
	for _, tt in ipairs(weaponReferenceTooltips) do tt:Hide() end
	weaponReferenceTooltipCount = 0
end

-- Blizzard's native ShoppingTooltip1/2 already sit to the right of GameTooltip
-- (whichever is shown depends on the hovered item's equip type) - ours chain
-- further right of THOSE, in a horizontal row, rather than anchoring to
-- GameTooltip directly (which would land underneath/on top of Blizzard's own
-- tooltip) or stacking vertically below each other.
local function GetReferenceTooltipChainStart()
	if ShoppingTooltip2 and ShoppingTooltip2:IsShown() then return ShoppingTooltip2 end
	if ShoppingTooltip1 and ShoppingTooltip1:IsShown() then return ShoppingTooltip1 end
	return GameTooltip
end

-- Whether a tracked weapon box currently mirrors what's physically equipped -
-- if so, Blizzard's own native "Currently Equipped" compare tooltip already
-- shows this exact item on screen, so spawning our own reference tooltip for
-- it too would just be a second window for the same weapon. A box that's
-- locked to something different (or empty) never matches here, so it still
-- gets its own reference tooltip - nothing else on screen would show it
-- otherwise. This is a plain, synchronous inventory lookup - not state
-- written by another tooltip hook - so it carries none of the timing
-- dependency that caused the earlier combo-value race condition.
local function IsWeaponBoxShownNatively(box, link)
	if not link then return false end
	if box == "offHand" then
		return link == GetInventoryItemLink("player", INVSLOT_OFFHAND)
	end
	return link == GetInventoryItemLink("player", INVSLOT_MAINHAND)
end

-- Live-reads whatever GameTooltip is currently displaying, so Blizzard's
-- native "Currently Equipped" tooltip can show a real comparison against the
-- actual candidate you're weighing, instead of just a bare score. This is a
-- read of Blizzard's OWN live tooltip state at the moment it's called, not a
-- value written earlier by our own hook code - GameTooltip's displayed item
-- never changes mid-hover (only modifier keys toggle, which just re-runs
-- Blizzard's compare logic against that SAME unchanged item), so this always
-- reflects either the real current candidate or nothing at all - never a
-- stale leftover from a previous, different hover. That's what makes this
-- safe where the earlier shared-variable approach wasn't: there's no window
-- where a write from one hook could be read before or after it happens by
-- another - there's nothing written at all, just a live query answered the
-- same way regardless of when it's asked.
local function GetLiveHoveredCandidate(selfLink)
	if not GameTooltip:IsShown() then return nil end
	local candidateName, candidateLink = GameTooltip:GetItem()
	if not candidateLink or candidateLink == selfLink then return nil end
	local candidateScore = GW.GetItemScore(candidateLink)
	if not candidateScore then return nil end
	local _, _, _, _, _, _, _, _, candidateEquipLoc = GetItemInfo(candidateLink)
	return candidateLink, candidateScore, candidateEquipLoc, candidateName
end

-- comparisons is a list of { score=, vsScore=, prefix= } - each rendered as
-- its own "prefix: Upgrade/Downgrade (+X)" line, always candidate-relative
-- (score is always the item you're actually considering, vsScore is whatever
-- loadout piece this reference represents) rather than an existing-vs-existing
-- comparison that doesn't involve the candidate at all. A reference can need
-- more than one line - e.g. the Main-Hand box shows both its own direct
-- comparison AND the resulting combo-vs-Two-Hand comparison.
--
-- Callers skip calling this at all (via IsWeaponBoxShownNatively) when the
-- box being referenced is already visible in Blizzard's own native compare
-- tooltip - no need to duplicate a window that's already on screen.
local function ShowWeaponReferenceTooltip(referenceLink, label, comparisons)
	if not referenceLink then return end
	weaponReferenceTooltipCount = weaponReferenceTooltipCount + 1
	local tt = weaponReferenceTooltips[weaponReferenceTooltipCount]
	if not tt then
		tt = CreateFrame("GameTooltip", "GearWeightsReferenceTooltip" .. weaponReferenceTooltipCount, nil, "GameTooltipTemplate")
		tt:SetScale(0.8)
		weaponReferenceTooltips[weaponReferenceTooltipCount] = tt
	end
	local prev = weaponReferenceTooltips[weaponReferenceTooltipCount - 1]
	local anchor = prev or GetReferenceTooltipChainStart()
	tt:SetOwner(GameTooltip, "ANCHOR_NONE")
	tt:ClearAllPoints()
	tt:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
	tt:SetHyperlink(referenceLink)
	local referenceScore = GW.GetItemScore(referenceLink)
	if referenceScore then
		tt:AddLine(" ")
		tt:AddLine(string.format("GearWeights: %.1f", referenceScore), 0.4, 0.75, 1.0)
	end
	if comparisons then
		for _, c in ipairs(comparisons) do
			if c.info then
				tt:AddLine(c.info, 0.7, 0.7, 0.7)
			else
				AppendComparisonLine(tt, c.prefix, c.score, c.vsScore, nil)
			end
		end
	end
	tt:AddLine(" ")
	tt:AddLine("|cff888888GearWeights reference: " .. label .. "|r")
	tt:Show()
end

GameTooltip:HookScript("OnHide", ResetWeaponReferenceTooltips)

-- Per-stat breakdown of where the score comes from, relative to whatever
-- this would actually replace (same equipped item GW.GetBestUpgradeDiff
-- itself compares against) rather than each stat's absolute contribution -
-- so a stat this item has less of than what's equipped shows as a real
-- downgrade even though the item's own tooltip states a positive value for
-- it. Falls back to absolute contributions when there's nothing to compare
-- against (empty slot, or a 2H weapon, whose comparison is a combined score
-- rather than a single item). Appended after the Upgrade/Downgrade verdict
-- line(s) further up the tooltip rather than before them - the breakdown
-- explains a verdict you've already seen, not the reverse.
local function AppendScoreBreakdown(tooltip, itemLink)
	local _, _, _, _, breakdownEquippedLink = GW.GetBestUpgradeDiff(itemLink)
	local breakdown = GW.GetItemScoreBreakdownVsEquipped(itemLink, breakdownEquippedLink)
	if not breakdown then return end
	for _, entry in ipairs(breakdown) do
		local color = entry.contribution >= 0 and "|cff00ff00" or "|cffff4444"
		tooltip:AddLine(string.format("  %+.0f %s (%s%+.1f|r)", entry.displayValue, entry.label, color, entry.contribution), 0.7, 0.7, 0.7)
	end
end

-- Cross-spec comparison (Settings tab: Spec Comparisons) - appended at the
-- very end of every equippable item's tooltip, below the active spec's own
-- score/breakdown/comparison lines, one section per other spec the user has
-- ticked and assigned an Equipment Set to. Uses GW.GetSpecComparisonForItem
-- (Equipment-Set-based, since there's no live "currently equipped" for a
-- spec you're not standing in) and that spec's own saved stat weights, not
-- whichever spec is actually active right now.
local function AppendSpecComparisons(tooltip, itemLink)
	local specTargets = GW.GetSpecCompareTargets()
	if #specTargets == 0 then return end
	local fullBreakdown = GW.IsSpecCompareFullBreakdown()
	for _, target in ipairs(specTargets) do
		local specScore, specDiff, specEquippedLink = GW.GetSpecComparisonForItem(itemLink, target.specId, target.equipmentSet)
		if specScore then
			tooltip:AddLine(" ")
			tooltip:AddLine(string.format("%s: %.1f", GW.GetSpecName(target.specId), specScore), 0.4, 0.75, 1.0)
			if specDiff then
				if specDiff > 0.05 then
					tooltip:AddLine(string.format("  |cff00ff00Upgrade (+%.1f)|r", specDiff))
				elseif specDiff < -0.05 then
					tooltip:AddLine(string.format("  |cffff4444Downgrade (%.1f)|r", specDiff))
				else
					tooltip:AddLine("  |cffffff00Sidegrade (~equal)|r")
				end
			end
			if fullBreakdown then
				local specBreakdown = GW.GetItemScoreBreakdownVsEquipped(itemLink, specEquippedLink, target.specId)
				if specBreakdown then
					for _, entry in ipairs(specBreakdown) do
						local color = entry.contribution >= 0 and "|cff00ff00" or "|cffff4444"
						tooltip:AddLine(string.format("    %+.0f %s (%s%+.1f|r)", entry.displayValue, entry.label, color, entry.contribution), 0.7, 0.7, 0.7)
					end
				end
			end
		end
	end
end

local function AppendScoreLines(tooltip, itemLink)
	if not itemLink then return end

	-- Blizzard's native "Currently Equipped" compare tooltip (ShoppingTooltip1/2)
	-- is used below (together with GetLiveHoveredCandidate) to give a tracked
	-- weapon box's own self-reference case a real, live comparison against
	-- whatever candidate you're actually hovering, instead of just a bare
	-- score.
	local isNativeCompareTooltip = tooltip == ShoppingTooltip1 or tooltip == ShoppingTooltip2

	-- Only the primary hover tooltip, and only while shift is held (matching
	-- the native compare gesture), ever shows the supplementary reference
	-- tooltips - reset on every call so a previous item's leftovers don't
	-- linger once you move to a new item or let go of shift.
	local showReferenceTooltips = tooltip == GameTooltip and IsShiftKeyDown() and true or false
	if tooltip == GameTooltip then
		ResetWeaponReferenceTooltips()
	end

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
		AppendScoreBreakdown(tooltip, itemLink)
		tooltip:Show()
		return
	end

	-- A 2H weapon replaces both the main hand and off hand, so it's compared
	-- against BOTH of your remembered weapon loadouts independently - your
	-- Two-Hand reference, and your Main-Hand + Off-Hand combo - rather than
	-- only whichever currently scores higher, since you want to know how it
	-- stacks up against each on its own terms.
	if equipLoc == "INVTYPE_2HWEAPON" then
		local mhIgnoreReason = GW.GetSlotIgnoreReason(INVSLOT_MAINHAND)
		local twoHandLink = GW.GetWeaponBoxLink("twoHand")
		local mhLink = GW.GetWeaponBoxLink("mainHand")
		local ohLink = GW.GetWeaponBoxLink("offHand")
		-- Comparing this item against itself (you're looking at whatever's
		-- currently in the Two-Hand box) is meaningless and skipped, but the
		-- combo comparison below is still real, useful information even then.
		local isOwnTwoHandReference = twoHandLink == itemLink
		if not twoHandLink and not mhLink and not ohLink then
			tooltip:AddLine(mhIgnoreReason and ("|cff888888Upgrade (weapon slots empty) (" .. mhIgnoreReason .. ")|r") or "|cff00ff00Upgrade (weapon slots empty)|r")
		else
			local twoHandScore = twoHandLink and GW.GetItemScore(twoHandLink) or 0
			-- This 2H item's own combo math is always the plain, existing
			-- Main-Hand + Off-Hand loadout - it never tries to fold in
			-- whatever Main-Hand/Off-Hand item you might ALSO be evaluating
			-- right now via any state shared across tooltip hooks (that
			-- approach caused a real race condition). The one exception is
			-- just below: Blizzard's native tooltip showing this exact item
			-- substitutes a live read of whatever you're actually hovering
			-- instead, which is safe for the reasons explained above
			-- GetLiveHoveredCandidate.
			local comboScore = (mhLink and GW.GetItemScore(mhLink) or 0) + (ohLink and GW.GetItemScore(ohLink) or 0)
			if not isOwnTwoHandReference then
				AppendComparisonLine(tooltip, string.format("vs Two-Hand %.1f: ", twoHandScore), score, twoHandScore, mhIgnoreReason)
			end
			if isOwnTwoHandReference and isNativeCompareTooltip then
				-- This IS your tracked Two-Hand weapon's own "Currently
				-- Equipped" tooltip - show how it stacks up against whatever
				-- you're actually hovering right now, live, rather than a
				-- bare score with no comparison at all.
				local candidateLink, candidateScore, candidateEquipLoc, candidateName = GetLiveHoveredCandidate(itemLink)
				if candidateEquipLoc == "INVTYPE_2HWEAPON" then
					AppendComparisonLine(tooltip, string.format("vs %s %.1f: ", candidateName, candidateScore), candidateScore, score, mhIgnoreReason)
				elseif candidateEquipLoc and slotsForEquipLoc[candidateEquipLoc] then
					for _, slotId in ipairs(slotsForEquipLoc[candidateEquipLoc]) do
						local newComboScore
						if slotId == INVSLOT_MAINHAND then
							newComboScore = candidateScore + (ohLink and GW.GetItemScore(ohLink) or 0)
						elseif slotId == INVSLOT_OFFHAND then
							newComboScore = (mhLink and GW.GetItemScore(mhLink) or 0) + candidateScore
						end
						if newComboScore then
							tooltip:AddLine(string.format("Main-Hand + Off-Hand Combo: %.1f", newComboScore), 0.7, 0.7, 0.7)
							AppendComparisonLine(tooltip, string.format("Combo vs Two-Hand %.1f: ", score), newComboScore, score, mhIgnoreReason)
						end
					end
				end
			else
				-- A 2H candidate doesn't change your Main-Hand + Off-Hand combo
				-- at all (unlike a Main-Hand/Off-Hand candidate, where the combo
				-- line above it already establishes what "combo" means
				-- numerically here) - so state the existing combo's value
				-- plainly first, then compare against it.
				tooltip:AddLine(string.format("Main-Hand + Off-Hand Combo: %.1f", comboScore), 0.7, 0.7, 0.7)
				-- Framed with the CANDIDATE as the subject ("vs Combo: Upgrade/
				-- Downgrade"), same as "vs Two-Hand" above it - both describe
				-- this candidate's own standing against a reference. The
				-- previous "Combo vs Two-Hand" framing put the existing combo
				-- as the subject instead, and reused "Two-Hand" to mean the
				-- candidate itself (not your tracked Two-Hand box, which is
				-- what it means one line up) - a real ambiguity, not just an
				-- inconsistent tone.
				AppendComparisonLine(tooltip, string.format("vs Combo %.1f: ", comboScore), score, comboScore, mhIgnoreReason)
				AppendLoadoutFlipNote(tooltip, "twoHand", score)
			end
			-- Always show all three tracked references, regardless of which
			-- one happens to be physically equipped right now - a locked box
			-- is deliberately showing something you're NOT currently wearing,
			-- so deferring to Blizzard's native "currently equipped" tooltip
			-- would hide exactly the reference you locked it for. Fixed
			-- order (Main-Hand, then Off-Hand, then Two-Hand) every time.
			if showReferenceTooltips then
				local comboInfo = { info = string.format("Main-Hand + Off-Hand Combo: %.1f", comboScore) }
				-- Candidate as subject, matching the main tooltip's own "vs
				-- Combo" framing above.
				local comboComparison = { score = score, vsScore = comboScore,
					prefix = string.format("vs Combo %.1f: ", comboScore) }
				if mhLink and not IsWeaponBoxShownNatively("mainHand", mhLink) then
					ShowWeaponReferenceTooltip(mhLink, "Main-Hand", { comboInfo, comboComparison })
				end
				if ohLink and not IsWeaponBoxShownNatively("offHand", ohLink) then
					ShowWeaponReferenceTooltip(ohLink, "Off-Hand", { comboInfo, comboComparison })
				end
				if not isOwnTwoHandReference and not IsWeaponBoxShownNatively("twoHand", twoHandLink) then
					ShowWeaponReferenceTooltip(twoHandLink, "Two-Hand", { {
						score = score, vsScore = twoHandScore,
						prefix = string.format("vs Two-Hand %.1f: ", twoHandScore),
					} })
				end
			end
		end
		AppendScoreBreakdown(tooltip, itemLink)
		AppendSpecComparisons(tooltip, itemLink)
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
	-- against whatever's in the *other* ring/trinket slot is a real number but
	-- a misleading one here - it looks like it's judging this item against
	-- the thing you're actually considering, when it isn't. Just show the
	-- plain score instead of a comparison that isn't about that decision.
	-- Main-Hand/Off-Hand are exempted: the per-slot loop below already skips
	-- a misleading self-comparison line for them specifically, but still
	-- needs to run so the Combo vs Two-Hand line shows even when you're
	-- looking at whatever's currently in that reference box.
	for _, slotId in ipairs(slots) do
		if slotId ~= INVSLOT_MAINHAND and slotId ~= INVSLOT_OFFHAND
			and GW.GetEquippedLinkForScoring(slotId) == itemLink then
			AppendScoreBreakdown(tooltip, itemLink)
			AppendSpecComparisons(tooltip, itemLink)
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

	-- An excluded armor type (Cloth/Leather/Mail/Plate, Settings tab) is a
	-- property of this item itself, not any one slot - computed once and
	-- folded into every slot's ignore reason below, same "still shown, not
	-- counted as a real upgrade" treatment a locked slot gets.
	local armorIgnoreReason = GW.GetArmorTypeIgnoreReason(itemLink)

	local shownTwoHandReference = false
	for _, slotId in ipairs(slots) do
		local equippedLink = GW.GetEquippedLinkForScoring(slotId)
		local label = slotLabels[slotId]
		local prefix = label and (label .. ": ") or ""
		local slotBlockedBy2H = slotId == INVSLOT_OFFHAND and IsMainHandTwoHanded()
		local slotIgnoreReason = GW.GetSlotIgnoreReason(slotId) or armorIgnoreReason
		if uniqueNarrowed and not uniqueEligible[slotId] and equippedLink and equippedLink ~= itemLink then
			local equippedScore = GW.GetItemScore(equippedLink)
			if equippedScore then
				local diff = score - equippedScore
				local wouldBeNote = diff > 0.05 and string.format(" - would be +%.1f", diff) or ""
				tooltip:AddLine(prefix .. "|cff888888Blocked by Unique-Equip limit" .. wouldBeNote .. "|r")
			end
		elseif not equippedLink then
			if slotBlockedBy2H then
				tooltip:AddLine(prefix .. "|cff888888Blocked by 2H Main-Hand|r")
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

		-- Weapons are a two-piece system: also compare what the Main-Hand +
		-- Off-Hand total would be with this item in this slot (alongside
		-- whichever tracked reference occupies the other hand) against your
		-- Two-Hand reference - independent of what's physically equipped
		-- right now, since the whole point of the reference boxes is to
		-- reason about your intended loadout even if you're literally
		-- wearing a quest weapon at this moment.
		if slotId == INVSLOT_MAINHAND or slotId == INVSLOT_OFFHAND then
			local mhLink = GW.GetWeaponBoxLink("mainHand")
			local ohLink = GW.GetWeaponBoxLink("offHand")
			local mhScore = mhLink and GW.GetItemScore(mhLink) or nil
			local ohScore = ohLink and GW.GetItemScore(ohLink) or nil
			local newComboScore
			if slotId == INVSLOT_MAINHAND then
				newComboScore = score + (ohScore or 0)
			else
				newComboScore = (mhScore or 0) + score
			end
			local twoHandLink = GW.GetWeaponBoxLink("twoHand")
			local twoHandScore = twoHandLink and GW.GetItemScore(twoHandLink) or 0
			local oldComboScore = (mhScore or 0) + (ohScore or 0)
			-- On Blizzard's native tooltip showing your tracked Main-Hand/
			-- Off-Hand item itself, "newComboScore" above is computed from
			-- itemLink (this box's own item), so it's identical to the old
			-- combo - not useful. Substitute a live read of whatever you're
			-- actually hovering instead (see GetLiveHoveredCandidate), same
			-- as the Two-Hand case above.
			local isOwnHandReference = (slotId == INVSLOT_MAINHAND and itemLink == mhLink)
				or (slotId == INVSLOT_OFFHAND and itemLink == ohLink)
			if isOwnHandReference and isNativeCompareTooltip then
				local candidateLink, candidateScore, candidateEquipLoc = GetLiveHoveredCandidate(itemLink)
				if candidateEquipLoc and slotsForEquipLoc[candidateEquipLoc] then
					for _, candidateSlotId in ipairs(slotsForEquipLoc[candidateEquipLoc]) do
						local liveComboScore
						if candidateSlotId == INVSLOT_MAINHAND then
							liveComboScore = candidateScore + (ohScore or 0)
						elseif candidateSlotId == INVSLOT_OFFHAND then
							liveComboScore = (mhScore or 0) + candidateScore
						end
						if liveComboScore then
							AppendComparisonLine(tooltip, string.format("  Combo Main-Hand + Off-Hand %.1f: ", liveComboScore), liveComboScore, oldComboScore, nil)
							AppendComparisonLine(tooltip, string.format("  Combo vs Two-Hand %.1f: ", twoHandScore), liveComboScore, twoHandScore, nil)
						end
					end
				end
			else
				-- The new combo total is shown explicitly (not just its diff),
				-- so it's never ambiguous whether an embedded number belongs to
				-- the combo or to Two-Hand - "Combo Main-Hand + Off-Hand 81.4:"
				-- names its own value before "Combo vs Two-Hand 86.3:" names its.
				AppendComparisonLine(tooltip, string.format("  Combo Main-Hand + Off-Hand %.1f: ", newComboScore), newComboScore, oldComboScore, nil)
				AppendComparisonLine(tooltip, string.format("  Combo vs Two-Hand %.1f: ", twoHandScore), newComboScore, twoHandScore, nil)
				AppendLoadoutFlipNote(tooltip, slotId == INVSLOT_MAINHAND and "mainHand" or "offHand", score)
			end

			-- Always show all three tracked references, regardless of what's
			-- physically equipped right now (a locked box is deliberately
			-- showing something you're not currently wearing) - fixed order
			-- (Main-Hand, then Off-Hand, then Two-Hand) every time, whichever
			-- hand this candidate itself occupies. The same-hand reference is
			-- the only one that matters individually (an upgrade there is
			-- automatically an upgrade to the combo too), so it gets its own
			-- direct comparison too, on top of the two combo lines every
			-- reference shows.
			if showReferenceTooltips then
				local comboComparisons = {
					{ score = newComboScore, vsScore = oldComboScore,
						prefix = string.format("Combo Main-Hand + Off-Hand %.1f: ", newComboScore) },
					{ score = newComboScore, vsScore = twoHandScore,
						prefix = string.format("Combo vs Two-Hand %.1f: ", twoHandScore) },
				}
				if slotId == INVSLOT_MAINHAND then
					if mhLink and mhLink ~= itemLink and mhScore and not IsWeaponBoxShownNatively("mainHand", mhLink) then
						ShowWeaponReferenceTooltip(mhLink, "Main-Hand", {
							{ score = score, vsScore = mhScore, prefix = string.format("vs Main-Hand %.1f: ", mhScore) },
							comboComparisons[1], comboComparisons[2],
						})
					end
					if ohLink and not IsWeaponBoxShownNatively("offHand", ohLink) then
						ShowWeaponReferenceTooltip(ohLink, "Off-Hand", comboComparisons)
					end
				else
					if mhLink and not IsWeaponBoxShownNatively("mainHand", mhLink) then
						ShowWeaponReferenceTooltip(mhLink, "Main-Hand", comboComparisons)
					end
					if ohLink and ohLink ~= itemLink and ohScore and not IsWeaponBoxShownNatively("offHand", ohLink) then
						ShowWeaponReferenceTooltip(ohLink, "Off-Hand", {
							{ score = score, vsScore = ohScore, prefix = string.format("vs Off-Hand %.1f: ", ohScore) },
							comboComparisons[1], comboComparisons[2],
						})
					end
				end
				if not shownTwoHandReference and not IsWeaponBoxShownNatively("twoHand", twoHandLink) then
					shownTwoHandReference = true
					ShowWeaponReferenceTooltip(twoHandLink, "Two-Hand", comboComparisons)
				end
			end
		end
	end

	AppendScoreBreakdown(tooltip, itemLink)
	AppendSpecComparisons(tooltip, itemLink)
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
			-- The structured extended-cost API is coming back empty (0 cost
			-- kinds) despite extendedCost being flagged true, so check whether
			-- the real cost is only exposed as plain tooltip text instead -
			-- some custom currency implementations do it that way.
			if n > 0 then
				if not GearWeightsVendorDiagTooltip then
					GearWeightsVendorDiagTooltip = CreateFrame("GameTooltip", "GearWeightsVendorDiagTooltip", nil, "GameTooltipTemplate")
				end
				GearWeightsVendorDiagTooltip:SetOwner(UIParent, "ANCHOR_NONE")
				GearWeightsVendorDiagTooltip:SetMerchantItem(1)
				DEFAULT_CHAT_FRAME:AddMessage("-- Tooltip lines for item 1 --")
				for i = 1, GearWeightsVendorDiagTooltip:NumLines() do
					local left = _G["GearWeightsVendorDiagTooltipTextLeft" .. i]
					local right = _G["GearWeightsVendorDiagTooltipTextRight" .. i]
					local lt = left and left:GetText()
					local rt = right and right:GetText()
					DEFAULT_CHAT_FRAME:AddMessage(string.format("  L%d: left=%s right=%s", i, tostring(lt), tostring(rt)))
				end
			end
		end
	elseif strsub(msg, 1, 7) == "repdiag" then
		-- Diagnostic for the planned Reputations category: dumps AtlasLoot_Data's
		-- real structure for whatever zone name matches, so we can see how
		-- Friendly/Honored/Revered/Exalted are actually encoded (mode headers,
		-- like Normal/Heroic Mode already are for dungeons, or something else)
		-- before building the real feature on top of a guess.
		local search = strtrim(strsub(msg, 8)):lower()
		if search == "" then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: usage /gw repdiag <name search>, e.g. /gw repdiag argent")
		elseif not AtlasLoot_Data then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: AtlasLoot_Data not loaded yet.")
		else
			local matches = 0
			for key, data in pairs(AtlasLoot_Data) do
				local name = data.Name
				if type(name) == "string" and strfind(name:lower(), search, 1, true) then
					matches = matches + 1
					DEFAULT_CHAT_FRAME:AddMessage(string.format("-- key=%s Name=%s Type=%s Side=%s #entries=%d --",
						tostring(key), tostring(name), tostring(data.Type), tostring(data.Side), #data))
					for i, boss in ipairs(data) do
						if i > 3 then
							DEFAULT_CHAT_FRAME:AddMessage("  ... (" .. (#data - 3) .. " more, truncated)")
							break
						end
						DEFAULT_CHAT_FRAME:AddMessage(string.format("  [%d] boss.Name=%s #sections=%d", i, tostring(boss.Name), #boss))
						for si, section in ipairs(boss) do
							if si > 3 then
								DEFAULT_CHAT_FRAME:AddMessage("    ... (more sections truncated)")
								break
							end
							local first = section[1]
							local isHeader = first ~= nil and first.name ~= nil and first.itemID == nil
							DEFAULT_CHAT_FRAME:AddMessage(string.format(
								"    section %d: #items=%d firstEntry.name=%s firstEntry.itemID=%s isModeHeader=%s",
								si, #section, tostring(first and first.name), tostring(first and first.itemID), tostring(isHeader)))
						end
					end
				end
			end
			if matches == 0 then
				DEFAULT_CHAT_FRAME:AddMessage("GearWeights: no AtlasLoot_Data entries matched '" .. search .. "'.")
			end
		end
	elseif strsub(msg, 1, 8) == "repcheck" then
		-- Per-item breakdown for one tracked reputation faction: for every
		-- item AtlasLoot lists there, shows what GW.GetItemReputationRequirement
		-- found on its tooltip, whether that faction is one your character can
		-- actually earn (GetFactionInfo), whether the standing tier is
		-- currently ticked, and the final GW.GetBestUpgradeDiff verdict - so a
		-- faction reporting zero/wrong upgrades can be diagnosed item by item
		-- instead of guessed at.
		local search = strtrim(strsub(msg, 9)):lower()
		if search == "" then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: usage /gw repcheck <faction name search>, e.g. /gw repcheck argent dawn")
		elseif not AtlasLoot_Data then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: AtlasLoot_Data not loaded yet.")
		elseif not GW.REPUTATION_ZONE_LIST then
			DEFAULT_CHAT_FRAME:AddMessage("GearWeights: GW.REPUTATION_ZONE_LIST not found.")
		else
			local matchedZone
			for _, repZone in ipairs(GW.REPUTATION_ZONE_LIST) do
				if strfind(repZone.name:lower(), search, 1, true) then
					matchedZone = repZone
					break
				end
			end
			if not matchedZone then
				DEFAULT_CHAT_FRAME:AddMessage("GearWeights: no tracked reputation faction matched '" .. search .. "'.")
			else
				local data = AtlasLoot_Data[matchedZone.key]
				if not data then
					DEFAULT_CHAT_FRAME:AddMessage("GearWeights: AtlasLoot_Data['" .. matchedZone.key .. "'] not found.")
				else
					DEFAULT_CHAT_FRAME:AddMessage("-- Reputation check: " .. matchedZone.name .. " (key=" .. matchedZone.key .. ") --")
					if matchedZone.available == false then
						DEFAULT_CHAT_FRAME:AddMessage("  |cffff4444Note: this faction is marked unavailable (not confirmed live on this server yet) and is greyed out/excluded from the real scan regardless of the verdicts below.|r")
					end
					local seen = {}
					for _, boss in ipairs(data) do
						for _, section in ipairs(boss) do
							for _, entry in ipairs(section) do
								if entry and entry.itemID then
									local itemName, itemLink = GetItemInfo(entry.itemID)
									if not itemLink then
										DEFAULT_CHAT_FRAME:AddMessage(string.format("  [id %d] |cff888888not resolved (GetItemInfo nil - not cached yet)|r", entry.itemID))
									elseif not seen[itemLink] then
										seen[itemLink] = true
										if GW.IsReputationItemExcluded and GW.IsReputationItemExcluded(itemName) then
											DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s |cff888888excluded (quest-reward item, not reputation-gated)|r", itemName))
										else
											local factionName, standing = GW.GetItemReputationRequirement(itemLink)
											local source = "tooltip"
											if not standing then
												local override = GW.GetReputationItemOverride and GW.GetReputationItemOverride(itemName)
												if override then
													standing = override.standing
													factionName = override.factionName
													source = "override"
												end
											end
											if not standing then
												DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s |cffff4444no \"Requires X - Y\" line found|r", itemName))
											else
												-- Deliberately NOT checking whether this faction is
												-- currently in the reputation pane - most classic reps
												-- stay hidden until an unlock quest is done, and the
												-- goal is to surface "worth going to earn" upgrades
												-- even before that. Only a genuine Alliance/Horde
												-- side-lock excludes an item.
												local reachableOk = GW.IsReputationFactionReachable and GW.IsReputationFactionReachable(factionName)
												local tierOk = GW.IsReputationTierEnabled and GW.IsReputationTierEnabled(standing)
												local score, diff, usable = GW.GetBestUpgradeDiff(itemLink)
												local verdict
												if not reachableOk then
													verdict = "|cff888888wrong Alliance/Horde side|r"
												elseif not tierOk then
													verdict = "|cff888888standing tier disabled in settings|r"
												elseif usable == false then
													verdict = "|cffff4444not usable by your class|r"
												elseif not diff then
													verdict = "|cff888888no diff (nothing to compare against)|r"
												elseif diff <= 0.05 then
													verdict = string.format("|cff888888not an upgrade (%.1f)|r", diff)
												else
													verdict = string.format("|cff00ff00WOULD REPORT (+%.1f)|r", diff)
												end
												DEFAULT_CHAT_FRAME:AddMessage(string.format(
													"  %s - Requires %s - %s (%s) | reachable=%s tierEnabled=%s | %s",
													itemName, factionName, standing, source, tostring(reachableOk), tostring(tierOk), verdict))
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	else
		if GearWeightsUI_Toggle then GearWeightsUI_Toggle() end
	end
end
