# TESTING

In-game checklist. Run it with `sm_director_debug` on, and keep `addons/sourcemod/logs/l4d2_director.log` open.

Useful console checks: `director_no_specials`, `director_no_bosses`, `director_no_mobs` (type the name alone to see the value), `sm_config` (l4dinfectedbots' current settings, root only), `sm plugins list`.

1. **Load and claim.**
   - The plugin loads with no errors (`sm plugins list`, error log).
   - `sm_director` claims the role, and the free camera works: you can fly, and clicking doesn't jump to a player.
   - Everyone sees `[DIRECTOR] <name> is now the Director.`
2. **AI off.**
   - After a claim, all three `director_no_*` cvars read 1.
   - Play 3 minutes: the AI spawns no specials, hordes or bosses, and l4dinfectedbots spawns no bots. The server console shows `[TS] Couldn't spawn due to director_no_specials 1.`
3. **AI back.**
   - After `sm_director_quit`, the three cvars return to their pre-claim values and AI spawning returns.
   - l4dinfectedbots' spawn setting is unchanged: this plugin never touches it (README, *l4dinfectedbots*). Confirm its bots appear again.
4. **Income.** Points rise by 2/sec, stop at 300, and show in the hint: `Points: x/300 | Armed: … | Specials alive: n/4`.
5. **Placement blocks.** Each shows a red ring with the right reason:
   - Too close to survivors (< 600 units)
   - In view of survivors
   - Behind survivors (more than 200 flow behind the lead)
   - Too far ahead (more than 3000 flow ahead)
   - Safe room (inside the start or end saferoom)
6. **Witch in view.** A Witch placed in plain view of survivors shows green (`allow_visible` 1).
7. **Every item spawns.**
   - Each one spawns at the crosshair, and its cost is deducted.
   - The horde attacks immediately. **If it stands idle, note it.** Then set `"method" "panic"` on the mob item and `sm_director_reload`.
   - Note whether the Witch sits or wanders on this map.
8. **Cooldowns and limits.**
   - Re-buying during a cooldown is blocked (the menu row is greyed out; the hint says "Cooling down").
   - Spawn 4 specials and the 5th shows "Limit reached". Kill one and placement is allowed again.
   - Same for a 2nd Tank and a 3rd Witch.
9. **Live reload.** Change the hunter's `cost` in the server's `configs/l4d2_director.cfg`, then run `sm_director_reload`. The open menu shows the new price without a restart. Break the file on purpose (delete a `}`): the reload reports the error and the old prices stay.
10. **Finale.**
    - At finale start, the Director sees "Finale — the AI has the wheel.", all menu rows are greyed out, and the cvars are restored.
    - On the next map, Director mode resumes on its own: the camera, menu and AI-off state come back.
11. **Disconnect.** When the Director disconnects mid-map, the three cvars are restored within 1 second, and chat says the role is free.
12. **Summary.** At round end or map transition, everyone sees `[DIRECTOR] <name> spent N pts: … | Incaps caused: n | Kills: n`, and the same line appears in `l4d2_director.log` as `SUMMARY map=…`.
13. **Invader refused.** With `l4d2_invasion` loaded, a human on the infected team running `sm_director` gets "Active invaders can't be the Director." Invasions are not expected to work while a Director is active; that's by design.
14. **Crescendos get hordes.** With a Director active, trigger a car alarm (c1m2) or the mall alarm (c1m3). AI hordes come in waves as in normal coop, `l4d2_director.log` shows `CRESCENDO started`, then `CRESCENDO finished` once the event ends, and normal hordes stop again.

Also worth checking:
- Switching the Director to survivors via the team menu releases the role.
- Going AFK for 90 s releases it.
- A normal map change does **not** release it.
