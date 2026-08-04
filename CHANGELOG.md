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

## v1.26.63 - 2026-08-03

### Fixes
- Fixed scaled items (pre-level-60 dungeon/world drops and trash - level 60 heroic/mythic dungeon and all raid loot is fixed and unaffected) giving actively wrong scores/upgrade verdicts - GetItemStats() returns a cached snapshot that isn't reliably tied to the specific instance of the item you're actually looking at, and this server allows up to ~60 different valid variants of the same item to exist at once (one per character level it can scale to). Confirmed via a real item with two copies in bags at once - one read correctly, the other showed +15 Spirit in the GearWeights breakdown against a tooltip that plainly stated +17. Now, wherever the item's own tooltip - always correct for whoever's looking at it, and permanently fixed once the item is actually looted - states a different value for a stat than GetItemStats() does, the tooltip's number is trusted outright, with no "is this close enough to GetItemStats() to just leave it" tolerance: a wrong cached variant can easily land close enough to the real value to slip past a tolerance check (as the +15-vs+17 case did), so any disagreement at all now gets corrected. Whenever a tooltip is already on screen for the item (hovering it, or GearWeights adding its own lines to it), its already-displayed lines are read directly instead of opening a second, separate tooltip query - a separate query was found to behave unreliably for an item you already own, seemingly re-triggering the server's still-settling drop logic rather than reporting the item's real, fixed value. A dedicated scan tooltip is still used, but only for the background ranking scan evaluating potential drops nobody has looted yet, where there's no existing tooltip to read from. A corrected item's tooltip shows "(scaled item - stats corrected to match this tooltip)" so it's clear a correction happened.
- Updated the "-- Scaling correction --" section of `/gw dumphover`/`/gw dump` to also report whether the correction was read from the already-displayed tooltip or a separate scan, for diagnosing a case where the correction still isn't kicking in as expected.
- Fixed loot window and need/greed roll popups getting stuck showing a scaled item's pre-settle stats (and score) for as long as they sat there, only ever catching up to the real, correct value after actually being looted - reading straight off the already-displayed tooltip (the fix above) is correct for an item you already own, but a not-yet-looted item is a different case: it's still actively settling, and something about querying it independently (rather than just trusting whatever's currently painted) turned out to be part of what drives that settling forward. Hovering a loot slot or roll popup now goes back to independently querying the item's current value on every hover, same as the background ranking scan already did, instead of reading whatever the tooltip happens to be showing at that instant.
- Fixed a severe lag spike (reported as a full client freeze/crash) from hovering loot, worst on a session's very first drop - the independent query added by the fix above ran fresh, uncached, every single time Blizzard's own loot tooltip re-asserted itself while the mouse just sat still (which happens repeatedly on its own, and is part of how a still-settling item's tooltip updates itself), and a single GearWeights tooltip append pass already asks for an item's stats several times internally (score, correction check, breakdown), multiplying it further. Each of those had become a full server round-trip specifically for items still settling their scaled stats - fine occasionally, not fine dozens of times a second. Now throttled to at most one real query per item per half-second, reusing that result for any repeat ask inside the window - far too brief to notice on a tooltip, but enough to stop the pile-up.
- Fixed Blizzard's own native "If you replace this item, the following stat changes will occur:" tooltip section visibly flickering between two different values every half-second while shift-comparing a scaled item - not a line GearWeights writes, but every comparison GearWeights computes (not just the item you're actually hovering, but also whatever it's being measured against - equipped gear, tracked weapon boxes) was scoring those reference items through the same separate-scan path as a not-yet-looted item, since none of those lookups had a live tooltip of their own to read from. For an item you already own, that's exactly the query already known to be unreliable (the very first fix in this version) - so it was repeatedly perturbing the equipped item's own stats behind the scenes, which Blizzard's native comparison reads directly with no correction of its own, making the flicker visible on-screen. Equipped gear and tracked weapon boxes now get a real, reliable live tooltip too (SetInventoryItem for whatever's actually worn right now, the same trustworthy source the hovered item itself uses), instead of falling back to the separate scan they'd been using by omission.

<details>
<summary>v1.26.60 - 2026-08-01</summary>

### Fixes
- Fixed the cross-spec tooltip comparison's Equipment Set lookup being unreliable on this server - confirmed a case where an item was genuinely saved in a set but Blizzard's own GetEquipmentSetItemIDs still returned nothing for that slot. Now snapshots each set's actual contents (full item links, gems/enchants included) ourselves at the moment it's saved, via the same live-gear API already trusted elsewhere in this addon, instead of relying on that API to report it correctly after the fact. **Existing Equipment Sets need to be re-saved once (Update in the Equipment Manager) for this snapshot to exist** - until then it falls back to the old, less reliable lookup.
- Fixed the cross-spec tooltip comparison confidently claiming a candidate was a big "Upgrade" for another spec when that spec's Equipment Set had no item saved for that slot - treated the same as a genuinely empty slot (counting the full score as the diff), when a missing slot is far more likely to mean the Equipment Set is stale/incomplete (Equipment Sets don't auto-sync with what's actually equipped). Now shows "No reference for this slot in this spec's Equipment Set" instead of guessing at a verdict.

</details>

<details>
<summary>v1.26.58 - 2026-08-01</summary>

### Fixes
- Fixed weapon/armor proficiency detection incorrectly reporting "Unusable by your class" for a skill the character genuinely has, on classes whose Skills pane lists a separate "One-/Two-Handed X" line rather than the stock-WoW convention of one shared "X" line for both variants - confirmed via a real item dump (itemSubType "Two-Handed Maces" matching the Skills pane's own line name exactly, but the code only ever checked for a line named "Maces"). Now checks the raw skill-line name first, before falling back to the translated short form.
- Fixed weapon/armor usability checks getting stuck stale for the rest of the session - the proficiency scan (Skills pane) and its per-item usability cache were never invalidated after their first computation, so a character who gained a new weapon skill (or swapped to a build granting different ones) mid-session could keep seeing "Unusable by your class" on an item they could now actually use, until a full /reload. Now cleared on SKILL_LINES_CHANGED, the event that fires exactly when the Skills pane's own data changes.
- Fixed the Stat Weights tab's "Weight" column header drifting out of alignment with the actual weight edit boxes when the window is resized - the header tracked the scroll frame's width, but the row/edit-box widths stayed fixed at their original size. Both now resize together, same approach already used on the Instance Loot tab.
- Fixed confusing/ambiguous weapon comparison framing on Two-Handed weapon tooltips: "Combo vs Two-Hand" reused "Two-Hand" to mean the candidate itself in one line, right after using it to mean your tracked Two-Hand box in the line above - genuinely ambiguous, not just inconsistently worded. Now reads "vs Combo", consistently framed with the candidate as the subject throughout (matching "vs Two-Hand" above it), the same way Main-Hand/Off-Hand candidates were already framed with the resulting Combo as the subject.
- Added an explicit "[!] This would make X your better loadout" note on weapon tooltips when a candidate would flip which loadout (Two-Hand vs Combo) scores higher overall - the same flip check that already drives the ranking list's own [!] marker, now also surfaced directly on the tooltip itself.
- Fixed the bottom-bar Mark of Triumph icon showing as a blank/broken texture for a character with 0 of that currency - the item-count fallback path only fetched the icon when the count was greater than 0, and a currency-list icon that comes back as an empty string wasn't being caught by the existing nil-only fallback either.

</details>

<details>
<summary>v1.26.53 - 2026-08-01</summary>

### Fixes
- Moved the tooltip's per-stat score breakdown to render AFTER the Upgrade/Downgrade verdict line(s) instead of before - the breakdown explains a verdict you've already seen, not the reverse.
- Main window background opacity: now also forces the frame's own alpha (not just the backdrop color's alpha channel - the two multiply together, so a low frame alpha would mute full-opacity backdrop colors regardless), and re-applies both every time the window is shown rather than only once at creation, in case a reskin addon re-applies its own transparency afterward.
- Fixed the Settings tab's Spec Comparisons section (checkboxes and Equipment Set assignments) being shared account-wide instead of per-character - switching characters showed one character's spec picks and Equipment Set names on another's screen, same class of bug as the earlier stat-weight-profile/weapon-baseline fix. Existing data migrates to whichever character loads first under this version.

</details>

<details>
<summary>v1.26.50 - 2026-07-29</summary>

### New: Cross-spec tooltip comparison
- Item tooltips can now show whether a candidate is also an upgrade for OTHER specs, not just whichever one you're actively playing - scored against that spec's own saved stat weights, shown below the active spec's own score/breakdown.
- Since there's no live "currently equipped" for a spec you're not standing in, each spec you enable needs a Blizzard Equipment Set assigned to it (new Settings tab section: "Spec Comparisons", one row per spec slot with a checkbox + dropdown of your saved sets). Specs 1 & 2 start ticked; a spec's comparison doesn't show on tooltips until a set is also assigned to it.
- Equipment Sets only expose the base item ID for each slot, not the full item link - so gems/enchants on that spec's saved gear aren't factored into its score, only the item's own innate stats. Good enough to catch a real upgrade, not perfectly precise.
- Weapon slots for other specs are treated as plain single-slot comparisons (whatever the Equipment Set has saved for Main-Hand/Off-Hand) - the active spec's own Two-Hand vs Main-Hand+Off-Hand combo tracking only applies to whichever spec you're actually playing, since that tracking is driven by live equip-change events.
- A Settings toggle controls whether other specs show a full per-stat breakdown (default) or just a compact Upgrade/Downgrade line.
- Added a spec picker to the Stats tab so you can view/edit ANY spec's stat weights (including import/export) from wherever you're currently playing, instead of only ever being able to edit whichever spec is actively equipped - needed to actually set up a spec's weights for the cross-spec comparison above without physically switching to it.

### Dungeon/Raid Ranking Panel
- A spec change now automatically re-runs the ranking scan (and re-syncs the weapon baseline boxes), so results always reflect whichever spec just became active instead of sitting stale with just a passive "(spec changed since this scan)" note until you remember to rescan yourself. Polled rather than event-driven, since there's no reliable event for a pure spec swap that doesn't also change your gear.

</details>

<details>
<summary>v1.26.47 - 2026-07-29</summary>

### New: Tooltip score breakdown
- The "GearWeights: X.X" tooltip line now shows a per-stat breakdown underneath it (e.g. "+20 Spell Power (+6.0)"), so it's clear exactly which stats are driving the score. Each stat's contribution is relative to whatever this item would actually replace, not the item's own absolute stat value - so a stat you'd have less of than what you're already wearing correctly shows as a downgrade for that one line, even while other stats make the item an overall upgrade. Falls back to plain absolute contributions when there's nothing to compare against (an empty slot, or a Two-Handed weapon, whose comparison is a combined score rather than a single item). Only stats this profile actually weights are shown, biggest contribution first.

</details>

<details>
<summary>v1.26.44 - 2026-07-29</summary>

### Fixes
- Fixed stat-weight profiles and weapon baseline boxes being shared across different characters on the same account whenever they landed on the same numeric spec slot - both are now scoped per-character (in addition to per-spec), so a brand-new character always starts blank instead of inheriting another character's weights/tracked weapons. Existing data migrates automatically into whichever character is active the first time this version loads.

</details>

<details>
<summary>v1.26.43 - 2026-07-29</summary>

### Fixes
- Fixed the Greed-roll Bind-on-Pickup bypass ("Prompt to accept BoP when Greed looting", unticked) never actually suppressing the confirmation popup - `LOOT_ROLL_TYPE_GREED` is nil on this server's client even though the roll type value itself arrives normally, so the comparison silently always failed. Now falls back to the standard numeric value when the named constant isn't defined.

<details>
<summary>v1.26.42 - 2026-07-29</summary>

### New: Reputation-gated items (Settings tab: Reputations)
- Added Reputations as a new upgrade category alongside Dungeons/Raids/Vendor, covering all 12 classic reputation factions (Argent Dawn, Alterac Valley, Arathi Basin, Timbermaw Hold, Zandalar Tribe, Bloodsail Buccaneers, Cenarion Circle, Hydraxian Waterlords, Desolace Centaur Clans, Thorium Brotherhood, Wintersaber Trainers, Brood of Nozdormu).
- Standing is read directly off each item's own tooltip ("Requires \<Faction\> - \<Standing\>"), shown next to the item as just the standing (e.g. "Exalted") since the faction is already implied by the section it's listed under.
- A handful of items that carry no tooltip requirement line at all (Alterac Valley's insignia rank rewards, Bloodsail Buccaneers' costume set, Cenarion Circle's badge-purchased rewards, Desolace's Gelkis/Magram items) are handled through a small hardcoded standing table, verified faction-by-faction against real game data.
- Added a "Neutral" standing tier (below Friendly) for items that only require a quest, no rep threshold.
- Reputation upgrades are no longer gated by whether that reputation is currently visible in your own reputation pane - most classic reps stay hidden until an unlock quest is done, but this now surfaces "worth going to earn" upgrades regardless, only excluding genuinely Alliance/Horde-locked factions (Stormpike Guard vs. Frostwolf Clan).
- Brood of Nozdormu and Hydraxian Waterlords are listed but greyed out and excluded from scanning - both are earned in raids (Blackwing Lair, Molten Core) not yet confirmed live on this server.
- Added a per-faction/per-standing checklist to the Settings tab, and a coarse "Other Sources: Reputations" toggle next to Vendors on the Instance Loot tab.
- Reputation scanning piggybacks on the existing login auto-scan and caches its tooltip results in memory for the session, so there's no added per-item cost during normal play.

### Settings tab: collapsible sections
- Included Slots, Included Dungeons & Raids, and the new Reputations checklist are now collapsible (click the header to expand/collapse), instead of one long scroll.

### Instance Loot tab: layout polish
- Added WoW-style divider lines between source-toggle groups - a subtle line between closely-related rows (e.g. Raids/Other Sources), a brighter one between bigger conceptual sections (Other Sources/View by Slot, and around the weapon boxes).
- Moved the weapon box help text to the right of the boxes instead of below, to save vertical space.
- Renamed the rescan button to "Scan All Sources" to reflect the broader set of sources it now covers.
- Made the main window background more opaque.

### Weapon Baseline Tracking
- The Two-Hand/Main-Hand/Off-Hand reference boxes are now tracked per-spec instead of sharing one set - since this is a classless/hybrid-class server, switching spec often means switching to a completely different weapon. Existing tracked weapons migrate automatically into your active spec on first load of this version.

### Known issue
- The Greed-roll Bind-on-Pickup bypass ("Prompt to accept BoP when Greed looting", unticked) isn't currently suppressing the confirmation popup - under active investigation; this build includes temporary debug chat output to help diagnose it. (Fixed in v1.26.43, see above.)

</details>

<details>
<summary>v1.26.22 - 2026-07-28</summary>

### New: Included Slots / Armor Types / Included Dungeons & Raids (Settings tab)
- "Locked Slots" renamed to "Included Slots" and flipped to a positive whitelist: every slot is checked (included) by default, and you uncheck a slot to stop counting upgrades there - reads as a positive confirmation instead of confirming a negative. Reordered into two columns matching the character pane's paperdoll layout.
- Added an Armor Types filter (Plate/Mail/Leather/Cloth), same whitelist framing - uncheck a type to stop seeing its upgrades (e.g. a Plate wearer hiding spellpower Cloth suggestions). A type your class can't wear at all shows greyed out with a tooltip explaining why.
- Added an Included Dungeons & Raids checklist - every zone the out-of-instance ranking scan would consider, whitelisted the same way. Sorted to match AtlasLoot's own category menu order. All 8 classic raids are listed; only World Bosses and Zul'Gurub are enabled today, the rest show greyed out until they're confirmed live on this server.

### Dungeon/Raid Ranking Panel
- Difficulty tiers (Normal/Heroic/Mythic) are now filtered independently for Dungeons vs. Raids, instead of one shared row - raids are typically a tier behind the equivalent dungeon difficulty in practice (you often move from Heroic/Mythic dungeons into Normal raids), so one filter didn't fit how progression actually works.

### Fixes
- Fixed the main window not appearing at all after an unrelated Settings change reinterpreted a saved window position under a different coordinate scheme.
- Fixed a crash on `/gw` caused by a new Settings function being defined before a helper it depended on (a recurring Lua scoping gotcha in this codebase - see CLAUDE.md-adjacent notes if this bites again).

</details>

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
