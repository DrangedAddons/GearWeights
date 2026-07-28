# Changelog

All notable changes to GearWeights are recorded here. Each new version gets its own section, newest first - add to this file as part of the work, not just at release time.

Only the newest entry is left as a plain, always-visible `## vX.Y.Z` heading. When a new version is added, wrap the entry that was previously newest in a collapsed `<details><summary>vX.Y.Z - date</summary>` block (see the example below) - GitHub renders that as a collapsed, expandable section. Keep doing this one section at a time as new versions land, so the full history stays here without making the page long to scroll through.

<!--
Shape once a second version exists (placeholders only - avoid writing a
real, literal "## vX.Y.Z" line in here: the release workflow greps for
the first line matching the tagged version's heading, so a real-looking
version number sitting inside this comment could get matched instead of
the actual section further down):

## v<NEWEST> - <date>
(newest entry - stays fully visible, not wrapped)

<details>
<summary>v<PREVIOUS> - <date></summary>

(previous entry's full body goes here, unchanged)

</details>
-->

## v1.26.22 - 2026-07-28

### New: Included Slots / Armor Types / Included Dungeons & Raids (Settings tab)
- "Locked Slots" renamed to "Included Slots" and flipped to a positive whitelist: every slot is checked (included) by default, and you uncheck a slot to stop counting upgrades there - reads as a positive confirmation instead of confirming a negative. Reordered into two columns matching the character pane's paperdoll layout.
- Added an Armor Types filter (Plate/Mail/Leather/Cloth), same whitelist framing - uncheck a type to stop seeing its upgrades (e.g. a Plate wearer hiding spellpower Cloth suggestions). A type your class can't wear at all shows greyed out with a tooltip explaining why.
- Added an Included Dungeons & Raids checklist - every zone the out-of-instance ranking scan would consider, whitelisted the same way. Sorted to match AtlasLoot's own category menu order. All 8 classic raids are listed; only World Bosses and Zul'Gurub are enabled today, the rest show greyed out until they're confirmed live on this server.

### Dungeon/Raid Ranking Panel
- Difficulty tiers (Normal/Heroic/Mythic) are now filtered independently for Dungeons vs. Raids, instead of one shared row - raids are typically a tier behind the equivalent dungeon difficulty in practice (you often move from Heroic/Mythic dungeons into Normal raids), so one filter didn't fit how progression actually works.

### Fixes
- Fixed the main window not appearing at all after an unrelated Settings change reinterpreted a saved window position under a different coordinate scheme.
- Fixed a crash on `/gw` caused by a new Settings function being defined before a helper it depended on (a recurring Lua scoping gotcha in this codebase - see CLAUDE.md-adjacent notes if this bites again).

<details>
<summary>v1.26.11 - 2026-07-27</summary>

First release since v1.17.1 - a lot has landed since then.

### New: Weapon Baseline Tracking
- Three independent reference boxes (Two-Hand / Main-Hand / Off-Hand) that each remember your last-relevant weapon, so switching between a 2H loadout and dual-wield doesn't lose track of either.
- Click a box to lock it to a specific item; drag a weapon onto a box to set it manually.
- Shift-hover comparison tooltips show how a candidate weapon stacks up against both your Two-Hand and Main-Hand+Off-Hand combo, including a `[!]` flag when an item would flip which loadout scores higher.
- Added a short help line under the boxes explaining drag/lock, with a bit more breathing room around them.

### Vendor Prices
- Vendor listings now show real prices instead of "Free" for items whose cost isn't exposed by the game's normal APIs.
- Added a manually compiled price table covering the Mark of Triumph Vendor's full ~768-item stock.
- Prices render as an icon + hover tooltip, matching the currency tracker.

### Dungeon/Raid Ranking Panel
- Fixed the same item appearing as a duplicate upgrade across Normal/Heroic/Mythic tiers when it doesn't actually scale.
- Sort by upgrade amount for both boss loot and vendor items.
- Category headers now show both zone count and item count.
- Unique-Equipped items are now handled correctly - won't claim a copy you can't actually equip is a real upgrade.
- "View by Slot" now remembers whether you had it checked, instead of resetting every login.

### Fixes
- Fixed the resize handle occasionally snapping the window to full size the instant you clicked it, before you'd dragged at all.
- Fixed the main window sometimes not appearing at all after certain updates.
- Fixed a couple of crashes from earlier in this cycle (a stale saved-data format, a missing frame name).

### Other
- Vendor and quest-reward item glow effects were added, then disabled for now (including their Settings toggles) - the underlying code is still there, just inactive until revisited.

</details>
