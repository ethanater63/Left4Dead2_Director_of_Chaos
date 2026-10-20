# L4D2 Director Mode

This is my attempt at making YOU the director. Invite your friends for a night of fun where one of you is in control of spawning the infected! It's total chaos, have fun! FYI this is vibe coded, but thoroughly playtested. There may be bugs, I will update when possible, thank you for supporting!

One human player is the **Director** in a coop campaign. They fly a free camera and spend points that build up over time. Points buy spawns placed at their crosshair: hordes, special infected, Witches and Tanks. Placement rules stop cheap kills. While a human Director is active, the AI Director's spawning is off.

Phase 1 build. Every number is in `configs/l4d2_director.cfg`, which reloads with `sm_director_reload` and needs no recompile.

## Install

Requirements on the server, which are already there: Metamod, SourceMod 1.12 (stable), Left 4 DHooks Direct, l4dinfectedbots. Director mode is a separate gamemode from `l4d2_invasion`. The two can be loaded together, but invasions don't work while a Director is active (see *Verified APIs → l4dinfectedbots*).

```bash
./build.sh                    # compiles plugins/l4d2_director.smx (fails on any warning)
./deploy/deploy_plugin.sh     # copies .smx + .cfg, restarts l4d2, tails the error log
```

| Repo file | Server destination |
|---|---|
| `plugins/l4d2_director.smx` | `addons/sourcemod/plugins/` |
| `configs/l4d2_director.cfg` | `addons/sourcemod/configs/` |

`build.sh` looks for spcomp 1.12.0-git7253 in four places, in order: `$SPCOMP`, this repo's `build/`, the invasion repo's `build/` next to this one, and a fresh download.

### Where it runs

Director mode has its own server, separate from the invasion server:

| | Director | Invasion |
|---|---|---|
| Proxmox CT | **107 `l4d2-director`** | 103 `l4d2` |
| LAN address | **192.168.1.55:27016** | 192.168.1.52:27015 |
| From the internet | **`<public-ip>:27016`** | `<public-ip>:27015` |
| ssh (deploy) | `l4d2-director-deploy` (steam) | `l4d2-deploy` (steam) |
| ssh (root) | `l4d2-director` | `l4d2` |

- **How CT 107 was made (2026-10-18):** a full clone of CT 103 with new SSH host keys, machine-id, MAC and IP. `l4d2_invasion.smx` was moved to `plugins/disabled/`. The server name was changed to "L4D2 Director Mode | Coop vs a Human Director"; the original is kept as `cfg/server.cfg.invasion.bak`.
- **Everything else is as cloned,** including the rcon password, admins, l4dinfectedbots and left4dhooks 1.169.
- **Port:** the Director server runs on **27016** (`-port 27016` in `/etc/systemd/system/l4d2.service` on CT 107). Both servers share one public IP, so the router forwards UDP+TCP 27016 → 192.168.1.55 and 27015 → 192.168.1.52.
- **Deploy settings:** `deploy_plugin.sh` reads `L4D2_HOST` (default `l4d2-director-deploy`) and `L4D2_PATH` (default `/home/steam/l4d2/left4dead2`).

Logs go to `addons/sourcemod/logs/l4d2_director.log`: claims, releases, every spend, failed spawns, reloads and the per-round summary.

## Commands

| Command | Who | Flag | Does |
|---|---|---|---|
| `sm_director` | anyone | — | Claim the role if it's free |
| `sm_director_quit` | Director | — | Release the role |
| `sm_dmenu` | Director | — | Open the spawn menu (disarms first) |
| `sm_director_assign <target>` | admin | `ADMFLAG_KICK` (c) | Give the role; replaces the current Director |
| `sm_director_reload` | admin | `ADMFLAG_CONFIG` (i) | Reload the config; on failure keeps the last good one and prints why |
| `sm_director_points <n>` | admin | `ADMFLAG_CHEATS` (n) | Set points (testing). Not clamped to `cap`; income just stops at the cap. |
| `sm_director_debug` | admin | `ADMFLAG_KICK` (c) | Toggle verbose logging to the log file and server console |

**Playing as the Director:**
- Pick an item from the menu with the number keys. That arms it.
- A ring follows your crosshair: green means valid, red means blocked. The reason shows in the hint box.
- **Left click** places the item. **Right click** cancels and reopens the menu.
- While you're the Director, attack, attack2 and jump are swallowed so they don't knock you out of the free camera.

## Config reference (`configs/l4d2_director.cfg`)

KeyValues. Missing keys fall back to the values shown.

### `economy`
| Key | Default | Meaning |
|---|---|---|
| `start_points` | 50 | Points on claim (new Director) and at the start of a campaign |
| `income_per_sec` | 2 | Added every second while a round is live (`round_start`…`round_end`) |
| `cap` | 300 | Income stops here |
| `income_paused_in_finale` | 1 | No income after `finale_start` |

### `placement`
| Key | Default | Meaning |
|---|---|---|
| `min_survivor_distance` | 600 | Minimum distance from every living survivor |
| `max_place_distance` | 3000 | Crosshair trace range |
| `flow_behind_allowed` | 200 | May place up to this far behind the lead survivor's flow |
| `flow_ahead_max` | 3000 | …and no further than this ahead |
| `block_saferoom` | 1 | Refuse checkpoint/safe-room nav areas |
| `nav_snap_distance` | 100 | *Optional, not in the shipped file.* Nav area must be within this distance of the crosshair point |
| `visibility_raise` | 40 | *Optional.* The visibility trace aims this far above the point |
| `mob_spread` | 150 | *Optional.* Radius of the common-infected cluster |

### `limits`
Only entities this plugin spawned count toward these limits.
| Key | Default |
|---|---|
| `max_alive_specials` | 4 |
| `max_alive_tanks` | 1 |
| `max_alive_witches` | 2 |
| `max_alive_mobs` | -1 (*optional*; counts live commons; -1 = no limit) |

### `finale`
| Key | Default | Meaning |
|---|---|---|
| `ai_takes_over` | 1 | On `finale_start`: restore the AI Director and turn off Director spending. The Director sees "Finale — the AI has the wheel." Director mode resumes on the next map, or when the round restarts after a wipe. |
| `allow_types` | special | Item types the Director can still buy after the AI takes the finale, space-separated (`mob special witch tank`). Empty = nothing. A Panic Horde counts as `mob`. Income still follows `income_paused_in_finale`. |

### `role`
| Key | Default | Meaning |
|---|---|---|
| `afk_seconds` | 90 | Release the role after this many seconds with no button or mouse input. The same window is the grace period for the Director to reconnect after a map change. 0 = never. |

### `crescendo`
How the AI's hordes are held back while a human Director is active, without breaking map events.

| Key | Default | Meaning |
|---|---|---|
| `block_natural_by_timer` | 1 | **1:** `director_no_mobs` is left alone. Only the random horde timer is pushed out: the eight `z_mob_spawn_{min,max}_interval_{easy,normal,hard,expert}` cvars are set to `natural_horde_interval`, then `L4D_ResetMobTimer`. Car alarms, panic buttons, `ScriptedPanicEvent` minifinales and `BeginScript` onslaughts (the c2m2 carousel, the c2m3 coaster, the c1m3 mall) keep their hordes on every campaign, because they don't use that timer. **0:** the old behaviour. `director_no_mobs 1` blocks every AI horde, with the `ai_mobs` exception. |
| `natural_horde_interval` | 99999 | Seconds the random horde timer is set to while a Director is active. On release, the saved values come back and the timer is reset. |
| `ai_mobs` | 1 | Mode 0 only: a `create_panic_event` from the map lifts `director_no_mobs` until `panic_event_finished`. Onslaught scripts don't fire that event. |
| `max_seconds` | 300 | Mode 0 only: backstop for `ai_mobs`. |

### `groups` (optional)

Shared cooldowns. Each subsection is a group name; items join a group with `"group" "<name>"`.

| Key | Default | Meaning |
|---|---|---|
| `max_per_window` | 1 | Buys allowed per window. |
| `window` | — | Window length in seconds. It starts at the group's first buy; once `max_per_window` buys are made, every item in the group is locked until it ends. |

An item's own `cooldown` still applies on top of this. The menu and hint show whichever wait is longer.

### `items`
- Each subsection is one item. File order is menu order, up to 10 items (keys 1-9 and 0; with 10 items the Exit row is dropped).
- Adding, removing or repricing an item takes only a config edit and `sm_director_reload`.

| Key | Required for | Meaning |
|---|---|---|
| `label` | all | Menu text (defaults to the section name) |
| `type` | all | `mob`, `special`, `witch` or `tank` |
| `cost` | all | Points |
| `cooldown` | — | Seconds before it can be bought again (default 0) |
| `allow_visible` | — | 1 = may be placed in survivors' line of sight |
| `count` | mob | Commons spawned |
| `class` | special | 1 Smoker, 2 Boomer, 3 Hunter, 4 Spitter, 5 Jockey, 6 Charger |
| `group` | — | *Optional.* Name of a group under `groups`; the item shares that group's cooldown. |
| `method` | — | *Optional, mob only.* `crosshair` (default) or `panic`. `panic` calls `L4D_ForcePanicEvent()`; the game picks where the horde spawns. |
| `duration` | 30 | *Panic only.* A panic item fires as soon as it's picked, with no placement. `director_no_mobs` goes to 0 for this many seconds so the panic waves can spawn, then back to 1. The AI may add its own mobs during that window. |
| `horde_size` | 0 | *Panic only.* `z_mega_mob_size` during the panic window (the size of a panic wave). 0 leaves the server's value. Restored afterwards. |
| `common_limit` | 0 | *Panic only.* `z_common_limit` during the panic window (the most commons alive at once; the server default is 30). 0 leaves the server's value. Restored afterwards. |
| `min_survivor_distance`, `flow_behind_allowed`, `flow_ahead_max` | — | Per-item overrides of the global placement values |

Cooldowns are tracked by item key, so they survive a reload. If you rename a key, its cooldown resets.

## How it works

- **Claim:**
  - The player moves to spectator with `m_iObserverMode` 6 (roaming) and `m_hObserverTarget` -1. The mode is re-enforced every 0.1 s.
  - The AI is switched off and the claim is announced.
  - Points reset to `start_points`, unless the same SteamID was the last Director.
- **Release:**
  - Happens on `sm_director_quit`, on a real disconnect (the `player_disconnect` event, which fires immediately), on a switch to another team, or after `afk_seconds` without input.
  - The AI is restored immediately.
  - Map changes do not release the role. The Director is re-bound by SteamID when they load in, moved back to the free camera, and the menu reopens.
- **Placement (every 0.1 s while armed):**
  1. Trace from the eye along the view (`MASK_SOLID`, players ignored).
  2. Find the nearest nav area within `nav_snap_distance`. The exact hit point is kept if it lies on that area; otherwise the area centre is used.
  3. Validate, in this order: no nav → finale lock → too close → in view → behind → too far ahead → safe room → limit reached → not enough points → cooling down.
  4. Left click re-validates at click time before spawning.
- **Spawns:**
  - Specials, Tanks and Witches use the left4dhooks spawn natives and face the nearest survivor.
  - A mob is `count` × `CreateEntityByName("infected")` + `DispatchSpawn` + teleport into a cluster, each snapped to the nav mesh. 0.1 s later each common gets `L4D2_CommandABot(common, nearestSurvivor, BOT_CMD_ATTACK)`. If any command is refused, `L4D2_RushVictim` runs as a fallback.
  - If a spawn native returns nothing, no points are spent and the Director is told.
- **Stats:**
  - Per map: points spent per item label, plus survivor incaps and deaths whose attacker (`attacker` userid or `attackerentid`) is in the spawned-entity list.
  - Printed and logged once per round, at `map_transition` or `round_end`, whichever comes first.

## Verified APIs

These were checked against `scripting/include/left4dhooks.inc`, copied from the invasion repo (1.168 includes; the server runs 1.169), and against the l4dinfectedbots and spawn_infected_nolimit sources on master, fetched 2026-10-18. **Nothing has been tested in-game yet.**

| Need | Verified name | Notes |
|---|---|---|
| Spawn special | `int L4D2_SpawnSpecial(int zombieClass, const float vecPos[3], const float vecAng[3])` | Returns the entity (client) index. Class 1–6. |
| Spawn Tank | `int L4D2_SpawnTank(const float vecPos[3], const float vecAng[3])` | Returns the entity index |
| Spawn Witch | `int L4D2_SpawnWitch(const float vecPos[3], const float vecAng[3])` | Returns the entity index |
| Nav area at a position | `any L4D_GetNearestNavArea(const float vecPos[3], float maxDist = 300.0, bool anyZ = false, bool checkLOS = false, bool checkGround = false, int teamID = 2)` | Used for the "within 100 units" check. `Address L4D2Direct_GetTerrorNavArea(float pos[3], float beneathLimit = 120.0)` is used only to test whether the hit point lies on that area. `L4D_GetNavAreaCenter(Address, float[3])` is the snap fallback. |
| Flow at a nav area | `float L4D2Direct_GetTerrorNavAreaFlow(Address pTerrorNavArea)` | |
| Survivor flow | `float L4D2Direct_GetFlowDistance(int client)` | The lead is the maximum over living survivors |
| Safe room | `int L4D_GetNavArea_SpawnAttributes(Address)` & `NAV_SPAWN_CHECKPOINT` (= 2048, 1<<11) | Backed up by `L4D_IsPositionInFirstCheckpoint` / `L4D_IsPositionInLastCheckpoint` |
| AI spawning off | `director_no_specials`, `director_no_bosses`, `director_no_mobs` | Set through `ConVar.SetString`. SourceMod writes the value directly, so `FCVAR_CHEAT` doesn't block it with `sv_cheats 0`. **Confirm in-game** (TESTING #2). |
| Block AI spawns that slip through (belt and braces) | forwards `L4D_OnSpawnSpecial`, `L4D_OnSpawnTank`, `L4D_OnSpawnWitch` → `Plugin_Handled` while the AI is off | The plugin's own spawns are let through by a re-entrancy flag |
| Mob attack | `bool L4D2_CommandABot(int entity, int target, BOT_CMD type, float vecPos[3] = NULL_VECTOR)` with `BOT_CMD_ATTACK`; fallback `void L4D2_RushVictim(int client, float range)` | Docs say CommandABot accepts common infected |
| Panic fallback | `L4D_ForcePanicEvent()` (stock in `left4dhooks_silver.inc`) | Subject to the horde cooldown timer |
| First map of a campaign | `bool L4D_IsFirstMapInScenario()` | Checked in `OnMapStart` |
| l4d2_invasion "is invader" | **No native or forward exists.** `l4d2_invasion.sp` has no `CreateNative` or `CreateGlobalForward`, and `IsInvader()` is internal. | Fallback: refuse anyone human on team 3 |

### l4dinfectedbots: no bot-limit cvar, so `director_no_specials` covers it

CLAUDE.md Step 1 asked for l4dinfectedbots' "max-specials cvar or data-config value". From reading its source:

- **There is no cvar.** The limit is `max_specials` in `data/l4dinfectedbots/<mode>.cfg`. The runtime override is `sm_zlimit <n>`, but it requires `ADMFLAG_ROOT` and refuses the server console, so a plugin can't call it cleanly.
- **It doesn't need one.** l4dinfectedbots stops spawning when `director_no_specials` is 1: `Timer_Spawn_InfectedBot` returns early with `"[TS] Couldn't spawn due to director_no_specials 1."`

So Step 4.2 is covered by Step 4.1, and this plugin never touches l4dinfectedbots' settings.

Side effect: the same early return also stops l4dinfectedbots respawning human infected players. Director mode is its own gamemode and isn't meant to run alongside invasions, so this is accepted.

All three cvars are set to 1 while a Director is active. They're re-checked every second and restored on release, at map end, at the finale handover and in `OnPluginEnd`.

## Known issues / unverified

- **Mob idle risk.** If the commons stand idle in testing, set `"method" "panic"` on the mob item and run `sm_director_reload`. The panic fallback spawns wherever the game decides, not at the crosshair.
- **Witch posture.** `L4D2_SpawnWitch` lets the game decide. Witches sit on night maps but wander on daytime maps, and there's no clean property to force a seated Witch.
- **`director_no_specials` vs our own SI spawns.** `L4D2_SpawnSpecial` calls `ZombieManager::SpawnSpecial` directly and should ignore the cvar. If specials fail to spawn in testing, the Director gets "Spawn failed — no points spent." and the log has a `SPAWN FAILED` line.
- **Scripted bosses are blocked too.** While the AI is off, non-finale map-scripted Tanks and Witches are stopped (`director_no_bosses` plus the forwards). With `ai_takes_over 0`, finale Tanks are blocked as well, which may stall some finales.
- **Timer mode assumes** map onslaught scripts restart the horde timer with their own timing (`Director.ResetMobTimer()`). The official scripts are encrypted, so this was checked live on the c2m3 coaster. If an onslaught stays empty, set `block_natural_by_timer 0` to get the old behaviour back.
- **Wandering commons** still spawn. `director_no_mobs` only stops hordes.
- **Visibility** means line of sight from any living survivor's eye, regardless of which way they face. That's stricter than real field of view.
- **Swamp Fever and similar events.** Some crescendos are flagged as finales by Valve. `finale_start` may fire there, which hands control to the AI for the rest of that round.
- **Stats** accumulate per map across wipes. The summary after a wipe includes earlier attempts on that map.
- **The map-change reattach** assumes the Director reconnects within `afk_seconds`. Otherwise the role is released ("left the game").

## License

**GPLv3.** See [LICENSE](LICENSE) for the full text.

This repo redistributes GPLv3 code (the Left 4 DHooks includes), so the whole work is GPLv3. Take it, fork it, run it, change it, and ship your own version. The one condition is that derivatives stay GPLv3 and keep their source available.

### Third-party components

| Component | In this repo? | License |
|---|---|---|
| `scripting/l4d2_director.sp`, `configs/`, scripts and docs | yes, our code | GPLv3 |
| `scripting/include/left4dhooks*.inc` (5 files) | yes, vendored | GPLv3 ([Left4DHooks](https://github.com/SilvDev/Left4DHooks) ships a verbatim GPLv3 `LICENSE`) |
| Left 4 DHooks Direct plugin and extension | no, installed on the server | GPLv3 |
| l4dinfectedbots | no, installed on the server | see [L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins) |
| Metamod:Source, SourceMod | no, installed on the server | their own terms |
