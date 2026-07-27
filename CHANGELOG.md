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

## v1.26.11 - 2026-07-27

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
