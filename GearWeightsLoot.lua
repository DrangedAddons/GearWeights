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
				local score, diff, usable, flipsLoadout = GW.GetBestUpgradeDiff(itemLink)
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
						flipsLoadout = flipsLoadout,
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

-- options: { dungeon = { normal = bool, heroic = bool, mythic = bool },
--            raid = { normal = bool, heroic = bool, mythic = bool } }
-- Dungeon and raid tiers are filtered independently - raids are typically a
-- tier below the equivalent dungeon difficulty in practice, so someone who's
-- moved past Heroic/Mythic dungeons into Normal raids wants both filters set
-- differently rather than one Normal/Heroic/Mythic toggle applying to both.
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

	local dungeonTiers = {}
	if options.dungeon.normal then table.insert(dungeonTiers, "normal") end
	if options.dungeon.heroic then table.insert(dungeonTiers, "heroic") end
	if options.dungeon.mythic then table.insert(dungeonTiers, "mythic") end

	local raidTiers = {}
	if options.raid.normal then table.insert(raidTiers, "normal") end
	if options.raid.heroic then table.insert(raidTiers, "heroic") end
	if options.raid.mythic then table.insert(raidTiers, "mythic") end

	-- Anything that's neither dungeon nor raid (currently just the vendor
	-- bucket, ZONE_CATEGORY_OVERRIDE) isn't gated by either filter at all -
	-- always scan every tier for it, since vendor stock isn't tied to
	-- dungeon/raid difficulty preferences.
	local ALL_TIERS = { "normal", "heroic", "mythic" }
	local function TiersForCategory(category)
		if category == "dungeon" then return dungeonTiers end
		if category == "raid" then return raidTiers end
		return ALL_TIERS
	end

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
		for _, tier in ipairs(TiersForCategory(zone.category)) do
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
				local score, diff, usable, flipsLoadout = GW.GetBestUpgradeDiff(itemLink)
				if usable ~= false and diff and diff > 0.05 then
					local result = resultByKey[work.zoneKey]
					result[work.tier] = result[work.tier] + 1
					result.total = result.total + 1
					table.insert(result.items, { itemLink = itemLink, score = score, diff = diff, tier = work.tier, bossName = work.bossName, flipsLoadout = flipsLoadout })
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
		GearWeightsDB.settings.glowInstanceLoot = false
	end
	if GearWeightsDB.settings.glowWorldDrops == nil then
		GearWeightsDB.settings.glowWorldDrops = false
	end
	if GearWeightsDB.settings.glowQuestRewards == nil then
		GearWeightsDB.settings.glowQuestRewards = false
	end
	if GearWeightsDB.settings.glowQuestVendorValue == nil then
		GearWeightsDB.settings.glowQuestVendorValue = false
	end
	if GearWeightsDB.settings.glowVendorItems == nil then
		GearWeightsDB.settings.glowVendorItems = false
	end
	-- One-time forced-off migration: all five of these defaulted to true
	-- before and may already be true in existing SavedVariables. The glow
	-- effects aren't working as intended yet, so turn them all off now
	-- (the Settings checkboxes for them are removed too - see
	-- GearWeightsUI.lua) rather than leaving them silently active with no
	-- way to toggle them off. The underlying glow code is untouched and
	-- still there to pick back up later - only the settings values and the
	-- UI to change them are disabled. Gated so this only forces the value
	-- once; it won't fight a future re-enable once the toggles come back.
	if not GearWeightsDB.settings.allGlowDisabledMigration then
		GearWeightsDB.settings.glowInstanceLoot = false
		GearWeightsDB.settings.glowWorldDrops = false
		GearWeightsDB.settings.glowQuestRewards = false
		GearWeightsDB.settings.glowQuestVendorValue = false
		GearWeightsDB.settings.glowVendorItems = false
		GearWeightsDB.settings.allGlowDisabledMigration = true
	end
	if GearWeightsDB.settings.viewBySlot == nil then
		GearWeightsDB.settings.viewBySlot = false
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
	-- Raids are typically a tier below the equivalent dungeon difficulty in
	-- practice (e.g. you outgear Heroic/Mythic dungeons before Normal raids),
	-- so dungeon and raid tiers are tracked independently rather than one
	-- shared Normal/Heroic/Mythic filter applying to both categories.
	if GearWeightsDB.settings.raidRankNormal == nil then
		GearWeightsDB.settings.raidRankNormal = true
	end
	if GearWeightsDB.settings.raidRankHeroic == nil then
		GearWeightsDB.settings.raidRankHeroic = true
	end
	if GearWeightsDB.settings.raidRankMythic == nil then
		GearWeightsDB.settings.raidRankMythic = true
	end
end

function GW.IsDungeonRankTierEnabled(tier)
	EnsureLootSettings()
	if tier == "normal" then return GearWeightsDB.settings.dungeonRankNormal end
	if tier == "heroic" then return GearWeightsDB.settings.dungeonRankHeroic end
	if tier == "mythic" then return GearWeightsDB.settings.dungeonRankMythic end
	return false
end

function GW.IsRaidRankTierEnabled(tier)
	EnsureLootSettings()
	if tier == "normal" then return GearWeightsDB.settings.raidRankNormal end
	if tier == "heroic" then return GearWeightsDB.settings.raidRankHeroic end
	if tier == "mythic" then return GearWeightsDB.settings.raidRankMythic end
	return false
end

function GW.SetDungeonRankTierEnabled(tier, enabled)
	EnsureLootSettings()
	if tier == "normal" then GearWeightsDB.settings.dungeonRankNormal = enabled
	elseif tier == "heroic" then GearWeightsDB.settings.dungeonRankHeroic = enabled
	elseif tier == "mythic" then GearWeightsDB.settings.dungeonRankMythic = enabled
	end
end

function GW.SetRaidRankTierEnabled(tier, enabled)
	EnsureLootSettings()
	if tier == "normal" then GearWeightsDB.settings.raidRankNormal = enabled
	elseif tier == "heroic" then GearWeightsDB.settings.raidRankHeroic = enabled
	elseif tier == "mythic" then GearWeightsDB.settings.raidRankMythic = enabled
	end
end

function GW.IsViewBySlotEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.viewBySlot
end

function GW.SetViewBySlotEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.viewBySlot = enabled
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

function GW.IsVendorGlowEnabled()
	EnsureLootSettings()
	return GearWeightsDB.settings.glowVendorItems
end

function GW.SetVendorGlowEnabled(enabled)
	EnsureLootSettings()
	GearWeightsDB.settings.glowVendorItems = enabled
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
-- Weapon baseline - three independent "paperdoll" reference boxes (Two-Hand,
-- Main Hand, Off Hand) used as the comparison target when scoring weapons.
-- Each remembers the last relevant item seen in its own category rather than
-- only reflecting whatever's on your character at this instant:
--   - Two-Hand remembers the last 2H weapon you had equipped
--   - Main Hand remembers the last 1H (non-2H) mainhand weapon
--   - Off Hand remembers the last off-hand item (only updates while a 2H
--     isn't equipped, since the slot is physically blocked otherwise)
-- So swapping from a 2H to dual-wield updates Main Hand/Off Hand but leaves
-- Two-Hand showing your last 2H, and vice versa. Each box can be
-- independently locked (freezes it against further equip changes - protects
-- against a temporary quest-required weapon swap) or manually set by
-- dragging an item onto it in the UI.
--------------------------------------------------------------------------------

local WEAPON_BOX_KEYS = { twoHand = true, mainHand = true, offHand = true }

local function EnsureWeaponBaseline()
	GearWeightsDB = GearWeightsDB or {}
	GearWeightsDB.weaponBaseline = GearWeightsDB.weaponBaseline or {}
	for key in pairs(WEAPON_BOX_KEYS) do
		-- An earlier version (1.21.x) stored this as a flat { locked, mainHand
		-- = link, offHand = link } shape - mainHand/offHand were raw link
		-- strings, not sub-tables. `or {...}` alone wouldn't replace a
		-- leftover string (it's truthy), and assigning a field onto a string
		-- value errors, so explicitly check the type instead of just nil.
		if type(GearWeightsDB.weaponBaseline[key]) ~= "table" then
			GearWeightsDB.weaponBaseline[key] = { link = nil, locked = false }
		end
	end
end

function GW.GetWeaponBoxLink(box)
	EnsureWeaponBaseline()
	return GearWeightsDB.weaponBaseline[box].link
end

function GW.IsWeaponBoxLocked(box)
	EnsureWeaponBaseline()
	return GearWeightsDB.weaponBaseline[box].locked
end

function GW.SetWeaponBoxLocked(box, locked)
	EnsureWeaponBaseline()
	GearWeightsDB.weaponBaseline[box].locked = locked and true or false
end

-- Manually assigns a box's reference item (e.g. dragged onto it in the UI),
-- regardless of that box's current lock state - an explicit action always
-- takes effect immediately.
function GW.SetWeaponBoxLink(box, link)
	EnsureWeaponBaseline()
	GearWeightsDB.weaponBaseline[box].link = link
end

-- Called on equip changes: updates every unlocked box according to what's
-- actually relevant to it right now, leaving locked boxes - and boxes whose
-- category isn't currently active (e.g. Main Hand/Off Hand while a 2H is
-- equipped) - untouched instead of clearing them.
function GW.SyncWeaponBoxesFromEquipped()
	EnsureWeaponBaseline()
	local baseline = GearWeightsDB.weaponBaseline
	local mhLink = GetInventoryItemLink("player", INVSLOT_MAINHAND)
	local ohLink = GetInventoryItemLink("player", INVSLOT_OFFHAND)
	local mhIs2H = false
	if mhLink then
		local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
		mhIs2H = mhEquipLoc == "INVTYPE_2HWEAPON"
	end

	if mhIs2H then
		if not baseline.twoHand.locked then baseline.twoHand.link = mhLink end
	else
		if not baseline.mainHand.locked then baseline.mainHand.link = mhLink end
		if not baseline.offHand.locked then baseline.offHand.link = ohLink end
	end
end

-- Returns the link to treat as "equipped" in this slot for scoring/comparison
-- purposes - the tracked Main Hand/Off Hand box for those slots (never the
-- Two-Hand box; 2H candidates compare against GW.GetTwoHandComparisonScore()
-- instead, which considers both remembered loadouts), live equipped gear for
-- every other slot (which has no such baseline concept).
function GW.GetEquippedLinkForScoring(slotId)
	if slotId == INVSLOT_MAINHAND then
		return GW.GetWeaponBoxLink("mainHand")
	elseif slotId == INVSLOT_OFFHAND then
		return GW.GetWeaponBoxLink("offHand")
	end
	return GetInventoryItemLink("player", slotId)
end

-- What a 2H candidate should be compared against: whichever of your two
-- remembered weapon loadouts (a 2H, or a Main Hand + Off Hand combo) scores
-- higher - it only counts as a real upgrade if it beats your best current
-- alternative, not just one of them arbitrarily.
function GW.GetTwoHandComparisonScore()
	local twoHandLink = GW.GetWeaponBoxLink("twoHand")
	local mhLink = GW.GetWeaponBoxLink("mainHand")
	local ohLink = GW.GetWeaponBoxLink("offHand")
	local twoHandScore = twoHandLink and GW.GetItemScore(twoHandLink) or 0
	local comboScore = (mhLink and GW.GetItemScore(mhLink) or 0) + (ohLink and GW.GetItemScore(ohLink) or 0)
	return math.max(twoHandScore, comboScore)
end

-- A weapon candidate can be a real upgrade over its own reference box
-- (Two-Hand, Main Hand, or Off Hand individually) without that being the
-- whole story - a modest Main Hand upgrade can be exactly what tips your
-- WHOLE loadout from "2H is better" to "dual-wield is better," which is easy
-- to miss looking at just that one slot's own diff. replacingBox is which
-- box this candidate would go into ("twoHand"/"mainHand"/"offHand").
-- Returns: flips (bool - whether the better loadout changes), newBetter and
-- oldBetter ("twoHand" or "combo").
function GW.CheckWeaponLoadoutFlip(replacingBox, candidateScore)
	local twoHandLink = GW.GetWeaponBoxLink("twoHand")
	local mhLink = GW.GetWeaponBoxLink("mainHand")
	local ohLink = GW.GetWeaponBoxLink("offHand")
	local twoHandScore = twoHandLink and GW.GetItemScore(twoHandLink) or 0
	local mhScore = mhLink and GW.GetItemScore(mhLink) or 0
	local ohScore = ohLink and GW.GetItemScore(ohLink) or 0
	local comboScore = mhScore + ohScore

	local newTwoHandScore, newComboScore = twoHandScore, comboScore
	if replacingBox == "twoHand" then
		newTwoHandScore = candidateScore
	elseif replacingBox == "mainHand" then
		newComboScore = candidateScore + ohScore
	elseif replacingBox == "offHand" then
		newComboScore = mhScore + candidateScore
	else
		return false
	end

	local oldBetter = twoHandScore >= comboScore and "twoHand" or "combo"
	local newBetter = newTwoHandScore >= newComboScore and "twoHand" or "combo"
	return oldBetter ~= newBetter, newBetter, oldBetter
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

-- Armor-type filter (Settings tab): whether Cloth/Leather/Mail/Plate
-- upgrades are excluded from counting, independent of any one slot. All
-- four default to included (not excluded) - nothing in the saved table
-- means "included", matching GW.IsSlotLocked's own default.
function GW.IsArmorTypeExcluded(armorType)
	EnsureLootSettings()
	GearWeightsDB.settings.excludedArmorTypes = GearWeightsDB.settings.excludedArmorTypes or {}
	return GearWeightsDB.settings.excludedArmorTypes[armorType] == true
end

function GW.SetArmorTypeExcluded(armorType, excluded)
	EnsureLootSettings()
	GearWeightsDB.settings.excludedArmorTypes = GearWeightsDB.settings.excludedArmorTypes or {}
	if excluded then
		GearWeightsDB.settings.excludedArmorTypes[armorType] = true
	else
		GearWeightsDB.settings.excludedArmorTypes[armorType] = nil
	end
end

-- Whether a candidate item's own armor material type has been excluded from
-- upgrade counting - a property of the item itself, not any one slot, so
-- this is a separate check from GW.GetSlotIgnoreReason rather than folded
-- into it.
function GW.GetArmorTypeIgnoreReason(itemLink)
	if not itemLink then return nil end
	local _, _, _, _, _, _, itemSubType = GetItemInfo(itemLink)
	if itemSubType and GW.ARMOR_TYPE_SET[itemSubType] and GW.IsArmorTypeExcluded(itemSubType) then
		return "Excluded armor type"
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
		dungeon = {
			normal = GW.IsDungeonRankTierEnabled("normal"),
			heroic = GW.IsDungeonRankTierEnabled("heroic"),
			mythic = GW.IsDungeonRankTierEnabled("mythic"),
		},
		raid = {
			normal = GW.IsRaidRankTierEnabled("normal"),
			heroic = GW.IsRaidRankTierEnabled("heroic"),
			mythic = GW.IsRaidRankTierEnabled("mythic"),
		},
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
		GW.SyncWeaponBoxesFromEquipped()
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
		GW.SyncWeaponBoxesFromEquipped()
		if GW.RefreshWeaponBaselineDisplay then GW.RefreshWeaponBaselineDisplay() end
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

-- Prices for the Mark of Triumph Vendor - extendedCost is flagged true for
-- every item here, but neither the structured cost API nor the tooltip
-- exposes the actual amount (see GW.FormatVendorPrice), so this is a manually
-- compiled reference table covering the vendor's full stock. Keyed by item
-- name rather than item ID: AtlasLoot's bundled MarkOfTriumph data doesn't
-- match what's actually live on this server for some of these items, so name
-- is the only reliable match key without risking a wrong ID.
local KNOWN_VENDOR_PRICES = {
	["Amplifying Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Amulet of the Redeemed"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Anastari Heirloom"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Animated Chain Necklace"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Archivist Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Aristocratic Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Armbands of Change"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Armswake Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ash Covered Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Backusarian Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ban'thok Sash"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Banshee Finger"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Barbed Thorn Necklace"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Barman Shanker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Barrage Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bashguuder"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Battleborn Armbraces"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Battlechaser's Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Beaststalker's Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Beaststalker's Bindings"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Beaststalker's Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Beaststalker's Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Beauty's Silken Ribbon"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of Bravery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of Courage"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of Currents"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of Valor"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of the Ordained"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Belt of the Trickster"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bindings of Elements"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Black Steel Bindings"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Blackcrow"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Blackmist Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Blackveil Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Blade of Necromancy"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bleak Howler Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Blisterbane Wrap"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodfist"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodmail Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodmail Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodmail Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodmail Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bloodmoon Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bone Slicing Hatchet"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bonechill Hammer"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boneclenched Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bonecreeper Stylus"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bonescraper"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of Currents"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of Elements"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of Ferocity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of Valor"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of the Full Moon"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Boots of the Shrieker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Bravery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Cooled Anger"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Courage"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Currents"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Prosperity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of Valor"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Bracers of the Eclipse"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Brazecore Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Brigam Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Brightspark Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Burned Gatherings"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Butcher's Apron"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cadaverous Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cadaverous Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cadaverous Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cadaverous Walkers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cape of the Black Baron"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cape of the Fire Salamander"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Carapace Spine Crossbow"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Carrier Wave Pendant"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Chillsteel Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Chiselbrand Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cho'Rush's Blade"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cinderhide Armsplints"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cloak of the Cosmos"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cloudrunner Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Clutch of Andros"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Clutches of Dying Light"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Coal Miner Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Coldstone Slippers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Cord of Elements"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Corla's Baton"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Corpselight Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Crystallized Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dal'Rend's Tribal Guardian"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dark Advisor's Pendant"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Darkshade Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Death Grips"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Death Knight Sabatons"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Deathbone Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Deathbone Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Deathbone Sabatons"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Deathbone Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Demon Howl Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Demonfork"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Demonskin Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Detention Strap"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Devout Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Devout Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Devout Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Devout Sandals"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Diana's Pearl Necklace"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Distracting Dagger"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Doomforged Straightedge"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dracorian Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dragonrider Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dreadmist Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dreadmist Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dreadmist Sandals"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dreadmist Wraps"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Dustfeather Sash"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ebon Hilt of Marduk"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Eidolon Talisman"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Elder Magus Pendant"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Elemental Plate Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Emberfury Talisman"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Emberplate Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Entrenching Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Evil Eye Pendant"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Eyestalk Cord"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Faith Healer's Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fallbrush Handgrips"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fang of the Crystal Spider"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fel Hardened Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Felstriker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Feralsurge Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fiendish Machete"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Finkle's Skinner"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fire Striders"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Firemoss Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fists of Phalanx"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Flame Walkers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Flameweave Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fleetfoot Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Fluctuating Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Force Imbued Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Foresight Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Frightalon"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Frostbite Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Frostweaver Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Funeral Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gallant's Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gargoyle Shredder Talons"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gargoyle Slashers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Accuracy"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Bravery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Courage"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Deftness"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Elements"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Tenacity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gauntlets of Valor"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gilded Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Girdle of Beastial Fury"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gloves of Currents"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gloves of Restoration"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gloves of Shadowy Mist"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gordok Bracers of Power"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Gracious Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Graverot Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Greaves of Tenacity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Greaves of Withering Despair"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Grimgore Noose"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Grimy Metal Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Grizzle's Skinner"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Halycon's Spiked Collar"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hammer of the Vesper"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Handcrafted Mastersmith Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Handguards of Savagery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hands of Power"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hands of the Exalted Herald"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Harmonious Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Heart of the Fiend"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hedgecutter"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Heliotrope Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["High Priestess Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hookfang Shanker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Houndmaster's Rifle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hurd Smasher"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hurley's Tankard"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Hyena Hide Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Iceblade Hacker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Imperial Jewel"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Incendic Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ironfoe"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ironweave Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ironweave Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ironweave Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ironweave Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Jagged Bone Fist"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Juno's Shadow"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Kayser's Boots of Precision"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Keris of Zul'Serak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lefty's Brass Knuckle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lethtendris's Wand"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightborne Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightborne Cord"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightborne Handguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightborne Wrists"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightforge Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightforge Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightforge Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lightforge Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Loomguard Armbraces"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Lord General's Sword"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magically Sealed Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magister's Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magister's Bindings"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magister's Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magister's Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Magistrate's Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Malefic Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Maleki's Footwraps"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Mana Channeling Wand"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Mana Shaping Handwraps"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Manacles of Pain"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Mar Alom's Grip"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Marksman Bands"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Marksman's Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Master Cannoneer Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Merciful Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Modest Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Molten Fists"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Morlune's Bracer"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Mud Stained Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Mugger's Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Necropile Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Necropile Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Necropile Cuffs"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Necropile Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Oblivion's Touch"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Oddly Magical Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Odious Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ogre Pocket Knife"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ogreseer Fists"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ogreseer Tower Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Omnicast Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Pads of the Dread Wolf"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Pale Moon Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Pendant of Celerity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Phantasmal Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Phase Blade"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Phasing Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Plaguebat Fur Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Pyremail Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Pyric Caduceus"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Quickdraw Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Quicksilver Amulet"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Rainbow Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Razor Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Redoubt Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Reiver Claws"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ribsteel Footguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Riptide Shoes"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Ritssyn's Wand of Bad Mojo"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Rivenspike"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Royal Tribunal Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Rubicund Armguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Rubidium Hammer"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Runed Golem Shackles"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Sash of the Burning Heart"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Sash of the Grand Hunt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Savage Gladiator Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Savage Gladiator Grips"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Scepter of the Unholy"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Searing Needle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Serpentine Skuller"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadefiend Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadewood Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadow Prowler's Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowcraft Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowcraft Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowcraft Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowcraft Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowy Laced Handwraps"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shadowy Mail Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shalehusk Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shivery Handwraps"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shroud of Arcane Mastery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Shroud of Domination"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Silent Fang"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Silkweb Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Skul's Fingerbone Claws"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Skul's Ghastly Touch"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Skullforge Reaver"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Slaghide Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Slashclaw Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Soot Encrusted Footwear"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Soul Breaker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Specter's Blade"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Spritecaster Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Star of Mystaria"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Steelbender's Masterpiece"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stompers of Bravery"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stonebark Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stoneshatter"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stoneshield Cloak"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stoneskin Gargoyle Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Stonewall Girdle"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Sublime Wristguards"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Swiftdart Battleboots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Swiftwalker Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Talisman of Evasion"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Tearfall Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Tempest Talisman"] = { amount = 35, currencyName = "Mark of Triumph" },
	["The Cruel Hand of Timmy"] = { amount = 35, currencyName = "Mark of Triumph" },
	["The Emperor's New Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["The Jaw Breaker"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Thornheart Bands"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Thornheart Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Thornheart Sash"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Thornheart Treads"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Thuzadin Sash"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Timeworn Mace"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Timmy's Galoshes"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Tooth of Gnarr"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Treads of Courage"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Trueaim Gauntlets"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Twitching Shadows"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Unsophisticated Hand Cannon"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Vambraces of the Sadist"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Venomspitter"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Verdant Footpads"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Verek's Collar"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Verek's Leash"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Vigorsteel Vambraces"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Waistguard of Tenacity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wand of Arcane Potency"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wand of Eternal Light"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Warpwood Binding"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Waterspout Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Well Balanced Axe"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Whipvine Cord"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wildfire Cape"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wildheart Belt"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wildheart Boots"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wildheart Bracers"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wildheart Gloves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Willey's Portable Howitzer"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Windreaver Greaves"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wraith Scythe"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wristguards of Renown"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Wristguards of Tenacity"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Xorothian Firestick"] = { amount = 35, currencyName = "Mark of Triumph" },
	["Amalgam's Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of Flesh"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of Mending"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of Rumination"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of Vigor"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of the Ogre King"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Band of the Steadfast Hero"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Bloodclot Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Cyclopean Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Dimly Opalescent Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Don Mauricio's Band of Domination"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Emerald Flame Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Flaming Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Flattened Elven Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Gordok Knuckleband"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Gordok Nose Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Innervating Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Kibble"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Magma Forged Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Magus Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Mark of the Dragon Lord"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Murmuring Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Naglering"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Necromantic Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Painweaver Band"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Ring of Demonic Guile"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Ring of Demonic Potency"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Rosewine Circle"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Rune Band of Wizardry"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Seal of Rivendare"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Signet of Transformation"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Skullcracker Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Tarnished Elven Ring"] = { amount = 44, currencyName = "Mark of Triumph" },
	["Beaststalker's Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bile-etched Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bloodmail Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bone Golem Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bonespike Shoulder"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Boreal Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bulky Iron Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Burial Shawl"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Cadaverous Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Cyclone Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Dark Warder's Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Deadwalker Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Death's Clutch"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Deathbone Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Demonic Runed Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Denwatcher's Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Devout Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Diabolic Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Dreadmist Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Dregmetal Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Earthslag Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Ebonsteel Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Flamescarred Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Golem Fitted Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Icy Tomb Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Ironweave Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Kentic Amice"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Kyrstel Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Lead Surveyor's Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Lightborne Shoulderguards"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Lightforge Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Magister's Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Mantle of Lost Hope"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Mantle of the Scarlet Crusade"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Necropile Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Pauldrons of Courage"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Pauldrons of Elements"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Pauldrons of Tenacity"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Raz's Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Royal Cap Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Shadowcraft Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Shoulderpads of Bravery"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Shoulderpads of Currents"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Shroud of the Nathrezim"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Slamshot Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Soulstealer Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Spaulders of Valor"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Splinthide Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Stoneform Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Stratholme Militia Shoulderguard"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Sunderseer Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Thornheart Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Thuzadin Mantle"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Truestrike Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Wailing Nightbane Pauldrons"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Wildheart Spaulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Wyrmtongue Shoulders"] = { amount = 45, currencyName = "Mark of Triumph" },
	["Bloodied Bone Dagger"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Briarwood Reed"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Burst of Knowledge"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Cannonball Runner"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Counterattack Lodestone"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Draconic Infused Emblem"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Force of Will"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Grace of the Herald"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Hand of Justice"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Heart of Wyrmthalak"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Heart of the Scale"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Mindtap Talisman"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Piccolo of the Flaming Fire"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Pimgib's Collar"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Ramstein's Lightning Bolts"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Second Wind"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Smolderweb's Eye"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Vigilance Charm"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Witching Hourglass"] = { amount = 55, currencyName = "Mark of Triumph" },
	["Alanna's Embrace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Amber Messenger"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ancient Bone Bow"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Angerforge's Molten Totem"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Arbiter's Blade"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Archived Record of Inquisition"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Azerothian Diamond Ring"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Band of the Titans"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Barrier Shield"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beaststalker's Cap"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beaststalker's Pants"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beaststalker's Tunic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beauty's Chew Toy"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beauty's Favorite Bone"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Beauty's Plate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Blade of the New Moon"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Blademaster Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Blood-etched Blade"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bloodmail Coif"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bloodmail Hauberk"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bloodmail Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bloodthirsty Ravaging Claw"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bone Ring Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Bonebrace Hauberk"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Book of the Dead"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Braincage"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Breakwater Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Breastplate of Valor"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Brightly Glowing Stone"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Cadaverous Armor"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Cadaverous Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Cadaverous Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Cape of Eternal Shrouding"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Carapace of Anub'shiah"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Carrion Scorpid Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Chestguard of Bravery"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Chestplate of Courage"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Chestplate of Tranquility"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Chief Architect's Monocle"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Chitinous Plate Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Circle of Flame"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Clever Hat"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Coif of Elements"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Corla's Obsidian Relic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Crepuscular Shield"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Crest of Retribution"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Crimson Felt Hat"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Crown of Tyranny"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Crown of the Ogre King"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dal'Rend's Sacred Charge"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Deathbone Chestplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Deathbone Helmet"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Deathbone Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Deathdealer Breastplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Devout Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Devout Robe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Devout Skirt"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Draconian Aegis of the Legion"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Draconian Deflector"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dragoneye Coif"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dragonfang Talisman"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dragonskin Cowl"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dreadguard's Protector"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dreadmist Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dreadmist Mask"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dreadmist Robe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Dungeonlord's Drape"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Eldritch Reinforced Legplates"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Energetic Rod"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Energized Chestplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Enthralled Sphere"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Eye of Rend"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Faceguard of Bravery"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Father Flame"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Felhide Cap"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Flamestrider Robes"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Flarethorn"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Flightblade Throwing Axe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Foreman's Head Protector"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Freezing Lich Robes"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Funeral Pyre Vestment"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ghostloom Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ghostshroud"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ghoul Skin Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Gift of the Elven Magi"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Globe of D'sak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Golem Skull Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Gordok Ritual Totem"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Grand Crusader's Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Greathelm of Courage"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Gyth's Skull"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Hammer of Revitalization"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Handcrafted Mastersmith Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Hauberk of Tenacity"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Haunting Spectre Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Headdress of Currents"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Heat Wave Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Helm of Awareness"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Helm of Tenacity"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Helm of Valor"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Helm of the Executioner"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Helm of the New Moon"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Houndmaster's Bow"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Husk of Nerub'enkan"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Hyena Hide Jerkin"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Idol of Ferocity"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Idol of Lunar Apparitions"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Idol of Rejuvenation"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Idol of the Tamed Mauler"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Inquisition Robes"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Insightful Hood"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Intricately Runed Shield"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ironguard Signet"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ironweave Cowl"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ironweave Pants"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ironweave Robe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Kilt of Elements"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Kreeg's Mug"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Kromcrush's Chestplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lavacrest Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Leggings of Bravery"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Leggings of Currents"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Leggings of Destruction"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Leggings of Frenzied Magic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Leggings of Torment"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Legguards of Courage"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Legguards of Tenacity"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Legplates of Valor"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Legplates of Vigilance"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Legplates of the Eternal Guardian"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Libram of Divinity"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Libram of Hope"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Libram of Truth"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lichbone Neck"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightborne Chestguard"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightborne Faceguard"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightborne Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightforge Breastplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightforge Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Lightforge Legplates"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Luminary Kilt"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Maelstrom Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Magister's Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Magister's Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Magister's Robes"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Magmus Stone"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Malgen's Long Bow"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Mask of the Unforgiven"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Mastersmith's Hammer"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Memento of Quel'thalas"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Mind Carver"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Mindsurge Robe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Mixologist's Tunic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Molten Forged Necklace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Necropile Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Necropile Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Necropile Robe"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Nightbrace Tunic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Observer's Shield"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ogre Forged Hauberk"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ogre Toothpick Shooter"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Oversimplified Stick Chucker"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Padre's Trousers"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Petrified Bark Shield"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Petrified Codex"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Plaguehound Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Plate of the Shaman King"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Polychromatic Visionwrap"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ragefury Eyepatch"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Rattlecage Buckler"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Reliquary Scripture"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Remulos' Restorative Rites"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Renouncer's Cowl"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Rhombeard Protector"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ring of the Damned"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Riphook"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Robe of Combustion"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Robe of Everlasting Night"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Robes of the Exalted"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Robes of the Royal Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Rock Golem Bulwark"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Royal Decorated Armor"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Sacred Cloth Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Satyr's Bow"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Savage Gladiator Chain"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Savage Gladiator Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Savage Gladiator Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Scarab Plate Helm"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Scarlet Friar's Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Scepter of Interminable Focus"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Screeching Bow"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Searingscale Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Senior Designer's Pantaloons"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Shadowcraft Cap"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Shadowcraft Pants"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Shadowcraft Tunic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Shaggy Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Shield of the Iron Maiden"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Silvermoon Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Skul's Cold Embrace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Skull of Burning Shadows"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Skullsmoke Pants"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Skyshroud Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Songbird Blouse"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Soothing Aquamarine Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Spellbound Tome"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Spellweaver's Turban"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Spiderfang Carapace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Spiritshroud Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Starfire Tiara"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Stoneshell Guard"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tanglemoss Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tattered Leather Hood"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Thaurissan's Royal Scepter"] = { amount = 60, currencyName = "Mark of Triumph" },
	["The Hammer of Grace"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Thornheart Cover"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Thornheart Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Thornheart Tunic"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Threadbare Trousers"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tombstone Breastplate"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tome of Divine Right"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tome of Knowledge"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tome of the Lost"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Torturer's Mercy"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Totem of Rage"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Totem of Rebirth"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Totem of Sustaining"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tressermane Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tribal War Feathers"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tristam Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tunic of Currents"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Tunic of the Crescent Moon"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Unbridled Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Ursinefur Cloak"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Vest of Elements"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Warmaster Legguards"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Warstrife Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wildheart Cowl"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wildheart Kilt"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wildheart Vest"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wildwater Totem"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Willey's Back Scratcher"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Willowy Crown"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Witchblade"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wolfshear Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Woollies of the Prancing Minstrel"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wraith Choker"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Wraithplate Leggings"] = { amount = 60, currencyName = "Mark of Triumph" },
	["Aegis of Defense"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Aegis of Impunity"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Aegis of Sanctity"] = { amount = 65, currencyName = "Mark of Triumph" },
	["Angerforge's Battle Axe"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Barbarous Blade"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Barovian Family Sword"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Blackblade of Shahram"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Blackhand Doomsaw"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Blessed Windstone"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Chillpike"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Demonshear"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Draenei Focusing Crystal"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Dreadforge Retaliator"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Fist of Omokk"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Flame Wrath"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Force of Magma"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Frightskull Shaft"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Gravestone War Axe"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Guiding Stave of Wisdom"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Hammer of Divine Might"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Hammer of the Grand Crusader"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Headmaster's Charge"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Holdable Ruby"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Hoodoo Detector"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Huntsman's Harpoon"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Impervious Giant"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Kindling Stave"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Lavastone Hammer"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Lord Valthalak's Staff of Command"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Lunar Splinter"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Malicious Axe"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Monstrous Glaive"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Peacemaker"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Quel'dorei Channeling Rod"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Redemption"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Relentless Scythe"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Rod of the Ogre Magi"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Runeblade of Baron Rivendare"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Seeping Willow"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Skullcracking Mace"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Slavedriver's Cane"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Spire of the Stoneshaper"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Staff of Metanoia"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Stone of the Earth"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Stoneflower Staff"] = { amount = 70, currencyName = "Mark of Triumph" },
	["The Blackrock Slicer"] = { amount = 70, currencyName = "Mark of Triumph" },
	["The Judge's Gavel"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Treant's Bane"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Trindlehaven Staff"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Unyielding Maul"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Waveslicer"] = { amount = 70, currencyName = "Mark of Triumph" },
	["Drakefury Scale"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Rose of Remembrance"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Signet of Vitality"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Spellbound Demonic Rune"] = { amount = 80, currencyName = "Mark of Triumph" },
	["Assassin's Cover"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Birdbrain's Cage"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Centurion's Barbute"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Golden Greathelm"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Microscopic Focusing Lens"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Rubicon Crown"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Searing Sun Greathelm"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Shroud of the Cathedral"] = { amount = 85, currencyName = "Mark of Triumph" },
	["Spiritual Tauren Headdress"] = { amount = 85, currencyName = "Mark of Triumph" },
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
