# L4D2 Director Mode — Implementation Plan

Phase 1 decisions below are final. Build them as written and don't ask clarifying questions. Stop only for hard blockers, such as a native or cvar that can't be verified. Ethan does all in-game testing.

**This mode will be retuned repeatedly after playtests.** For that reason:

- Every number lives in a config file that reloads without recompiling (see Step 3).
- Keep code mechanics generic. For example, an "item" is defined by config, not hardcoded per type.
- When Ethan asks for a change later, change the config if possible. Change code only when the mechanic itself changes.
- Log every change in `CHANGELOG.md`.

## Goal

One human player is the **Director** in a coop campaign. They fly a free camera and spend points that build up over time. Points buy spawns placed at their crosshair: mobs, special infected, Witches, and Tanks. Placement rules stop cheap kills. The AI Director's spawning is turned off while a human Director is active.

## Scope

**Phase 1 (this build):**
- Plugin `l4d2_director.sp`
- Config file `l4d2_director.cfg`
- Docs

**Out of scope — do NOT build:**
- Director abilities beyond spawning
- Uncommon infected
- Web stats
- Any changes to the invasion plugin

The parking lot at the bottom is for later; ignore it.

## Environment

The server already exists and runs:
- Metamod and SourceMod (stable)
- left4dhooks
- l4dinfectedbots
- `l4d2_invasion` (Ethan's invasion plugin)

Deploy works the same way as the invasion repo: rsync into place, then restart. If `../l4d2-invasion/deploy/deploy_plugin.sh` exists, copy and adapt it.

## Repo layout

```
l4d2-director/
├── CLAUDE.md
├── CHANGELOG.md
├── README.md                 (install, commands, config reference)
├── TESTING.md
├── TUNING.md                 (Ethan's playtest notes, see bottom section)
├── scripting/
│   ├── l4d2_director.sp
│   └── include/              (left4dhooks.inc + deps, same version as server)
├── plugins/
├── configs/
│   └── l4d2_director.cfg     (→ addons/sourcemod/configs/)
├── build.sh
└── deploy/deploy_plugin.sh
```

## Step 1 — Verify before coding

Check each item below against the installed left4dhooks include and the game, then record the exact verified names in `README.md` under "Verified APIs." Names below are best guesses.

| Need | Likely API | Verify |
|---|---|---|
| Spawn a special infected at a position | `L4D2_SpawnSpecial(class, pos, ang)` | Signature and return value (entity/client index) |
| Spawn a Tank | `L4D2_SpawnTank(pos, ang)` | |
| Spawn a Witch | `L4D2_SpawnWitch(pos, ang)` | |
| Nav area at a position | `L4D_GetNearestNavArea` / `L4D2Direct_GetTerrorNavArea` | |
| Map progress ("flow") at a nav area | `L4D2Direct_GetTerrorNavAreaFlow` | |
| A survivor's flow | `L4D2Direct_GetFlowDistance(client)` | |
| Safe-room check | Nav spawn attributes, `NAV_SPAWN_CHECKPOINT` | Flag value and getter name |
| Turn off AI spawning | cvars `director_no_specials`, `director_no_bosses`, `director_no_mobs` | That SourceMod can set them with `sv_cheats 0` |
| Stop l4dinfectedbots from spawning its own bots | its max-specials cvar or data-config value | Exact name. Its bot spawns would otherwise undercut the Director's economy. |

**Mob spawning:** a "mob" is N common infected spawned at the target.
- Create them with `CreateEntityByName("infected")`, then `DispatchSpawn`, then teleport them into a small random cluster around the target point, each snapped to the nav mesh.
- Then make them hunt the survivors right away: fire a `RushVictim`-style VScript (`L4D2_ExecVScriptCode` / `CommandABot`), or use the nearest working method.
- If commons spawned this way stand idle, report it and fall back to `L4D_ForcePanicEvent()` for the mob item. That fallback mob spawns wherever the game decides, not at the crosshair; note this in README Known issues.

## Step 2 — Becoming the Director

- **`sm_director`:** claims the Director role if it's free. One Director at a time.
- **`sm_director_assign <target>`:** admin only (`ADMFLAG_KICK`).
- **`sm_director_quit`:** releases the role.
- On claim:
  - Move the player to spectator team (1).
  - Set free-roam camera: `m_iObserverMode` = 6, with `m_hObserverTarget` = -1.
  - Turn off AI spawning (Step 4).
  - Announce to everyone: `\x04[DIRECTOR]\x01 \x05<name>\x01 is now the Director.`
- Release the role and restore the AI when the Director:
  - disconnects,
  - uses `sm_director_quit`,
  - switches teams, or
  - is AFK: no button input for `afk_seconds` while the role is held.
- A player who is currently an active invader cannot claim Director. Check through a native or forward that `l4d2_invasion` exposes if one exists; otherwise check that the player is on team 3 and refuse.

## Step 3 — Config file (`configs/l4d2_director.cfg`, KeyValues)

- Load the config on plugin start and on `sm_director_reload`, which is admin-only.
- If parsing fails, keep the last good config and print the error to the caller.
- Ship it with exactly these starting values:

```
"l4d2_director"
{
    "economy"
    {
        "start_points"      "50"
        "income_per_sec"    "2"
        "cap"               "300"
        "income_paused_in_finale" "1"
    }
    "placement"
    {
        "min_survivor_distance" "600"   // units from nearest living survivor
        "max_place_distance"    "3000"  // crosshair trace range
        "flow_behind_allowed"   "200"   // may place this far behind lead survivor's flow
        "flow_ahead_max"        "3000"  // and no further than this ahead
        "block_saferoom"        "1"
    }
    "limits"
    {
        "max_alive_specials"    "4"
        "max_alive_tanks"       "1"
        "max_alive_witches"     "2"
    }
    "finale"
    {
        "ai_takes_over"         "1"     // on finale_start: restore AI director, disable Director spending
    }
    "role"
    {
        "afk_seconds"           "90"
    }
    "items"
    {
        "mob"     { "label" "Horde (15)"  "type" "mob"     "count" "15" "cost" "25"  "cooldown" "20"  "allow_visible" "0" }
        "boomer"  { "label" "Boomer"      "type" "special" "class" "2"  "cost" "15"  "cooldown" "8"   "allow_visible" "0" }
        "smoker"  { "label" "Smoker"      "type" "special" "class" "1"  "cost" "20"  "cooldown" "8"   "allow_visible" "0" }
        "hunter"  { "label" "Hunter"      "type" "special" "class" "3"  "cost" "20"  "cooldown" "8"   "allow_visible" "0" }
        "spitter" { "label" "Spitter"     "type" "special" "class" "4"  "cost" "20"  "cooldown" "8"   "allow_visible" "0" }
        "jockey"  { "label" "Jockey"      "type" "special" "class" "5"  "cost" "30"  "cooldown" "10"  "allow_visible" "0" }
        "charger" { "label" "Charger"     "type" "special" "class" "6"  "cost" "30"  "cooldown" "10"  "allow_visible" "0" }
        "witch"   { "label" "Witch"       "type" "witch"                "cost" "60"  "cooldown" "60"  "allow_visible" "1" }
        "tank"    { "label" "Tank"        "type" "tank"                 "cost" "200" "cooldown" "180" "allow_visible" "0" }
    }
}
```

Rules for the items section:
- Items are generic. Their order in the file is their menu order, up to 9.
- `type` is one of `mob`, `special`, `witch`, or `tank`.
- Adding, removing, or repricing an item must need only a config edit and `sm_director_reload`.
- Each item may optionally override the global placement keys `min_survivor_distance`, `flow_behind_allowed`, and `flow_ahead_max`. Item value wins; otherwise the global value applies.

## Step 4 — Turning the AI Director off and on

**When a human Director is active:**
1. Save the current values of `director_no_specials`, `director_no_bosses`, and `director_no_mobs`, then set all three to `1`.
2. Save l4dinfectedbots' bot spawn limit, then set it to 0, using the verified name from Step 1.

**On release (and on plugin unload / map end):** restore the saved values. Restoring must also happen in `OnPluginEnd`.

**Finale:**
- Hook `finale_start`. If `ai_takes_over` is 1, restore the AI and turn off Director spending.
- Show the Director: "Finale — the AI has the wheel."
- Resume Director mode on the next map.

## Step 5 — Economy

- Use a 1-second repeating timer. While a Director is active and a round is in progress (`round_start` … `round_end`), add `income_per_sec`, up to `cap`.
- If the finale is active and `income_paused_in_finale` is 1, add no income.
- Points carry over between maps in the same campaign. Reset them to `start_points` when the Director changes or a new campaign starts (first map of a mission, via left4dhooks' first-map check if available).
- Show the Director a hint every second:
  `Points: 142/300 | Armed: Hunter (20) | Specials alive: 2/4`

## Step 6 — Menu and placement

**Menu:**
- On claim, and on the `sm_dmenu` command, open a SourceMod `Menu`.
- Each row shows the item label, its cost, and its cooldown remaining (or "ready").
- Items the Director can't afford or that are cooling down are shown but disabled (`ITEMDRAW_DISABLED`).
- Selecting an item "arms" it and closes the menu. Re-open the menu after each placement or cancel.

**Placement while armed** (handled in `OnPlayerRunCmd` for the Director):
1. Every 0.1s:
   - Trace a ray from the Director's eye along their view direction, up to `max_place_distance`. Use `TR_TraceRayFilter` with `MASK_SOLID`, ignoring players.
   - Snap the hit point to the nearest nav area.
   - Run validation.
   - Draw a ring at the point, visible only to the Director (`TE_SetupBeamRingPoint` + `TE_SendToClient`): green if valid, red if invalid.
   - If invalid, put the reason in the hint: "Too close to survivors", "In view of survivors", "Behind survivors", "Too far ahead", "Safe room", "No nav", or "Limit reached".
2. `IN_ATTACK` (left click) while valid: spawn the item, deduct its cost, start its cooldown, log the spend, and disarm.
3. `IN_ATTACK2` (right click): disarm and re-open the menu.
4. Debounce button presses so one click produces one spawn.

**Validation:** all of these must pass.
- A nav area exists within 100 units of the point.
- Distance to every living survivor is at least `min_survivor_distance`.
- Visibility, if the item's `allow_visible` is 0: run a trace from each living survivor's eye to the point raised 40 units. If any trace reaches it unobstructed, the spawn is invalid.
- The point's flow is between (lead survivor's flow − `flow_behind_allowed`) and (lead survivor's flow + `flow_ahead_max`).
- If `block_saferoom` is 1, the nav area is not a checkpoint/safe-room area.
- The type's alive count is below its limit. Count only entities this plugin spawned, tracked in an ArrayList and pruned on death.
- The Director has enough points and the item is off cooldown.
- Director spending is not disabled by the finale.

**After spawning:**
- Specials and Tanks are AI-controlled.
- Hook the spawned entity's death to update alive counts.
- Witch: spawn her seated by default.

## Step 7 — Stats and announcements

Track per map:
- points spent per item
- survivor incaps and deaths caused by Director-spawned entities (attacker is in the plugin's spawned-entity list)

At `round_end` and `map_transition`, print to everyone:
`\x04[DIRECTOR]\x01 <name> spent 840 pts: Tank x2, Horde x6, Hunter x4 … | Incaps caused: 7 | Kills: 1`

Log the same line to `addons/sourcemod/logs/l4d2_director.log` so Ethan can compare playtests. No database in Phase 1.

## Step 8 — Commands summary

| Command | Who | Does |
|---|---|---|
| `sm_director` | anyone | claim the role |
| `sm_director_quit` | Director | release the role |
| `sm_dmenu` | Director | open the spawn menu |
| `sm_director_assign <target>` | admin | give the role |
| `sm_director_reload` | admin | reload the config |
| `sm_director_points <n>` | admin | set points (testing) |
| `sm_director_debug` | admin | verbose logging toggle |

## Code quality bar
- Pass userids, not client indexes, through timers.
- Check `IsClientInGame` before every use of a client.
- Zero compiler warnings.
- No item names or numbers hardcoded outside the config loader.
- Saved cvars are always restored: on release, on map end, and in `OnPluginEnd`.

## Build and deploy
- `build.sh` runs `spcomp` with `-i scripting/include`. It must compile clean.
- `deploy_plugin.sh` copies the `.smx` and the `.cfg` into place, restarts the server, and tails the SourceMod error log.

## TESTING.md checklist (write this file)

1. The plugin loads with no errors. `sm_director` claims the role, free camera works, and the announcement shows.
2. After a claim, the AI spawns no specials, mobs, or bosses for 3 minutes of play, and l4dinfectedbots spawns no bots.
3. After `sm_director_quit`, AI spawning returns, and l4dinfectedbots' spawn setting is back to its original value.
4. Points increase by 2/sec, stop at 300, and are shown in the hint.
5. Each placement block shows red with the right reason: too close, in view, behind, too far ahead, safe room.
6. A Witch placed in view of survivors shows green (`allow_visible` 1).
7. Every item spawns at the crosshair and its cost is deducted. The mob attacks immediately; if it stands idle, note it.
8. Cooldowns and alive limits block placement correctly.
9. Changing the hunter's cost in the config and running `sm_director_reload` updates the menu without a restart.
10. At finale start, the AI takes over and spending is turned off. Director mode resumes on the next map.
11. When the Director disconnects mid-map, the AI is restored within 1 second.
12. The round-end spend summary prints and is logged.
13. With `l4d2_invasion` also loaded, an active invader can't claim Director, and the two plugins don't conflict.

## TUNING.md (create with this template; Ethan fills it in)

```
## Playtest YYYY-MM-DD — map, # players, difficulty
- What felt bad:
- What felt good:
- Director spend summary (paste from log):
- Changes to try:
```

When Ethan hands you TUNING.md notes later:
1. Map each note to a config change first.
2. Propose a code change only when no config change can address it.
3. Log what changed and why in CHANGELOG.md.

## Parking lot — do NOT build in Phase 1
- Director abilities: turn lights off, fog, fake horde sounds, lock a door briefly
- Uncommon infected (CEDA, clowns, mudmen) as items
- Income bonuses: when survivors split up, when someone is low health, or when survivors take a long time to advance
- A "rubber band" that discounts items when survivors are doing well
- Director vs. invader synergy: the Director can "summon" an invader
- An SQLite leaderboard of Director results
