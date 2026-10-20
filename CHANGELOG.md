# CHANGELOG

## 2026-10-20 — Director can spawn specials during the finale

- **Ethan:** sitting out the finale is boring. The Director should still be able to spawn regular special infected, but not the Horde, Panic Horde, Tank or Witch.
- **Change:** new `finale` key `allow_types` (set to `special`). After `ai_takes_over` hands the finale to the AI, items of those types stay buyable under the normal placement rules, group lock and alive limit. Everything else stays locked, and the AI still runs the finale's hordes and Tanks.
- **Also:** a reload in the middle of a finale now picks the finale back up (`L4D_IsMissionFinalMap` + `L4D2_GetCurrentFinaleStage() != FINALE_NONE`). Before, it switched the AI back off and killed the finale's hordes.

## 2026-10-20 — Map crescendos get normal hordes

- **Ethan:** during alarm or generator sections, hordes should spawn as normal.
- **Cause:** `director_no_mobs 1` (AI off while a Director is active) also blocked the panic waves that map events start.
- **Change:** on `create_panic_event` from the map, the AI's mobs are allowed until `panic_event_finished`, or `max_seconds` as a backstop. The Director's own Panic Horde is skipped. Specials and bosses stay off. New config section `crescendo` (`ai_mobs` 1, `max_seconds` 300). Log lines: `CRESCENDO started / finished / timed out`.

## 2026-10-20 — Director earned no points on some maps

- **Ethan:** a friend playing Director wasn't gaining points.
- **Cause:** L4D2 sometimes fires `round_start` before SourceMod's `OnMapStart`. `OnMapStart` then reset the round-live flag to off, so the income timer paid nothing for the whole map. The log showed it: claimed at 50, spent 25 on a Horde 49 s later, and 25 were left.
- **Fix:** `OnMapStart` no longer clears the flag; it only sets it on a late load. `OnMapEnd` already clears it between maps. Verified live: +39 points in 39 s after the hot deploy.
- **Also:** the plugin now loads `common.phrases`. Without it, `sm_director_assign` aimed at a bot or a bad target threw an exception instead of replying with the error.

## 2026-10-18 — Published to GitHub

- Repo: https://github.com/ethanater63/Left4Dead2_Director_of_Chaos (GPLv3), set up like the invasion repo: `LICENSE`, `.gitattributes` (LF everywhere, `.smx` binary), a `Makefile` wrapping `build.sh`, and the compiled `.smx` committed.
- Ethan's intro from the GitHub README now opens `README.md`.
- The public IP and DuckDNS name were removed from the docs before publishing, because both servers are deliberately unlisted.

## 2026-10-18 — Server unlisted

- **Ethan:** keep the Director server off the server browser.
- **CT 107 launch line:** added `-nomaster`. The server no longer registers with Steam's master list (confirmed by the Steam API) and ignores A2S info queries.
  - The join handshake still answers on the LAN and the public IP, so `connect <host>:27016` still works.
  - Backup: `/etc/systemd/system/l4d2.service.bak-nomaster`.
- **`server.cfg`:** `sv_tags` changed from `invasion,coop,sourcemod` (left over from the clone) to `director,coop,sourcemod`. Backup: `server.cfg.bak-tags`.
- **Follow-up:** the invasion server (CT 103) got the same `-nomaster` change at Ethan's request (backup `l4d2.service.bak-nomaster`). The Steam API now lists no servers at the public IP, and both servers still answer the join handshake.

## 2026-10-18 — Panic Horde cost

- **Ethan:** Panic Horde seems overpowered. Make it cost more.
- **Config only:** panic `cost` changed from 150 to 250. That's more than a Tank (200), and about 4 min of income at 1 pt/s, out of a 300 cap.

## 2026-10-18 — Longer special lock

- **Ethan:** make the special lock longer, about a minute.
- **Config only:** `groups.specials.window` changed from 30 to 60. The cap is now 2 specials per minute.

## 2026-10-18 — Shared special cooldown

- **Ethan:** add the shared cooldown, but allow 2 specials at once so the Director can coordinate them. One at a time would be too easy for the survivors.
- **Code (new mechanic):** optional `groups` config section plus a per-item `group` key.
  - A group allows `max_per_window` buys. The window starts at the first buy.
  - After the limit, every item in the group is locked until the window ends.
  - Group windows reset with cooldowns at the start of a campaign.
- **Config:**
  - New group `specials` (`max_per_window 2`, `window 30`).
  - All six specials joined it.
  - The result: at most 2 specials per 30 s, and the pair can be bought back to back.

## 2026-10-18 — Director too strong with specials

- **Ethan:** the Director feels overpowered. Specials can be spammed by cycling through them, since each one's cooldown is separate.
- **Config only (first step):**
  - `income_per_sec` changed from 2 to 1 (120 to 60 pts/min).
  - `max_alive_specials` changed from 4 to 3.
  - This roughly halves how many specials the Director can afford. Tank (200) and Panic Horde (150) also now take longer to save for.
- **Proposed code change, not built:** a shared cooldown for all specials, so buying any special briefly locks out the others. No config key can stop the cycling itself.

## 2026-10-18 — Horde cooldown

- **Ethan:** the regular horde needs a longer cooldown. Try 1:30.
- **Config only:** mob `cooldown` changed from 20 to 90.

## 2026-10-18 — Tank cooldown

- **Ethan:** a normal round has one Tank, so a second Tank should come from the Director's skill (slowing the survivors down), not from the timer.
- **Config only:** tank `cooldown` changed from 180 to 600 (10 min), about the length of a map at a normal pace.
- Cooldowns run on real time and carry over map changes within a campaign. A Tank bought late in one map still counts against the start of the next.

## 2026-10-18 — Panic Horde tuning (Ethan's playtest)

- **Ethan:** "the cost should be 150, it didn't spawn a big enough horde, the cooldown should be about 2 minutes."
- **Config:** panic `cost` changed from 75 to 150. `cooldown` stays at 120 (already 2 min).
- **Horde too small:**
  - No existing config key could fix it. A panic wave is sized by `z_mega_mob_size` (50 on this server) and capped by `z_common_limit` (30), so only about 30 commons were ever alive at once.
  - **Code:** new optional panic keys `horde_size` and `common_limit`. They set those two cvars for the panic window, then restore the saved values. Restore also runs on release, map end and plugin end.
  - **Config:** `horde_size 80`, `common_limit 80`.

## 2026-10-18 — Panic Horde item

- **Ethan asked:** let the Director start a "Panic Mode" horde.
- **Config:** new 10th item `panic`: "Panic Horde", `method panic`, `duration 30`, cost 75, cooldown 120. These are first-guess numbers to tune.
- **Code (mechanic change):**
  - A panic item fires as soon as it's picked from the menu. The game chooses where the horde comes from, so placing it at the crosshair would mean nothing.
  - `director_no_mobs` is lifted to 0 for the item's `duration` so the panic waves can spawn, then set back to 1.
- **Menu:** the limit is raised from 9 to 10 items. The 10th item uses key 0, and the Exit row is dropped when all 10 slots are used.

## 2026-10-18 — Fix: clicks didn't place

- **Bug (Ethan's first test):** left click jumped the camera onto a survivor and didn't spawn the armed Boomer. A spectating client never sends a click as `IN_ATTACK`. It sends `spec_next` (left), `spec_prev` (right) or `spec_mode` (jump), so the plugin never saw the click and the server changed the observer target.
- **Fix (code; this is a mechanic change):**
  - A listener on `spec_next`, `spec_prev` and `spec_mode` blocks all three for the Director, so the free camera holds.
  - `spec_next` places the armed item and `spec_prev` cancels it.
  - The `IN_ATTACK` path is kept, with a shared debounce so one click still makes one spawn.
- Hot-reloaded on CT 107.
- **Follow-up:** after a right-click cancel, the hint said "Armed: none" but the menu didn't come back.
  - The menu now reopens 0.2 s after a place or cancel, instead of in the same tick as the click.
  - Debug logging now records each click command and button press, to confirm what the client sends.
  - Confirmed in-game: left click placed a Charger and a Horde, and the menu came back after each.
- **Fix:** no income after a mid-map plugin reload.
  - Income only runs between `round_start` and `round_end`, and a reload mid-round never sees `round_start`.
  - A late load now counts as a live round.
- **Fix:** after picking a greyed-out row (Tank at under 200 points), the menu disappeared with no way back except `!dmenu`.
  - Any number key makes the client hide the menu, so the menu now reopens itself unless the Director picked Exit.
  - Right click while nothing is armed now opens the menu.
  - The hint shows "Right click: spawn menu" while nothing is armed.
- **Fix:** Boomers spawned ~438 units below the crosshair, under the map. The server log shows both Boomers in nav Area 0, and l4dinfectedbots kicked them later.
  - Specials and Tanks are now teleported to the aimed point right after `L4D2_SpawnSpecial`/`L4D2_SpawnTank`.
  - With debug on, each spawn's position is logged 0.5 s later to confirm it held.
- **Noted, no change:** a lone Tank (8000 HP on Expert) died in ~25 s to four survivor bots. Judge Tank strength with human survivors before tuning. If it's still too weak, a per-item `health` key is the proposed (code) change.

## 2026-10-18 — Deployed

- New server **CT 107 `l4d2-director`** at 192.168.1.55, a full clone of the invasion CT 103, with the invasion plugin disabled. CT 103 is unchanged and still running invasion.
- The Director server moved to port **27016**, so both servers can be reached through the one public IP. This needs a router forward of UDP+TCP 27016 → 192.168.1.55.
- `deploy_plugin.sh` now defaults to `l4d2-director-deploy`, so a bare run can't hit the invasion server.
- Verified over rcon: "L4D2 Director Mode" (1.0.0) is loaded, `l4d2_invasion` is not, and the error log is clean.

## 1.0.0 — 2026-10-18 — Phase 1

First build. Not yet tested in-game.

- `l4d2_director.sp`: claiming and releasing the role, free camera, AI Director off/on, economy, spawn menu, crosshair placement with validation, mob/special/Witch/Tank spawns, alive tracking, per-map stats and summary log.
- `configs/l4d2_director.cfg` with the Phase 1 starting values from CLAUDE.md.
- **Step 4.2 is handled by Step 4.1:** l4dinfectedbots has no bot-limit cvar, but it stops spawning when `director_no_specials` is 1, so the plugin doesn't touch it. Invasions don't work while a Director is active; Director mode is a separate gamemode (Ethan, 2026-10-18).
- Optional config keys (not in the shipped file; defaults are the CLAUDE.md values): `placement.nav_snap_distance` (100), `placement.visibility_raise` (40), `placement.mob_spread` (150), `limits.max_alive_mobs` (-1), and per-mob `method` `crosshair|panic`, which is the config switch for the panic-event fallback.
