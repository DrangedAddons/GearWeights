local GW = GearWeights

--------------------------------------------------------------------------------
-- Reads AtlasLoot's bundled dungeon/raid database to build a scored loot list
-- for whatever instance you're currently in. AtlasLoot's data uses stock
-- Blizzard item IDs; AtlasLoot_Cache's GetItemDifficultyID() resolves those to
-- Ascension's actual custom item IDs where a correction is known. Anything
-- that fails to resolve to a real item is skipped rather than shown wrong.
--------------------------------------------------------------------------------

-- Every AtlasLoot expansion module is Load-On-Demand: being "enabled" in the
-- addon list does NOT mean it's actually loaded into memory, and AtlasLoot_Data
-- only gets populated for a module once something explicitly loads it (normally
-- triggered by manually browsing to that content in AtlasLoot's own UI). Force
-- all of them to load ourselves instead of depending on that.
local atlasLootModules = {
	"AtlasLoot_OriginalWoW", "AtlasLoot_BurningCrusade", "AtlasLoot_WrathoftheLichKing",
	"AtlasLoot_Crafting_OriginalWoW", "AtlasLoot_Crafting_TBC", "AtlasLoot_Crafting_Wrath",
	"AtlasLoot_Vanity", "AtlasLoot_WorldEvents",
}
local modulesLoaded = false
local function EnsureAtlasLootModulesLoaded()
	if modulesLoaded then return end
	modulesLoaded = true
	for _, name in ipairs(atlasLootModules) do
		if not IsAddOnLoaded(name) then
			pcall(LoadAddOn, name)
		end
	end
end

-- AtlasLoot's own files never rely on a plain global "AtlasLoot" - each of
-- their files does `local AtlasLoot = LibStub("AceAddon-3.0"):GetAddon("AtlasLoot")`
-- to get a reference. Whether a matching global also exists turned out to be
-- unreliable (confirmed nil in testing), so fetch it the same way they do.
local function GetAtlasLootAddon()
	if not LibStub then return nil end
	local ok, addon = pcall(function() return LibStub("AceAddon-3.0"):GetAddon("AtlasLoot") end)
	if ok then return addon end
	return nil
end
GW.GetAtlasLootAddon = GetAtlasLootAddon

-- AtlasLoot itself defines the real difficulty tiers per zone Type (WrathDungeon,
-- ClassicDungeon, ClassicDungeonExt, etc.) in Core/Difficultys.lua, including
-- Ascension's extended Mythic 1-40 tiers.
--
-- GetInstanceInfo()'s difficultyName is unreliable here - it's sometimes
-- formatted text like "5 Player (Heroic)" and sometimes completely blank
-- (observed on Mythic). WoW's raw difficultyIndex is a clean small integer
-- instead, and appears to use a fixed, zone-type-independent numbering
-- (1=Normal, 2=Heroic, 3=Mythic, 4=Mythic 1, ...) offset by exactly 2 from
-- AtlasLoot's own "param" numbering (which reserves 1-2 for Bloodforged
-- tiers). Confirmed against two different zone Types with different table
-- shapes - ClassicDungeon (no Bloodforged slot) and ClassicDungeonExt (has
-- one) - both giving difficultyIndex 2 = Heroic = param 4, so this is a fixed
-- offset, not a lookup by position within the per-type array (which
-- differs between types and would be off-by-one for ClassicDungeonExt).
-- Text matching is kept as a fallback only, for when difficultyIndex is nil.
local function GetDifficultyParam(zoneType, difficultyIndex, difficultyName)
	local atlasLoot = GetAtlasLootAddon()
	local tiers = atlasLoot and atlasLoot.Difficulties and atlasLoot.Difficulties[zoneType]

	if difficultyIndex then
		local param = difficultyIndex + 2
		if not tiers or not tiers.Max or param <= tiers.Max then
			return param
		end
	end

	if tiers and difficultyName and difficultyName ~= "" then
		local bestParam, bestLen = nil, -1
		for _, tier in ipairs(tiers) do
			local name = tier[1]
			if name and strfind(difficultyName, name, 1, true) and strlen(name) > bestLen then
				bestParam = tier[2]
				bestLen = strlen(name)
			end
		end
		if bestParam then return bestParam end
	end

	return 3
end

-- Some zones (Dire Maul so far) are split into multiple separate AtlasLoot
-- entries ("Dire Maul East"/"West"/"North") that all share the same plain
-- GetRealZoneText() ("Dire Maul") - an exact name match can't tell them
-- apart. GetSubZoneText() can, since each wing's entrance area has its own
-- subzone name. Confirmed so far: "Capital Gardens" = West (matched against
-- user-confirmed location). Add entries here as other wings get confirmed.
local subzoneToWingSuffix = {
	["Capital Gardens"] = "West",
}

local function FindZoneData(zoneName)
	if not AtlasLoot_Data then return nil end

	local exactMatch, prefixMatches = nil, nil
	for key, data in pairs(AtlasLoot_Data) do
		if data.Name == zoneName then
			exactMatch = { data, key }
		elseif type(data.Name) == "string" and strfind(data.Name, zoneName .. " ", 1, true) == 1 then
			prefixMatches = prefixMatches or {}
			table.insert(prefixMatches, { data, key })
		end
	end

	if prefixMatches then
		-- Multiple wings share this zone name (e.g. Dire Maul East/West/North) -
		-- disambiguate using the subzone, since the plain zone name is ambiguous.
		local subzone = GetSubZoneText()
		local wingSuffix = subzone and subzoneToWingSuffix[subzone]
		if wingSuffix then
			for _, match in ipairs(prefixMatches) do
				if strfind(match[1].Name, wingSuffix, 1, true) then
					return match[1], match[2]
				end
			end
		end
		-- Unknown subzone for a known multi-wing zone - don't guess wrong.
		return nil
	end

	if exactMatch then
		return exactMatch[1], exactMatch[2]
	end
	return nil
end

local function IsModeHeader(entry)
	return entry ~= nil and entry.name ~= nil and entry.itemID == nil
end

-- Returns a flat array of item entries for this boss. WotLK-era dungeons split
-- each boss into Normal Mode/Heroic Mode sections (a header entry followed by
-- items), so those get filtered by matchText. Older/classic-era dungeons here
-- don't have that split at all - Ascension seems to just inject extra items
-- directly into flat item groups (e.g. main loot vs. trophy items) - so for
-- those, everything is included regardless of difficulty.
local function GetBossItemEntries(boss, matchText)
	local hasAnyModeHeader = false
	for _, section in ipairs(boss) do
		if IsModeHeader(section[1]) then
			hasAnyModeHeader = true
			break
		end
	end

	local entries = {}
	for _, section in ipairs(boss) do
		local first = section[1]
		if hasAnyModeHeader then
			if IsModeHeader(first) and strfind(first.name, matchText) then
				for i = 2, #section do
					if section[i] and section[i].itemID then table.insert(entries, section[i]) end
				end
			end
		else
			for i = 1, #section do
				if section[i] and section[i].itemID then table.insert(entries, section[i]) end
			end
		end
	end
	return entries
end

local function ResolveItemLink(stockItemId, diffParam)
	local realId = stockItemId
	if GetItemDifficultyID then
		local ok, resolved = pcall(GetItemDifficultyID, stockItemId, diffParam)
		if ok and resolved then realId = resolved end
	end
	local itemName, itemLink = GetItemInfo(realId)
	return itemLink, realId
end

-- Async: processes a handful of items per frame instead of the whole zone's
-- item list (can be 300+) in one unbroken stretch of Lua execution, since
-- that was happening automatically right after every dungeon loading screen.
-- Calls onComplete(status, list, zoneName, pendingIds) once done.
--   status: "ok", "notInInstance", "noData"
--   list: array of { bossName, itemLink, score, diff, zoneKey, bossIndex, stockItemId }
local BATCH_SIZE = 15

function GW.BuildInstanceLootList(onComplete)
	EnsureAtlasLootModulesLoaded()

	local instanceName, instanceType, difficultyIndex, difficultyName = GetInstanceInfo()
	if instanceType ~= "party" and instanceType ~= "raid" then
		onComplete("notInInstance")
		return
	end

	-- AtlasLoot's own ShowInstance() matches on GetRealZoneText() first, so try
	-- that the same way it does. But some zones have been renamed on the live
	-- server while AtlasLoot's bundled data still uses the old name - confirmed
	-- for Sunken Temple, where GetRealZoneText() now returns "The Temple of
	-- Atal'Hakkar" but AtlasLoot_Data's entry is still named "Sunken Temple".
	-- GetInstanceInfo()'s first return still gives the old name in that case,
	-- so fall back to it when the real zone text doesn't match anything.
	local zoneName = GetRealZoneText() or instanceName
	local zoneData, zoneKey = FindZoneData(zoneName)
	if not zoneData and instanceName and instanceName ~= zoneName then
		zoneData, zoneKey = FindZoneData(instanceName)
		if zoneData then zoneName = instanceName end
	end
	if not zoneData then
		onComplete("noData", nil, zoneName)
		return
	end

	local diffParam = GetDifficultyParam(zoneData.Type, difficultyIndex, difficultyName)
	-- The physical Normal Mode/Heroic Mode item split (where it exists, e.g.
	-- WotLK dungeons) only distinguishes Normal vs Heroic-and-above; anything
	-- past Heroic is layered on top via GetItemDifficultyID's scaling.
	-- difficultyIndex 1 = Normal, 2+ = Heroic and above (difficultyName text
	-- can be blank on higher tiers, so don't rely on it here).
	local sectionMatchText = (difficultyIndex and difficultyIndex >= 2) and "Heroic" or "Normal"

	-- Flatten everything upfront so it can be worked through in small batches.
	local workQueue = {}
	for bossIndex, boss in ipairs(zoneData) do
		if boss.Name then
			local entries = GetBossItemEntries(boss, sectionMatchText)
			for _, entry in ipairs(entries) do
				table.insert(workQueue, { bossIndex = bossIndex, bossName = boss.Name, entry = entry })
			end
		end
	end

	local list = {}
	local pendingIds = {}
	local i = 1

	local worker = CreateFrame("Frame")
	worker:SetScript("OnUpdate", function(self)
		local processed = 0
		while i <= #workQueue and processed < BATCH_SIZE do
			local work = workQueue[i]
			local entry = work.entry
			local itemLink = ResolveItemLink(entry.itemID, diffParam)
			if itemLink then
				local score, diff, usable = GW.GetBestUpgradeDiff(itemLink)
				if usable == false then
					table.insert(list, {
						bossName = work.bossName,
						itemLink = itemLink,
						unusable = true,
						zoneKey = zoneKey,
						bossIndex = work.bossIndex,
						stockItemId = entry.itemID,
					})
				elseif score then
					table.insert(list, {
						bossName = work.bossName,
						itemLink = itemLink,
						score = score,
						diff = diff,
						zoneKey = zoneKey,
						bossIndex = work.bossIndex,
						stockItemId = entry.itemID,
					})
				end
			else
				table.insert(pendingIds, entry.itemID)
			end
			i = i + 1
			processed = processed + 1
		end

		if i > #workQueue then
			self:SetScript("OnUpdate", nil)
			-- Deliberately not sorted by score: kept in AtlasLoot's own boss/item order.
			onComplete("ok", list, zoneName, pendingIds)
		end
	end)
end

--------------------------------------------------------------------------------
-- Out-of-instance dungeon/raid ranking: which zones have the most upgrades
-- for you right now, so you know where's actually worth going. Checked
-- directly against AtlasLoot's own Core/Difficultys.lua: Normal/Heroic/base
-- Mythic map to a fixed param of 3/4/5 across every dungeon and raid Type
-- (not just the ones already confirmed for single-zone scanning), so this
-- doesn't need any live GetInstanceInfo() context the way the current-zone
-- scan does - it can resolve every zone's tiers directly.
--------------------------------------------------------------------------------

-- Classic-only, per request - BC/Wrath dungeons and raids are skipped entirely.
local DUNGEON_ZONE_TYPES = {
	ClassicDungeon = true, ClassicDungeonExt = true,
}
local RAID_ZONE_TYPES = {
	ClassicRaid = true,
}
local TIER_PARAM = { normal = 3, heroic = 4, mythic = 5 }
local TIER_SECTION_MATCH = { normal = "Normal", heroic = "Heroic", mythic = "Heroic" }

-- These share AtlasLoot's "ClassicDungeonExt" Type but aren't real queueable
-- dungeons - "Shared Dungeon Loot" and the Tier 0/0.5 dungeon set pages are
-- reference lists, not places you actually go. Excluded entirely.
local EXCLUDED_ZONE_KEYS = {
	SharedDungeonLoot = true, T0 = true, ["T0.5"] = true,
}
-- Which real raids are actually live on this custom server is unclear, so
-- raids are skipped entirely for now except World Bosses (open-world, not
-- tied to a specific raid instance's availability).
local RAID_ZONE_KEY_WHITELIST = {
	WorldBossesCLASSIC = true,
}
-- Also Type=ClassicDungeonExt, but it's a vendor purchase list, not a
-- dungeon - recategorized into its own "vendor" bucket instead.
local ZONE_CATEGORY_OVERRIDE = {
	MarkOfTriumph = "vendor",
}

local RANKING_BATCH_SIZE = 20

-- options: { normal = bool, heroic = bool, mythic = bool }
-- onProgress(processedCount, totalCount) - called periodically during the scan.
-- onComplete(results) - results: array of
--   { zoneKey, zoneName, category = "dungeon"/"raid", normal=N, heroic=N, mythic=N, total=N,
--     items = { { itemLink, score, diff, tier, bossName }, ... } }
--   sorted descending by total upgrade count across the tiers that were scanned.
function GW.BuildDungeonRankingList(options, onProgress, onComplete)
	EnsureAtlasLootModulesLoaded()

	if not AtlasLoot_Data then
		onComplete({})
		return
	end

	local tiers = {}
	if options.normal then table.insert(tiers, "normal") end
	if options.heroic then table.insert(tiers, "heroic") end
	if options.mythic then table.insert(tiers, "mythic") end

	local zones = {}
	local resultByKey = {}
	for key, data in pairs(AtlasLoot_Data) do
		local category = DUNGEON_ZONE_TYPES[data.Type] and "dungeon" or (RAID_ZONE_TYPES[data.Type] and "raid" or nil)
		category = ZONE_CATEGORY_OVERRIDE[key] or category
		if category == "raid" and not RAID_ZONE_KEY_WHITELIST[key] then category = nil end
		if category and data.Name and not EXCLUDED_ZONE_KEYS[key] then
			table.insert(zones, { key = key, data = data, category = category })
			resultByKey[key] = { zoneKey = key, zoneName = data.Name, category = category, normal = 0, heroic = 0, mythic = 0, total = 0, items = {} }
		end
	end

	-- Flatten every (zone, tier, boss, item) combination into one work queue
	-- upfront, same batching approach as the single-zone scan, just at a much
	-- larger scale - each individual unit of work is exactly as cheap either way.
	local workQueue = {}
	for _, zone in ipairs(zones) do
		for _, tier in ipairs(tiers) do
			local sectionMatchText = TIER_SECTION_MATCH[tier]
			for bossIndex, boss in ipairs(zone.data) do
				if boss.Name then
					local entries = GetBossItemEntries(boss, sectionMatchText)
					for _, entry in ipairs(entries) do
						table.insert(workQueue, { zoneKey = zone.key, tier = tier, stockItemId = entry.itemID, bossName = boss.Name })
					end
				end
			end
		end
	end

	local total = #workQueue
	local i = 1
	-- Not every loot table actually has distinct items per difficulty - trash
	-- mob drops in particular are sometimes the exact same item at Normal,
	-- Heroic, and Mythic on this server, unlike boss loot which does scale.
	-- GetItemDifficultyID() can't distinguish "no such tier exists" from
	-- "happens to be the same item" (it falls back to returning the input ID
	-- unchanged either way), so instead: since tiers are always enqueued
	-- low-to-high (normal, then heroic, then mythic - see `tiers` above), once
	-- a boss's item resolves to some link, remember it per boss and skip any
	-- later tier that resolves to that exact same link. That's not a genuine
	-- separate upgrade opportunity, just the same item shown again.
	local seenItemsByZone = {}
	local worker = CreateFrame("Frame")
	worker:SetScript("OnUpdate", function(self)
		local processed = 0
		while i <= total and processed < RANKING_BATCH_SIZE do
			local work = workQueue[i]
			local itemLink = ResolveItemLink(work.stockItemId, TIER_PARAM[work.tier])
			if itemLink then
				local zoneSeen = seenItemsByZone[work.zoneKey]
				if not zoneSeen then
					zoneSeen = {}
					seenItemsByZone[work.zoneKey] = zoneSeen
				end
				local seenKey = work.bossName .. "|" .. itemLink
				if zoneSeen[seenKey] then
					itemLink = nil
				else
					zoneSeen[seenKey] = true
				end
			end
			if itemLink then
				local score, diff, usable = GW.GetBestUpgradeDiff(itemLink)
				if usable ~= false and diff and diff > 0.05 then
					local result = resultByKey[work.zoneKey]
					result[work.tier] = result[work.tier] + 1
					result.total = result.total + 1
					table.insert(result.items, { itemLink = itemLink, score = score, diff = diff, tier = work.tier, bossName = work.bossName })
				end
			end
			i = i + 1
			processed = processed + 1
		end

		if onProgress then onProgress(i - 1, total) end

		if i > total then
			self:SetScript("OnUpdate", nil)
			local results = {}
			for _, result in pairs(resultByKey) do
				if result.total > 0 then table.insert(results, result) end
			end
			table.sort(results, function(a, b) return a.total > b.total end)
			onComplete(results)
		end
	end)
end

--------------------------------------------------------------------------------
-- AtlasLoot WishList integration (Alt+click to add).
-- This is the least-verified part of this addon: AddItemToWishList expects
-- AtlasLoot's own internal button-data shape, and this reconstructs the
-- minimal version of it based on reading LootButtons.lua/WishList.lua, not
-- from actually exercising it in-game. Wrapped in pcall so a wrong assumption
-- fails safely into a chat message instead of breaking anything.
--------------------------------------------------------------------------------

function GW.AddToAtlasLootWishlist(entry)
	local atlasLoot = GetAtlasLootAddon()
	if not atlasLoot or not atlasLoot.AddItemToWishList then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: AtlasLoot isn't loaded, can't add to WishList.")
		return
	end
	if not entry.zoneKey or not entry.bossIndex or not entry.stockItemId then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: this item is missing the data needed to add it to AtlasLoot's WishList.")
		return
	end

	local itemName = GetItemInfo(entry.itemLink)
	local data = {
		name = itemName,
		item = { itemID = entry.stockItemId },
		dataID = entry.zoneKey,
		dataSource = "AtlasLoot_Data",
		tablenum = entry.bossIndex,
	}

	local wList = AtlasLootWishList and AtlasLootWishList.Options and AtlasLootWishList.Options[UnitName("player")]
		and AtlasLootWishList.Options[UnitName("player")].DefaultWishList
	if not wList then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: couldn't find your default AtlasLoot WishList.")
		return
	end

	local ok, err = pcall(atlasLoot.AddItemToWishList, atlasLoot, wList[1], wList[3], data)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage("GearWeights: adding to WishList failed (" .. tostring(err) .. "). This integration is unverified - please report this.")
	end
end

--------------------------------------------------------------------------------
-- Auto popup on zone-in, showing just the upgrades. Toggleable.
--------------------------------------------------------------------------------

local function EnsureLootSettings()
	GearWeightsDB = GearWeightsDB or {}
	if GearWeightsDB.settings == nil then GearWeightsDB.settings = {} end
	if GearWeightsDB.settings.autoShowInstanceUpgrades == nil then
		GearWeightsDB.settings.autoShowInstanceUpgrades = true
	end
	if GearWeightsDB.settings.targetLootEnabled == nil then
		GearWeightsDB.settings.targetLootEnabled = true
	end
	if GearWeightsDB.settings.glowInstanceLoot == nil then
		GearWeightsDB.settings.glowInstanceLoot = true
	end
	if GearWeightsDB.settings.glowWorldDrops == nil then
		GearWeightsDB.settings.glowWorldDrops = true
	end
	if GearWeightsDB.settings.glowQuestRewards == nil then
		GearWeightsDB.settings.glowQuestRewards = true
	end
	if GearWeightsDB.settings.glowQuestVendorValue == nil then
		GearWeightsDB.settings.glowQuestVendorValue = true
	end
	if GearWeightsDB.settings.dungeonRankNormal == nil then
		GearWeightsDB.settings.dungeonRankNormal = true
	end
	if GearWeightsDB.settings.dungeonRankHeroic == nil then
		GearWeightsDB.settings.dungeonRankHeroic = true
	end
	if GearWeightsDB.settings.dungeonRankMythic == nil then
		GearWeightsDB.settings.dungeonRankMythic = true
	end
end

function GW.IsDungeonRankTierEnabled(tier)
	EnsureLootSettings()
	if tier == "normal" then return GearWeightsDB.settings.dungeonRankNormal end
	if tier == "heroic" then return GearWeightsDB.settings.dungeonRankHeroic end
	if tier == "mythic" then return GearWeightsDB.settings.dungeonRankMythic end
	return false
end

function GW.SetDungeonRankTierEnabled(tier, enabled)
	EnsureLootSettings()
	if tier == "normal" then GearWeightsDB.settings.dungeonRankNormal = enabled
	elseif tier == "heroic" then GearWeightsDB.settings.dungeonRankHeroic = enabled
	elseif tier == "mythic" then GearWeightsDB.settings.dungeonRankMythic = enabled
	end
end

-- Cached across sessions so opening this view doesn't always mean a fresh
-- 15-25 second scan - only rescan when explicitly triggered (login, gear/spec
-- change, or the Rescan button), and remember whose gear the cache reflects.
function GW.GetCachedDungeonRanking()
	GearWeightsDB = GearWeightsDB or {}
	return GearWeightsDB.dungeonRanking
end

function GW.SetCachedDungeonRanking(results, specId)
	GearWeightsDB = GearWeightsDB or {}
	GearWeightsDB.dungeonRanking = { results = results, specId = specId, timestamp = time() }
end

function GW.IsAutoPopupEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.autoShowInstanceUpgrades
end

function GW.SetAutoPopupEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.autoShowInstanceUpgrades = enabled
end

function GW.IsTargetLootEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.targetLootEnabled
end

function GW.IsInstanceGlowEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.glowInstanceLoot
end

function GW.SetInstanceGlowEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.glowInstanceLoot = enabled
end

function GW.IsWorldDropGlowEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.glowWorldDrops
end

function GW.SetWorldDropGlowEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.glowWorldDrops = enabled
end

function GW.IsQuestRewardGlowEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.glowQuestRewards
end

function GW.SetQuestRewardGlowEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.glowQuestRewards = enabled
end

function GW.IsQuestVendorGlowEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.glowQuestVendorValue
end

function GW.SetQuestVendorGlowEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.glowQuestVendorValue = enabled
end

function GW.SetTargetLootEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.targetLootEnabled = enabled
end

--------------------------------------------------------------------------------
-- Locked slots: "technically an upgrade by stat weight, but I've already
-- decided I don't want to chase upgrades here" (set bonus, BiS trinket
-- proc, whatever isn't captured by raw stat weights). A locked slot still
-- gets scored and shown, just never counted as an upgrade.
--------------------------------------------------------------------------------

function GW.IsSlotLocked(slotId)
	EnsureLootSettings()
	GearWeightsDB.settings.lockedSlots = GearWeightsDB.settings.lockedSlots or {}
	return GearWeightsDB.settings.lockedSlots[slotId] == true
end

function GW.SetSlotLocked(slotId, locked)
	EnsureLootSettings()
	GearWeightsDB.settings.lockedSlots = GearWeightsDB.settings.lockedSlots or {}
	if locked then
		GearWeightsDB.settings.lockedSlots[slotId] = true
	else
		GearWeightsDB.settings.lockedSlots[slotId] = nil
	end
end

--------------------------------------------------------------------------------
-- Weapon baseline (2H vs Main Hand/Off Hand) - which weapon setup counts as
-- "currently equipped" for scoring/comparison purposes. Dynamic by default
-- (always reads whatever's actually equipped right now, so it naturally
-- reflects your last real weapon change), but can be locked to freeze a
-- snapshot at the moment of locking - protects comparisons from being thrown
-- off by a temporary quest-required weapon swap.
--------------------------------------------------------------------------------

local function EnsureWeaponBaseline()
	GearWeightsDB = GearWeightsDB or {}
	GearWeightsDB.weaponBaseline = GearWeightsDB.weaponBaseline or { locked = false }
end

function GW.IsWeaponBaselineLocked()
	EnsureWeaponBaseline()
	return GearWeightsDB.weaponBaseline.locked or false
end

-- Returns mainHandLink, offHandLink - the links to treat as "currently
-- equipped" for weapon-slot scoring: live equipped gear when unlocked, or the
-- frozen snapshot captured at the moment of locking when locked.
function GW.GetWeaponBaselineLinks()
	EnsureWeaponBaseline()
	local baseline = GearWeightsDB.weaponBaseline
	if baseline.locked then
		return baseline.mainHand, baseline.offHand
	end
	return GetInventoryItemLink("player", INVSLOT_MAINHAND), GetInventoryItemLink("player", INVSLOT_OFFHAND)
end

function GW.SetWeaponBaselineLocked(locked)
	EnsureWeaponBaseline()
	local baseline = GearWeightsDB.weaponBaseline
	if locked then
		baseline.mainHand = GetInventoryItemLink("player", INVSLOT_MAINHAND)
		baseline.offHand = GetInventoryItemLink("player", INVSLOT_OFFHAND)
	end
	baseline.locked = locked and true or false
end

-- Returns the link to treat as "equipped" in this slot for scoring/comparison
-- purposes - the tracked weapon baseline above for Main Hand/Off Hand, live
-- equipped gear for every other slot (which has no such baseline concept).
function GW.GetEquippedLinkForScoring(slotId)
	if slotId == INVSLOT_MAINHAND or slotId == INVSLOT_OFFHAND then
		local mh, oh = GW.GetWeaponBaselineLinks()
		return slotId == INVSLOT_MAINHAND and mh or oh
	end
	return GetInventoryItemLink("player", slotId)
end

-- Below max level, a heirloom is deliberately kept for its scaling stats and
-- XP bonus - a slot that happens to score higher on raw stat weights isn't
-- actually worth swapping to for that reason alone, so treat it the same as
-- a manually locked slot automatically, without needing to toggle anything.
local HEIRLOOM_ITEM_QUALITY = 7
local MAX_LEVEL = 60

function GW.IsHeirloomAutoIgnored(slotId)
	if UnitLevel("player") >= MAX_LEVEL then return false end
	local link = GetInventoryItemLink("player", slotId)
	if not link then return false end
	local _, _, quality = GetItemInfo(link)
	return quality == HEIRLOOM_ITEM_QUALITY
end

-- Returns a human-readable reason the slot is being skipped, or nil if it
-- isn't. Checked instead of GW.IsSlotLocked() everywhere a slot needs to be
-- excluded from upgrade counting, so both reasons share one code path.
function GW.GetSlotIgnoreReason(slotId)
	if GW.IsSlotLocked(slotId) then
		return "Equip slot locked"
	end
	if GW.IsHeirloomAutoIgnored(slotId) then
		return "Heirloom equipped - ignored below level " .. MAX_LEVEL
	end
	return nil
end

local lastZoneChecked
local MAX_SCAN_RETRIES = 8
local RETRY_INTERVAL = 3

local function TryAutoScan(retriesLeft)
	GW.BuildInstanceLootList(function(status, list)
		if status == "noData" and retriesLeft > 0 then
			-- AtlasLoot_Data may still be populating (its expansion modules can
			-- take a while after login/zoning), so retry instead of giving up.
			local retryFrame = CreateFrame("Frame")
			local elapsed = 0
			retryFrame:SetScript("OnUpdate", function(self, delta)
				elapsed = elapsed + delta
				if elapsed >= RETRY_INTERVAL then
					self:SetScript("OnUpdate", nil)
					TryAutoScan(retriesLeft - 1)
				end
			end)
			return
		end

		if status == "ok" then
			local hasUpgrade = false
			for _, entry in ipairs(list) do
				if entry.diff and entry.diff > 0.05 then
					hasUpgrade = true
					break
				end
			end
			if hasUpgrade and GW.OpenInstanceLootTab then
				GW.OpenInstanceLootTab()
			end
		end
	end)
end

local zoneEventFrame = CreateFrame("Frame")
zoneEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneEventFrame:SetScript("OnEvent", function()
	-- Load these as soon as the character enters the world, not just the first
	-- time the loot list is actually needed - avoids any gap between zoning
	-- into an instance and the data actually being ready.
	EnsureAtlasLootModulesLoaded()

	EnsureLootSettings()
	if not GearWeightsDB.settings.autoShowInstanceUpgrades then return end

	local zoneName, instanceType = GetInstanceInfo()
	if instanceType ~= "party" and instanceType ~= "raid" then
		lastZoneChecked = nil
		return
	end
	if zoneName == lastZoneChecked then return end
	lastZoneChecked = zoneName

	-- Give the client a moment to settle after zoning before the first scan.
	local delayFrame = CreateFrame("Frame")
	local elapsed = 0
	delayFrame:SetScript("OnUpdate", function(self, delta)
		elapsed = elapsed + delta
		if elapsed >= 2 then
			self:SetScript("OnUpdate", nil)
			TryAutoScan(MAX_SCAN_RETRIES)
		end
	end)
end)

--------------------------------------------------------------------------------
-- Dungeon ranking scan: run once automatically per session (delayed well
-- after login so it doesn't compete with everything else world-entry is
-- already doing), then only re-run on a debounced timer after gear changes -
-- never continuously, and never blocking, since a full scan can take real
-- wall-clock time (thousands of items across every dungeon and raid).
--------------------------------------------------------------------------------

local dungeonRankScanState = { inProgress = false, processed = 0, total = 0 }

function GW.GetDungeonRankScanState()
	return dungeonRankScanState
end

-- Returns false if a scan is already running (caller should just poll
-- GetDungeonRankScanState() / GetCachedDungeonRanking() instead of starting
-- a second overlapping one).
function GW.RunDungeonRankingScan(onComplete)
	if dungeonRankScanState.inProgress then return false end
	dungeonRankScanState.inProgress = true
	dungeonRankScanState.processed = 0
	dungeonRankScanState.total = 0

	local options = {
		normal = GW.IsDungeonRankTierEnabled("normal"),
		heroic = GW.IsDungeonRankTierEnabled("heroic"),
		mythic = GW.IsDungeonRankTierEnabled("mythic"),
	}
	GW.BuildDungeonRankingList(options, function(processed, total)
		dungeonRankScanState.processed = processed
		dungeonRankScanState.total = total
	end, function(results)
		dungeonRankScanState.inProgress = false
		GW.SetCachedDungeonRanking(results, GW.GetCurrentSpecId and GW.GetCurrentSpecId())
		if onComplete then onComplete(results) end
	end)
	return true
end

local DUNGEON_RANK_AUTO_SCAN_DELAY = 25
local DUNGEON_RANK_DEBOUNCE_DELAY = 5

local dungeonRankDebounceElapsed = 0
local dungeonRankDebounceFrame = CreateFrame("Frame")
dungeonRankDebounceFrame:Hide()
dungeonRankDebounceFrame:SetScript("OnUpdate", function(self, elapsed)
	dungeonRankDebounceElapsed = dungeonRankDebounceElapsed + elapsed
	if dungeonRankDebounceElapsed >= DUNGEON_RANK_DEBOUNCE_DELAY then
		self:Hide()
		GW.RunDungeonRankingScan()
	end
end)

local function ScheduleDungeonRankRescan()
	dungeonRankDebounceElapsed = 0
	dungeonRankDebounceFrame:Show()
end

local sessionDungeonScanTriggered = false
local dungeonRankTriggerFrame = CreateFrame("Frame")
dungeonRankTriggerFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
dungeonRankTriggerFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
dungeonRankTriggerFrame:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_ENTERING_WORLD" then
		if sessionDungeonScanTriggered then return end
		sessionDungeonScanTriggered = true
		local delayFrame = CreateFrame("Frame")
		local elapsed = 0
		delayFrame:SetScript("OnUpdate", function(self2, delta)
			elapsed = elapsed + delta
			if elapsed >= DUNGEON_RANK_AUTO_SCAN_DELAY then
				self2:SetScript("OnUpdate", nil)
				GW.RunDungeonRankingScan()
			end
		end)
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		ScheduleDungeonRankRescan()
	end
end)

-- Called from the Stat Weights tab whenever a weight value or profile import
-- changes, so a rescan reflects the update instead of only reacting to gear.
function GW.NotifyWeightsChanged()
	ScheduleDungeonRankRescan()
end

--------------------------------------------------------------------------------
-- Vendor prices - AtlasLoot's bundled data has no price info at all (its
-- vendor entries are bare {itemID=N}), so the only way to know what
-- something costs is to actually see it on a real merchant window. Captured
-- once per item and cached in SavedVariables (persists across sessions,
-- silently refreshed every time you revisit that vendor - a merchant window
-- only ever has a handful of items, so this is negligible cost even on
-- every visit). Items never actually seen for sale just show as unknown.
--------------------------------------------------------------------------------

local function EnsureVendorPriceCache()
	GearWeightsDB = GearWeightsDB or {}
	GearWeightsDB.vendorPrices = GearWeightsDB.vendorPrices or {}
end

-- Returns { copper = N, costs = { { amount, link, currencyName }, ... } } or
-- nil if this item has never been seen for sale on a visited merchant.
function GW.GetVendorPriceInfo(itemLink)
	if not itemLink then return nil end
	EnsureVendorPriceCache()
	local itemId = tonumber(itemLink:match("item:(%d+)"))
	if not itemId then return nil end
	return GearWeightsDB.vendorPrices[itemId]
end

-- Manually verified prices for the Mark of Triumph Vendor - confirmed on this
-- server via /gw vendordiag (extendedCost is flagged true for every item
-- here, but neither the structured cost API nor the tooltip exposes the
-- actual amount - see GW.FormatVendorPrice). Keyed by item name rather than
-- item ID: AtlasLoot's bundled MarkOfTriumph data doesn't match what's
-- actually live on this server for 6 of these 36 items, so name is the only
-- reliable match key without risking a wrong ID.
local KNOWN_VENDOR_PRICES = {
	["Centurion's Barbute"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Searing Sun Greathelm"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Microscopic Focusing Lens"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Birdbrain's Cage"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Assassin's Cover"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Spiritual Tauren Headdress"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Rubicon Crown"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Shroud of the Cathedral"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Golden Greathelm"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Wraith Choker"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lichbone Neck"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Memento of Quel'thalas"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Molten Forged Necklace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dragonfang Talisman"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ring of the Damned"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Band of the Titans"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Azerothian Diamond Ring"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ironguard Signet"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Spellbound Demonic Rune"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Rose of Remembrance"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Drakefury Scale"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Signet of Vitality"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Aegis of Defense"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Aegis of Impunity"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Aegis of Sanctity"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Soothing Aquamarine Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Scarlet Friar's Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Cape of Eternal Shrouding"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ursinefur Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dungeonlord's Drape"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bloodied Bone Dagger"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Draenei Focusing Crystal"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Holdable Ruby"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Blessed Windstone"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Hoodoo Detector"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Lunar Splinter"] = { amount = 70, currencyName = "Mark of Triumph" },
}

-- Returns an array of cost "parts" for the UI to render with real icons and
-- hover tooltips, plus a status string ("unknown"/"special"/"free") when
-- there's nothing to show. Each part is one of:
--   { kind = "copper", amount = N }
--   { kind = "markOfTriumph", amount = N } - render with GW.GetMarkOfTriumphInfo()'s
--     icon and GW.ShowMarkOfTriumphTooltip(), same as the bottom-bar tracker
--   { kind = "item", amount = N, itemLink = link } - a real item-based cost
--   { kind = "item", amount = N, name = "..." } - a named cost with no icon available
function GW.GetVendorPriceParts(itemLink)
	local info = GW.GetVendorPriceInfo(itemLink)

	local parts = {}
	if info then
		if info.copper and info.copper > 0 then
			table.insert(parts, { kind = "copper", amount = info.copper })
		end
		if info.costs then
			for _, cost in ipairs(info.costs) do
				if cost.currencyName == "Mark of Triumph" then
					table.insert(parts, { kind = "markOfTriumph", amount = cost.amount })
				elseif cost.link then
					table.insert(parts, { kind = "item", amount = cost.amount, itemLink = cost.link })
				else
					table.insert(parts, { kind = "item", amount = cost.amount, name = cost.currencyName or "?" })
				end
			end
		end
	end
	if #parts > 0 then return parts end

	local itemName = GetItemInfo(itemLink)
	local known = itemName and KNOWN_VENDOR_PRICES[itemName]
	if known then
		if known.currencyName == "Mark of Triumph" then
			return { { kind = "markOfTriumph", amount = known.amount } }
		end
		return { { kind = "item", amount = known.amount, name = known.currencyName } }
	end

	if not info then return nil, "unknown" end

	-- Some custom-currency vendors (confirmed on this server) flag
	-- extendedCost true but expose zero cost details through either the
	-- structured API or the tooltip text - there's no way for an addon to
	-- learn the real price here, so say so plainly instead of calling it Free.
	if info.extendedCost then return nil, "special" end
	return nil, "free"
end

local function ScanOpenMerchant()
	EnsureVendorPriceCache()
	local n = GetMerchantNumItems()
	for i = 1, n do
		local link = GetMerchantItemLink(i)
		local itemId = link and tonumber(link:match("item:(%d+)"))
		if itemId then
			local _, _, price, _, _, _, extendedCost = GetMerchantItemInfo(i)
			local costs
			if extendedCost then
				costs = {}
				local costKinds = GetMerchantItemCostInfo(i)
				for j = 1, (costKinds or 0) do
					local costTexture, costAmount, costLink, currencyName = GetMerchantItemCostItem(i, j)
					table.insert(costs, { amount = costAmount, link = costLink, currencyName = currencyName })
				end
			end
			GearWeightsDB.vendorPrices[itemId] = { copper = price, costs = costs, extendedCost = extendedCost and true or false }
		end
	end
end

local merchantWatchFrame = CreateFrame("Frame")
merchantWatchFrame:RegisterEvent("MERCHANT_SHOW")
merchantWatchFrame:SetScript("OnEvent", ScanOpenMerchant)
