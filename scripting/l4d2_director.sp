/**
 * l4d2_director.sp - one human player becomes the Director in a coop campaign.
 *
 * The Director flies a free camera and spends points that build up over time
 * on spawns placed at their crosshair: mobs, special infected, Witches and
 * Tanks. Placement rules stop cheap kills. The AI Director's spawning is
 * turned off while a human Director is active.
 *
 * Every tunable number lives in configs/l4d2_director.cfg and reloads with
 * sm_director_reload. Items are generic: an item is whatever the config says.
 *
 * Requires: Left 4 DHooks Direct.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION      "1.0.0"

#define TEAM_SPECTATOR      1
#define TEAM_SURVIVOR       2
#define TEAM_INFECTED       3

#define OBS_MODE_ROAMING    6

#define CHAT_TAG            "\x04[DIRECTOR]\x01"
#define CONFIG_FILE         "configs/l4d2_director.cfg"
#define LOG_FILE            "logs/l4d2_director.log"

// Menu rows. SourceMod fits 9 items on one unpaginated page with an exit button.
#define MAX_ITEMS           10      // keys 1-9 and 0; the Exit button is dropped at 10

// Placement loop and marker ring. These are UI timing/visuals, not gameplay.
#define PLACE_TICK          0.1
#define RING_LIFE           0.15    // a little over PLACE_TICK so the ring does not flicker
#define RING_RADIUS         40.0
#define RING_WIDTH          3.0
#define ARM_CLICK_GRACE     0.25    // ignore clicks this soon after arming
#define MENU_REOPEN_DELAY   0.2     // delay before the menu comes back after a place/cancel
#define TEAM_SWITCH_GRACE   1.0     // our own team move must not count as "switched teams"
#define REATTACH_GRACE      5.0     // after a map change the game may still assign a team
#define MOB_COMMAND_DELAY   0.1     // let freshly spawned commons finish spawning first

#define BEAM_MATERIAL       "materials/sprites/laserbeam.vmt"
#define HALO_MATERIAL       "materials/sprites/halo01.vmt"

// Item types. Order matches g_sTypeNames.
enum
{
	TYPE_MOB = 0,
	TYPE_SPECIAL,
	TYPE_WITCH,
	TYPE_TANK,
	TYPE_COUNT
}

static const char g_sTypeNames[TYPE_COUNT][] = { "mob", "special", "witch", "tank" };

// The three AI Director cvars this plugin saves, overrides and restores.
enum
{
	AICV_SPECIALS = 0,
	AICV_BOSSES,
	AICV_MOBS,
	AICV_COUNT
}

static const char g_sAICvarNames[AICV_COUNT][] = { "director_no_specials", "director_no_bosses", "director_no_mobs" };

enum struct Item
{
	char key[32];
	char label[64];
	int type;
	int count;              // mob: commons per spawn
	int zclass;             // special: ZombieClass 1..6
	int cost;
	float cooldown;
	bool allowVisible;
	bool panic;             // mob: "method" "panic" uses L4D_ForcePanicEvent instead of crosshair commons
	float duration;         // panic: seconds the AI's mobs are allowed back on
	char group[32];         // optional shared-cooldown group, "" = none
	int hordeSize;          // panic: z_mega_mob_size during the panic, 0 = leave it
	int commonLimit;        // panic: z_common_limit during the panic, 0 = leave it
	float minSurvivorDist;  // < 0 = use the global placement value
	float flowBehind;
	float flowAhead;
}

enum struct Config
{
	int startPoints;
	int incomePerSec;
	int cap;
	bool incomePausedInFinale;

	float minSurvivorDist;
	float maxPlaceDist;
	float flowBehind;
	float flowAhead;
	bool blockSaferoom;
	float navSnapDist;
	float visibleRaise;
	float mobSpread;

	int limit[TYPE_COUNT];  // < 0 = no limit

	bool aiTakesOver;
	int afkSeconds;

	bool crescendoAIMobs;
	float crescendoMax;
}

enum struct Spawned
{
	int ref;
	int type;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
Config g_Cfg;
ArrayList g_Items;          // of Item, in menu order
bool g_bCfgLoaded;

int g_iDirectorUserId;      // 0 = nobody holds the role
char g_sDirectorAuth[64];
char g_sLastAuth[64];       // whoever held the role last; reclaiming keeps their points
bool g_bAwaitingReattach;   // map changed while the role was held
int g_iPoints;

ConVar g_cvAI[AICV_COUNT];
char g_sSavedAI[AICV_COUNT][32];
bool g_bAIOff;
bool g_bMapRunning;

bool g_bRoundLive;
bool g_bFinale;
bool g_bSpendingDisabled;   // finale handed control back to the AI

StringMap g_smCooldownEnd;  // item key -> GetEngineTime() when ready again
StringMap g_smGroupMax;     // group -> buys allowed per window (config)
StringMap g_smGroupWindow;  // group -> window length in seconds (config)
StringMap g_smGroupEnd;     // group -> GetEngineTime() when the current window ends
StringMap g_smGroupCount;   // group -> buys made in the current window

int g_iArmed = -1;          // index into g_Items, -1 = nothing armed
float g_fArmedAt;
float g_fNextPlaceTick;
bool g_bPointValid;
bool g_bHavePoint;
float g_vPoint[3];
char g_sReason[64];
int g_iLastButtons;
float g_fLastInput;
float g_fGraceUntil;
ConVar g_cvMegaMobSize;
ConVar g_cvCommonLimit;
char g_sSavedMegaMob[16];
char g_sSavedCommonLimit[16];
bool g_bPanicSizeSet;
float g_fPanicUntil;         // GetEngineTime() until which director_no_mobs is lifted for a panic
float g_fCrescendoUntil;     // same, for a panic the map started (alarm, generator, gauntlet)
float g_fOwnPanicAt;         // when this plugin last called L4D_ForcePanicEvent
float g_fLastClickAt;        // debounces a click arriving as both a button and a spec_* command

Menu g_hOpenMenu;
char g_sMenuSig[512];

ArrayList g_Spawned;        // of Spawned: everything this plugin put into the world
bool g_bSelfSpawn;          // true while we are inside a spawn native

// Per-map stats
ArrayList g_StatLabels;     // labels in first-spent order
StringMap g_StatCount;      // label -> times bought
int g_iStatSpent;
int g_iStatIncaps;
int g_iStatKills;
char g_sStatName[MAX_NAME_LENGTH];
bool g_bSummaryPrinted;

char g_sLogPath[PLATFORM_MAX_PATH];
bool g_bDebug;
bool g_bLateLoad;           // loaded mid-map: round_start already fired
int g_iBeam;
int g_iHalo;

public Plugin myinfo =
{
	name        = "L4D2 Director Mode",
	author      = "Ethan",
	description = "A human player spends points to spawn infected at their crosshair.",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ---------------------------------------------------------------------------
// Plugin lifecycle
// ---------------------------------------------------------------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "l4d2_director only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	for (int i = 0; i < AICV_COUNT; i++)
	{
		g_cvAI[i] = FindConVar(g_sAICvarNames[i]);
		if (g_cvAI[i] == null)
			SetFailState("Could not find cvar \"%s\".", g_sAICvarNames[i]);
	}
	g_cvMegaMobSize = FindConVar("z_mega_mob_size");
	g_cvCommonLimit = FindConVar("z_common_limit");

	g_Items       = new ArrayList(sizeof(Item));
	g_Spawned     = new ArrayList(sizeof(Spawned));
	g_smCooldownEnd = new StringMap();
	g_smGroupMax    = new StringMap();
	g_smGroupWindow = new StringMap();
	g_smGroupEnd    = new StringMap();
	g_smGroupCount  = new StringMap();
	g_StatLabels  = new ArrayList(ByteCountToCells(64));
	g_StatCount   = new StringMap();

	LoadTranslations("common.phrases");     // FindTarget's error replies
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), LOG_FILE);

	CreateConVar("l4d2_director_version", PLUGIN_VERSION, "L4D2 Director Mode version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegConsoleCmd("sm_director",        Cmd_Director,     "Claim the Director role");
	RegConsoleCmd("sm_director_quit",   Cmd_DirectorQuit, "Release the Director role");
	RegConsoleCmd("sm_dmenu",           Cmd_DMenu,        "Open the Director spawn menu");
	RegAdminCmd("sm_director_assign",   Cmd_Assign,  ADMFLAG_KICK,   "sm_director_assign <target> - give the Director role");
	RegAdminCmd("sm_director_reload",   Cmd_Reload,  ADMFLAG_CONFIG, "Reload configs/l4d2_director.cfg");
	RegAdminCmd("sm_director_points",   Cmd_Points,  ADMFLAG_CHEATS, "sm_director_points <n> - set the Director's points");
	RegAdminCmd("sm_director_debug",    Cmd_Debug,   ADMFLAG_KICK,   "Toggle verbose Director logging");

	// A spectating client turns +attack/+attack2/+jump into these commands
	// instead of sending the buttons, so clicks have to be caught here.
	AddCommandListener(Listener_SpecCmd, "spec_next");
	AddCommandListener(Listener_SpecCmd, "spec_prev");
	AddCommandListener(Listener_SpecCmd, "spec_mode");

	HookEvent("round_start",          Event_RoundStart,   EventHookMode_PostNoCopy);
	HookEvent("round_end",            Event_RoundEnd,     EventHookMode_PostNoCopy);
	HookEvent("map_transition",       Event_MapTransition, EventHookMode_PostNoCopy);
	HookEvent("finale_start",         Event_FinaleStart,  EventHookMode_PostNoCopy);
	HookEvent("player_team",          Event_PlayerTeam);
	HookEvent("player_disconnect",    Event_PlayerDisconnect);
	HookEvent("player_death",         Event_PlayerDeath);
	HookEvent("player_incapacitated", Event_PlayerIncap);
	HookEvent("witch_killed",         Event_WitchKilled);
	HookEvent("create_panic_event",   Event_PanicStart,   EventHookMode_PostNoCopy);
	HookEvent("panic_event_finished", Event_PanicFinished, EventHookMode_PostNoCopy);

	char error[256];
	if (!LoadConfig(error, sizeof(error)))
		LogError("Config not loaded, Director mode is unavailable until sm_director_reload succeeds: %s", error);

	CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
	RestoreAI();
}

public void OnMapStart()
{
	g_iBeam = PrecacheModel(BEAM_MATERIAL, true);
	g_iHalo = PrecacheModel(HALO_MATERIAL, true);

	g_bMapRunning = true;
	// After a mid-map (re)load the round is already in progress. Otherwise
	// leave the flag alone: L4D2 can fire round_start before OnMapStart, and
	// OnMapEnd has already cleared it for the previous map.
	if (g_bLateLoad)
		g_bRoundLive = true;
	g_bLateLoad = false;
	g_bFinale = false;
	g_fPanicUntil = 0.0;
	g_fCrescendoUntil = 0.0;
	g_bSpendingDisabled = false;
	g_Spawned.Clear();
	ResetStats();

	// New campaign: points and cooldowns start over.
	if (L4D_IsFirstMapInScenario())
	{
		g_iPoints = g_Cfg.startPoints;
		g_smCooldownEnd.Clear();
		g_smGroupEnd.Clear();
		g_smGroupCount.Clear();
		DebugLog("First map of a campaign - points reset to %d", g_iPoints);
	}

	if (g_iDirectorUserId != 0)
	{
		g_bAwaitingReattach = true;
		g_fLastInput = GetEngineTime();     // loading time does not count as AFK
	}
}

public void OnConfigsExecuted()
{
	ApplyAIState();
}

public void OnMapEnd()
{
	g_bMapRunning = false;
	g_bRoundLive = false;
	RestoreAI();
	Disarm(false);
	g_Spawned.Clear();
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client) || g_iDirectorUserId == 0 || g_sDirectorAuth[0] == '\0')
		return;

	char auth[64];
	if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false))
		return;

	// The Director came back after a map change. Userids normally survive a
	// changelevel, but bind by SteamID in case they did not.
	if (StrEqual(auth, g_sDirectorAuth))
	{
		g_iDirectorUserId = GetClientUserId(client);
		g_bAwaitingReattach = true;
	}
}

public void OnClientDisconnect(int client)
{
	// Not a role release: this also fires for every client on a map change.
	// Real disconnects are handled by the player_disconnect event.
	UntrackEntity(client);
}

public void OnEntityDestroyed(int entity)
{
	if (g_Spawned == null || g_Spawned.Length == 0)
		return;
	UntrackEntity(entity);
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
bool LoadConfig(char[] error, int maxlen)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

	if (!FileExists(path))
	{
		FormatEx(error, maxlen, "%s not found", path);
		return false;
	}

	KeyValues kv = new KeyValues("l4d2_director");
	if (!kv.ImportFromFile(path))
	{
		FormatEx(error, maxlen, "%s could not be parsed", path);
		delete kv;
		return false;
	}

	Config c;

	kv.JumpToKey("economy");
	c.startPoints          = kv.GetNum("start_points", 50);
	c.incomePerSec         = kv.GetNum("income_per_sec", 2);
	c.cap                  = kv.GetNum("cap", 300);
	c.incomePausedInFinale = kv.GetNum("income_paused_in_finale", 1) != 0;
	kv.Rewind();

	kv.JumpToKey("placement");
	c.minSurvivorDist = kv.GetFloat("min_survivor_distance", 600.0);
	c.maxPlaceDist    = kv.GetFloat("max_place_distance", 3000.0);
	c.flowBehind      = kv.GetFloat("flow_behind_allowed", 200.0);
	c.flowAhead       = kv.GetFloat("flow_ahead_max", 3000.0);
	c.blockSaferoom   = kv.GetNum("block_saferoom", 1) != 0;
	// Optional keys, not in the shipped file. Defaults are the CLAUDE.md values.
	c.navSnapDist     = kv.GetFloat("nav_snap_distance", 100.0);
	c.visibleRaise    = kv.GetFloat("visibility_raise", 40.0);
	c.mobSpread       = kv.GetFloat("mob_spread", 150.0);
	kv.Rewind();

	kv.JumpToKey("limits");
	c.limit[TYPE_MOB]     = kv.GetNum("max_alive_mobs", -1);
	c.limit[TYPE_SPECIAL] = kv.GetNum("max_alive_specials", 4);
	c.limit[TYPE_TANK]    = kv.GetNum("max_alive_tanks", 1);
	c.limit[TYPE_WITCH]   = kv.GetNum("max_alive_witches", 2);
	kv.Rewind();

	kv.JumpToKey("finale");
	c.aiTakesOver = kv.GetNum("ai_takes_over", 1) != 0;
	kv.Rewind();

	kv.JumpToKey("role");
	c.afkSeconds = kv.GetNum("afk_seconds", 90);
	kv.Rewind();

	kv.JumpToKey("crescendo");
	c.crescendoAIMobs = kv.GetNum("ai_mobs", 1) != 0;
	c.crescendoMax    = kv.GetFloat("max_seconds", 300.0);
	kv.Rewind();

	if (c.cap < 0 || c.startPoints < 0 || c.incomePerSec < 0 || c.maxPlaceDist <= 0.0)
	{
		FormatEx(error, maxlen, "economy/placement values must not be negative");
		delete kv;
		return false;
	}

	// Optional shared cooldowns: a group allows max_per_window buys, counted
	// from the first buy, then locks every item in it until the window ends.
	StringMap groupMax = new StringMap();
	StringMap groupWindow = new StringMap();
	char gname[32];
	if (kv.JumpToKey("groups") && kv.GotoFirstSubKey())
	{
		do
		{
			kv.GetSectionName(gname, sizeof(gname));
			int gmax = kv.GetNum("max_per_window", 1);
			float gwin = kv.GetFloat("window", 0.0);
			if (gmax < 1 || gwin <= 0.0)
			{
				FormatEx(error, maxlen, "group \"%s\": needs max_per_window >= 1 and window > 0", gname);
				delete groupMax;
				delete groupWindow;
				delete kv;
				return false;
			}
			groupMax.SetValue(gname, gmax);
			groupWindow.SetValue(gname, gwin);
		}
		while (kv.GotoNextKey());
	}
	kv.Rewind();

	if (!kv.JumpToKey("items") || !kv.GotoFirstSubKey())
	{
		FormatEx(error, maxlen, "no \"items\" section, or it is empty");
		delete groupMax;
		delete groupWindow;
		delete kv;
		return false;
	}

	ArrayList items = new ArrayList(sizeof(Item));
	bool ok = true;
	char buf[32];

	do
	{
		Item it;
		kv.GetSectionName(it.key, sizeof(it.key));
		kv.GetString("label", it.label, sizeof(it.label), it.key);

		kv.GetString("type", buf, sizeof(buf));
		it.type = ParseType(buf);
		if (it.type < 0)
		{
			FormatEx(error, maxlen, "item \"%s\": unknown type \"%s\" (mob, special, witch, tank)", it.key, buf);
			ok = false;
			break;
		}

		it.count  = kv.GetNum("count", 0);
		it.zclass = kv.GetNum("class", 0);
		it.cost   = kv.GetNum("cost", -1);
		it.cooldown     = kv.GetFloat("cooldown", 0.0);
		it.allowVisible = kv.GetNum("allow_visible", 0) != 0;
		it.minSurvivorDist = kv.GetFloat("min_survivor_distance", -1.0);
		it.flowBehind      = kv.GetFloat("flow_behind_allowed", -1.0);
		it.flowAhead       = kv.GetFloat("flow_ahead_max", -1.0);

		it.duration = kv.GetFloat("duration", 30.0);
		kv.GetString("group", it.group, sizeof(it.group), "");
		int unused;
		if (it.group[0] != '\0' && !groupMax.GetValue(it.group, unused))
		{
			FormatEx(error, maxlen, "item \"%s\": group \"%s\" is not defined under \"groups\"", it.key, it.group);
			ok = false;
			break;
		}
		it.hordeSize   = kv.GetNum("horde_size", 0);
		it.commonLimit = kv.GetNum("common_limit", 0);
		kv.GetString("method", buf, sizeof(buf), "crosshair");
		if (StrEqual(buf, "panic"))
			it.panic = true;
		else if (!StrEqual(buf, "crosshair"))
		{
			FormatEx(error, maxlen, "item \"%s\": unknown method \"%s\" (crosshair, panic)", it.key, buf);
			ok = false;
			break;
		}

		if (it.cost < 0)
		{
			FormatEx(error, maxlen, "item \"%s\": missing or negative cost", it.key);
			ok = false;
			break;
		}
		if (it.type == TYPE_MOB && it.count < 1 && !it.panic)
		{
			FormatEx(error, maxlen, "item \"%s\": mob needs \"count\" of at least 1", it.key);
			ok = false;
			break;
		}
		if (it.type == TYPE_SPECIAL && (it.zclass < 1 || it.zclass > 6))
		{
			FormatEx(error, maxlen, "item \"%s\": special needs \"class\" 1-6", it.key);
			ok = false;
			break;
		}
		if (FindItemIn(items, it.key) != -1)
		{
			FormatEx(error, maxlen, "item \"%s\" is listed twice", it.key);
			ok = false;
			break;
		}
		if (items.Length >= MAX_ITEMS)
		{
			FormatEx(error, maxlen, "more than %d items", MAX_ITEMS);
			ok = false;
			break;
		}

		items.PushArray(it);
	}
	while (kv.GotoNextKey());

	delete kv;

	if (!ok)
	{
		delete items;
		delete groupMax;
		delete groupWindow;
		return false;
	}

	// Keep whatever was armed armed, if it still exists under the same key.
	char armedKey[32];
	if (g_iArmed != -1)
	{
		Item old;
		g_Items.GetArray(g_iArmed, old);
		strcopy(armedKey, sizeof(armedKey), old.key);
	}

	g_Cfg = c;
	delete g_Items;
	g_Items = items;
	delete g_smGroupMax;
	delete g_smGroupWindow;
	g_smGroupMax = groupMax;
	g_smGroupWindow = groupWindow;
	g_bCfgLoaded = true;

	if (g_iArmed != -1)
		g_iArmed = FindItemIn(g_Items, armedKey);
	if (g_iPoints > g_Cfg.cap)
		g_iPoints = g_Cfg.cap;

	DebugLog("Config loaded: %d items", g_Items.Length);
	return true;
}

int ParseType(const char[] name)
{
	for (int i = 0; i < TYPE_COUNT; i++)
	{
		if (StrEqual(name, g_sTypeNames[i]))
			return i;
	}
	return -1;
}

int FindItemIn(ArrayList list, const char[] key)
{
	Item it;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, it);
		if (StrEqual(it.key, key))
			return i;
	}
	return -1;
}

float ItemMinDist(const Item it)   { return it.minSurvivorDist >= 0.0 ? it.minSurvivorDist : g_Cfg.minSurvivorDist; }
float ItemFlowBehind(const Item it) { return it.flowBehind >= 0.0 ? it.flowBehind : g_Cfg.flowBehind; }
float ItemFlowAhead(const Item it)  { return it.flowAhead >= 0.0 ? it.flowAhead : g_Cfg.flowAhead; }

// ---------------------------------------------------------------------------
// Role
// ---------------------------------------------------------------------------
int GetDirector()
{
	if (g_iDirectorUserId == 0)
		return 0;
	int client = GetClientOfUserId(g_iDirectorUserId);
	if (client > 0 && IsClientInGame(client))
		return client;
	return 0;
}

bool TryClaim(int client, int replyTo, bool force)
{
	if (!g_bCfgLoaded)
	{
		ReplyToCommand(replyTo, "[DIRECTOR] The config is not loaded. An admin must fix it and run sm_director_reload.");
		return false;
	}
	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;

	int current = GetDirector();
	if (current == client)
	{
		ReplyToCommand(replyTo, "[DIRECTOR] %N is already the Director.", client);
		return false;
	}
	if (g_iDirectorUserId != 0)
	{
		if (!force)
		{
			if (current > 0)
				ReplyToCommand(replyTo, "[DIRECTOR] %N is already the Director.", current);
			else
				ReplyToCommand(replyTo, "[DIRECTOR] The Director role is held by a player who is reconnecting.");
			return false;
		}
		ReleaseDirector("replaced by an admin");
	}

	// l4d2_invasion exposes no native or forward, so an active invader is
	// anyone human on the infected team.
	if (GetClientTeam(client) == TEAM_INFECTED)
	{
		ReplyToCommand(replyTo, "[DIRECTOR] Active invaders can't be the Director.");
		return false;
	}

	char auth[64];
	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false);

	g_iDirectorUserId = GetClientUserId(client);
	strcopy(g_sDirectorAuth, sizeof(g_sDirectorAuth), auth);
	g_bAwaitingReattach = false;

	if (!StrEqual(auth, g_sLastAuth))
	{
		g_iPoints = g_Cfg.startPoints;
		strcopy(g_sLastAuth, sizeof(g_sLastAuth), auth);
	}
	if (g_iStatSpent == 0)
		GetClientName(client, g_sStatName, sizeof(g_sStatName));

	float now = GetEngineTime();
	g_fLastInput = now;
	g_fGraceUntil = now + TEAM_SWITCH_GRACE;
	g_iArmed = -1;

	MoveToFreeCam(client);
	ApplyAIState();

	PrintToChatAll("%s \x05%N\x01 is now the Director.", CHAT_TAG, client);
	LogDirector("CLAIM %N <%s> points=%d", client, auth, g_iPoints);

	OpenItemMenu(client);
	return true;
}

void ReleaseDirector(const char[] reason)
{
	if (g_iDirectorUserId == 0)
		return;

	int client = GetDirector();
	Disarm(false);
	if (client > 0 && g_hOpenMenu != null)
		CancelClientMenu(client);

	g_iDirectorUserId = 0;
	g_sDirectorAuth[0] = '\0';
	g_bAwaitingReattach = false;

	RestoreAI();

	if (client > 0)
	{
		PrintToChatAll("%s \x05%N\x01 is no longer the Director (%s).", CHAT_TAG, client, reason);
		LogDirector("RELEASE %N (%s)", client, reason);
	}
	else
	{
		PrintToChatAll("%s The Director role is free (%s).", CHAT_TAG, reason);
		LogDirector("RELEASE (%s)", reason);
	}
}

void MoveToFreeCam(int client, float grace = TEAM_SWITCH_GRACE)
{
	g_fGraceUntil = GetEngineTime() + grace;
	if (GetClientTeam(client) != TEAM_SPECTATOR)
		ChangeClientTeam(client, TEAM_SPECTATOR);
	CreateTimer(0.1, Timer_SetFreeCam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_SetFreeCam(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && client == GetDirector())
		EnforceFreeCam(client);
	return Plugin_Stop;
}

void EnforceFreeCam(int client)
{
	if (GetClientTeam(client) != TEAM_SPECTATOR)
		return;
	if (GetEntProp(client, Prop_Send, "m_iObserverMode") != OBS_MODE_ROAMING)
		SetEntProp(client, Prop_Send, "m_iObserverMode", OBS_MODE_ROAMING);
	if (GetEntPropEnt(client, Prop_Send, "m_hObserverTarget") != -1)
		SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", -1);
}

void Reattach(int client)
{
	g_bAwaitingReattach = false;
	g_fLastInput = GetEngineTime();
	MoveToFreeCam(client, REATTACH_GRACE);
	ApplyAIState();
	PrintToChat(client, "%s Director mode resumed. Points: %d/%d", CHAT_TAG, g_iPoints, g_Cfg.cap);
	OpenItemMenu(client);
	DebugLog("Reattached %N after map change", client);
}

// ---------------------------------------------------------------------------
// AI Director on/off
// ---------------------------------------------------------------------------
void SetCvarIfDifferent(ConVar cv, const char[] value)
{
	char cur[32];
	cv.GetString(cur, sizeof(cur));
	if (!StrEqual(cur, value))
		cv.SetString(value);
}

// Puts the three cvars where they should be right now. Called whenever any
// input to that decision changes, and once a second so nothing else can
// quietly flip them back.
void ApplyAIState()
{
	bool want = g_iDirectorUserId != 0 && g_bMapRunning && !g_bSpendingDisabled;
	if (!want)
	{
		RestoreAI();
		return;
	}

	if (!g_bAIOff)
	{
		for (int i = 0; i < AICV_COUNT; i++)
			g_cvAI[i].GetString(g_sSavedAI[i], sizeof(g_sSavedAI[]));
		g_bAIOff = true;
		DebugLog("AI off (saved %s=%s %s=%s %s=%s)",
			g_sAICvarNames[0], g_sSavedAI[0], g_sAICvarNames[1], g_sSavedAI[1], g_sAICvarNames[2], g_sSavedAI[2]);
	}

	// director_no_specials 1 also stops l4dinfectedbots: its spawn timer
	// returns early on it, so it has no separate limit to zero.
	for (int i = 0; i < AICV_COUNT; i++)
	{
		if (i == AICV_MOBS && (GetEngineTime() < g_fPanicUntil || GetEngineTime() < g_fCrescendoUntil))
			SetCvarIfDifferent(g_cvAI[i], "0");
		else
			SetCvarIfDifferent(g_cvAI[i], "1");
	}
}

void RestoreAI()
{
	RestorePanicSize();
	if (!g_bAIOff)
		return;
	for (int i = 0; i < AICV_COUNT; i++)
	{
		if (g_cvAI[i] != null)
			SetCvarIfDifferent(g_cvAI[i], g_sSavedAI[i]);
	}
	g_bAIOff = false;
	DebugLog("AI restored");
}

public Action L4D_OnSpawnSpecial(int &zombieClass, const float vecPos[3], const float vecAng[3])
{
	return (g_bAIOff && !g_bSelfSpawn) ? Plugin_Handled : Plugin_Continue;
}

public Action L4D_OnSpawnTank(const float vecPos[3], const float vecAng[3])
{
	return (g_bAIOff && !g_bSelfSpawn) ? Plugin_Handled : Plugin_Continue;
}

public Action L4D_OnSpawnWitch(const float vecPos[3], const float vecAng[3])
{
	return (g_bAIOff && !g_bSelfSpawn) ? Plugin_Handled : Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Once a second: role upkeep, income, hint, menu refresh
// ---------------------------------------------------------------------------
Action Timer_Second(Handle timer)
{
	if (g_iDirectorUserId == 0)
		return Plugin_Continue;

	float now = GetEngineTime();
	int client = GetDirector();

	if (client == 0)
	{
		// Mid-map absence is a disconnect. After a map change, give them
		// afk_seconds to finish loading.
		if (!g_bAwaitingReattach || (g_Cfg.afkSeconds > 0 && now - g_fLastInput >= float(g_Cfg.afkSeconds)))
			ReleaseDirector("left the game");
		return Plugin_Continue;
	}

	if (g_bAwaitingReattach)
		Reattach(client);

	if (g_Cfg.afkSeconds > 0 && now - g_fLastInput >= float(g_Cfg.afkSeconds))
	{
		ReleaseDirector("AFK");
		return Plugin_Continue;
	}

	ApplyAIState();

	if (g_bRoundLive && !(g_bFinale && g_Cfg.incomePausedInFinale) && g_iPoints < g_Cfg.cap)
	{
		g_iPoints += g_Cfg.incomePerSec;
		if (g_iPoints > g_Cfg.cap)
			g_iPoints = g_Cfg.cap;
	}

	ShowHint(client);
	RefreshItemMenu(client);
	return Plugin_Continue;
}

void ShowHint(int client)
{
	char armed[96] = "none";
	if (g_iArmed != -1)
	{
		Item it;
		g_Items.GetArray(g_iArmed, it);
		FormatEx(armed, sizeof(armed), "%s (%d)", it.label, it.cost);
	}

	char extra[96];
	if (g_bSpendingDisabled)
		strcopy(extra, sizeof(extra), "\nFinale — the AI has the wheel.");
	else if (g_iArmed != -1 && !g_bPointValid && g_sReason[0] != '\0')
		FormatEx(extra, sizeof(extra), "\nBlocked: %s", g_sReason);
	else if (g_iArmed == -1)
		strcopy(extra, sizeof(extra), "\nRight click: spawn menu");

	PrintHintText(client, "Points: %d/%d | Armed: %s | Specials alive: %d/%d%s",
		g_iPoints, g_Cfg.cap, armed, CountAlive(TYPE_SPECIAL), g_Cfg.limit[TYPE_SPECIAL], extra);
}

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------
float CooldownLeft(const char[] key)
{
	float ready;
	if (!g_smCooldownEnd.GetValue(key, ready))
		return 0.0;
	float left = ready - GetEngineTime();
	return left > 0.0 ? left : 0.0;
}

// Seconds until the item's group allows another buy; 0 if it already does.
float GroupLeft(const Item it)
{
	if (it.group[0] == '\0')
		return 0.0;
	float end;
	int count, max;
	if (!g_smGroupEnd.GetValue(it.group, end) || !g_smGroupCount.GetValue(it.group, count)
		|| !g_smGroupMax.GetValue(it.group, max))
		return 0.0;
	float left = end - GetEngineTime();
	return (left > 0.0 && count >= max) ? left : 0.0;
}

// The longer of the item's own cooldown and its group lock.
float WaitLeft(const Item it)
{
	float own = CooldownLeft(it.key);
	float group = GroupLeft(it);
	return own > group ? own : group;
}

void RecordGroupBuy(const Item it)
{
	if (it.group[0] == '\0')
		return;
	float now = GetEngineTime();
	float end, window;
	int count;
	if (!g_smGroupEnd.GetValue(it.group, end) || end <= now)
	{
		if (!g_smGroupWindow.GetValue(it.group, window))
			return;
		end = now + window;
		count = 0;
	}
	else
		g_smGroupCount.GetValue(it.group, count);
	g_smGroupEnd.SetValue(it.group, end);
	g_smGroupCount.SetValue(it.group, count + 1);
	DebugLog("Group %s: %d buy(s), window ends in %.0fs", it.group, count + 1, end - now);
}

bool CanBuy(const Item it)
{
	return !g_bSpendingDisabled && g_iPoints >= it.cost && WaitLeft(it) <= 0.0;
}

// Fills one menu row. Returns the draw style.
int BuildRow(const Item it, char[] display, int maxlen)
{
	float left = WaitLeft(it);
	if (left > 0.0)
		FormatEx(display, maxlen, "%s — %d pts — %ds", it.label, it.cost, RoundToCeil(left));
	else
		FormatEx(display, maxlen, "%s — %d pts — ready", it.label, it.cost);
	return CanBuy(it) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
}

void MenuSignature(char[] sig, int maxlen)
{
	sig[0] = '\0';
	char row[128];
	Item it;
	for (int i = 0; i < g_Items.Length; i++)
	{
		g_Items.GetArray(i, it);
		int style = BuildRow(it, row, sizeof(row));
		Format(sig, maxlen, "%s%s%d|", sig, row, style);
	}
	Format(sig, maxlen, "%s%d", sig, g_iPoints);
}

void OpenItemMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Items);
	menu.SetTitle("Director — %d/%d pts", g_iPoints, g_Cfg.cap);

	char row[128];
	Item it;
	for (int i = 0; i < g_Items.Length; i++)
	{
		g_Items.GetArray(i, it);
		int style = BuildRow(it, row, sizeof(row));
		menu.AddItem(it.key, row, style);
	}
	menu.Pagination = MENU_NO_PAGINATION;
	menu.ExitButton = g_Items.Length < MAX_ITEMS;

	MenuSignature(g_sMenuSig, sizeof(g_sMenuSig));
	g_hOpenMenu = menu;     // set before Display: the old menu's End fires during it
	menu.Display(client, MENU_TIME_FOREVER);
}

void RefreshItemMenu(int client)
{
	if (g_hOpenMenu == null || g_iArmed != -1)
		return;
	char sig[sizeof(g_sMenuSig)];
	MenuSignature(sig, sizeof(sig));
	if (!StrEqual(sig, g_sMenuSig))
		OpenItemMenu(client);
}

int MenuHandler_Items(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			int client = param1;
			if (client != GetDirector())
				return 0;
			g_fLastInput = GetEngineTime();

			char key[32];
			menu.GetItem(param2, key, sizeof(key));
			int idx = FindItemIn(g_Items, key);
			if (idx == -1)
				return 0;
			Item it;
			g_Items.GetArray(idx, it);
			if (it.type == TYPE_MOB && it.panic)
				StartPanic(client, it);
			else
				Arm(client, idx);
		}
		case MenuAction_Cancel:
		{
			// The client hides the menu on any number key, even a greyed-out
			// row. Bring it back unless the Director chose Exit.
			int client = param1;
			if (param2 != MenuCancel_Exit && param2 != MenuCancel_Disconnected && param2 != MenuCancel_Interrupted
				&& client == GetDirector() && g_iArmed == -1)
			{
				DebugLog("Menu cancelled (reason %d), reopening", param2);
				CreateTimer(MENU_REOPEN_DELAY, Timer_ReopenMenu, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
			}
		}
		case MenuAction_End:
		{
			if (menu == g_hOpenMenu)
				g_hOpenMenu = null;
			delete menu;
		}
	}
	return 0;
}

// ---------------------------------------------------------------------------
// Arming and placement
// ---------------------------------------------------------------------------
void Arm(int client, int idx)
{
	g_iArmed = idx;
	g_fArmedAt = GetEngineTime();
	g_fNextPlaceTick = 0.0;
	g_bPointValid = false;
	g_bHavePoint = false;
	g_sReason[0] = '\0';

	Item it;
	g_Items.GetArray(idx, it);
	PrintToChat(client, "%s Armed: \x05%s\x01. Left click to place, right click to cancel.", CHAT_TAG, it.label);
	ShowHint(client);
}

void Disarm(bool reopenMenu)
{
	g_iArmed = -1;
	g_bPointValid = false;
	g_bHavePoint = false;
	g_sReason[0] = '\0';

	// Deferred: a menu sent in the same tick as the click's input can be
	// dropped by the client.
	if (reopenMenu && g_iDirectorUserId != 0)
		CreateTimer(MENU_REOPEN_DELAY, Timer_ReopenMenu, g_iDirectorUserId, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ReopenMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && client == GetDirector() && g_iArmed == -1)
	{
		DebugLog("Reopening menu for %N", client);
		OpenItemMenu(client);
	}
	return Plugin_Stop;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (g_iDirectorUserId == 0 || IsFakeClient(client) || GetClientUserId(client) != g_iDirectorUserId)
		return Plugin_Continue;

	float now = GetEngineTime();
	if (buttons != 0 || mouse[0] != 0 || mouse[1] != 0)
		g_fLastInput = now;

	int pressed = buttons & ~g_iLastButtons;
	g_iLastButtons = buttons;

	// In spectator mode attack/attack2/jump cycle observer targets and modes,
	// which would knock the Director out of the free camera.
	Action result = Plugin_Continue;
	if (buttons & (IN_ATTACK | IN_ATTACK2 | IN_JUMP))
	{
		buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_JUMP);
		result = Plugin_Changed;
	}

	if (now >= g_fNextPlaceTick)
	{
		g_fNextPlaceTick = now + PLACE_TICK;
		EnforceFreeCam(client);
		if (g_iArmed != -1)
			UpdatePlacement(client);
	}

	if (pressed & (IN_ATTACK | IN_ATTACK2))
		DebugLog("%N buttons pressed=%d (armed=%d)", client, pressed, g_iArmed);
	if (pressed & IN_ATTACK)
		HandleClick(client, true);
	else if (pressed & IN_ATTACK2)
		HandleClick(client, false);

	return result;
}

Action Listener_SpecCmd(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client) || client != GetDirector())
		return Plugin_Continue;

	g_fLastInput = GetEngineTime();
	DebugLog("%N sent %s (armed=%d)", client, command, g_iArmed);
	if (StrEqual(command, "spec_next"))
		HandleClick(client, true);
	else if (StrEqual(command, "spec_prev"))
		HandleClick(client, false);

	// Never let the Director leave the free camera.
	return Plugin_Handled;
}

// primary = left click (place), otherwise right click (cancel).
void HandleClick(int client, bool primary)
{
	float now = GetEngineTime();
	if (now - g_fLastClickAt < ARM_CLICK_GRACE)
		return;

	// Nothing armed: right click brings the menu back.
	if (g_iArmed == -1)
	{
		if (!primary && g_hOpenMenu == null)
		{
			g_fLastClickAt = now;
			OpenItemMenu(client);
		}
		return;
	}
	if (now - g_fArmedAt < ARM_CLICK_GRACE)
		return;
	g_fLastClickAt = now;
	DebugLog("%N click %s", client, primary ? "place" : "cancel");

	if (primary)
		TryPlace(client);
	else
		Disarm(true);
}

bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return entity == 0 || entity > MaxClients;
}

// Traces the crosshair, snaps to nav and validates. out/reason are always
// written; g_bHavePoint says whether there is a point worth drawing.
bool EvaluatePlacement(int client, const Item it, float out[3], char[] reason, int maxlen)
{
	g_bHavePoint = false;
	reason[0] = '\0';

	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, g_Cfg.maxPlaceDist);
	AddVectors(eye, dir, end);

	TR_TraceRayFilter(eye, end, MASK_SOLID, RayType_EndPoint, TraceFilter_NoPlayers);
	if (!TR_DidHit())
	{
		strcopy(reason, maxlen, "No nav");
		return false;
	}
	TR_GetEndPosition(out);
	g_bHavePoint = true;

	Address area = L4D_GetNearestNavArea(out, g_Cfg.navSnapDist, false, false, false, TEAM_INFECTED);
	if (area == Address_Null)
	{
		strcopy(reason, maxlen, "No nav");
		return false;
	}

	// Keep the exact hit point when it lies on that area; otherwise snap to
	// the area's centre.
	float probe[3];
	probe = out;
	if (L4D2Direct_GetTerrorNavArea(probe) != area)
		L4D_GetNavAreaCenter(area, out);

	if (g_bSpendingDisabled)
	{
		strcopy(reason, maxlen, "Finale — the AI has the wheel");
		return false;
	}

	float minDist = ItemMinDist(it);
	float lead = 0.0;
	bool anySurvivor = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		float pos[3];
		GetClientAbsOrigin(i, pos);
		if (GetVectorDistance(pos, out) < minDist)
		{
			strcopy(reason, maxlen, "Too close to survivors");
			return false;
		}

		float flow = L4D2Direct_GetFlowDistance(i);
		if (!anySurvivor || flow > lead)
			lead = flow;
		anySurvivor = true;
	}
	if (!anySurvivor)
	{
		strcopy(reason, maxlen, "No living survivors");
		return false;
	}

	if (!it.allowVisible && VisibleToSurvivors(out))
	{
		strcopy(reason, maxlen, "In view of survivors");
		return false;
	}

	float pointFlow = L4D2Direct_GetTerrorNavAreaFlow(area);
	if (pointFlow < lead - ItemFlowBehind(it))
	{
		strcopy(reason, maxlen, "Behind survivors");
		return false;
	}
	if (pointFlow > lead + ItemFlowAhead(it))
	{
		strcopy(reason, maxlen, "Too far ahead");
		return false;
	}

	if (g_Cfg.blockSaferoom && IsSaferoom(area, out))
	{
		strcopy(reason, maxlen, "Safe room");
		return false;
	}

	int limit = g_Cfg.limit[it.type];
	if (limit >= 0 && CountAlive(it.type) >= limit)
	{
		strcopy(reason, maxlen, "Limit reached");
		return false;
	}

	if (g_iPoints < it.cost)
	{
		strcopy(reason, maxlen, "Not enough points");
		return false;
	}

	float left = WaitLeft(it);
	if (left > 0.0)
	{
		FormatEx(reason, maxlen, "Cooling down (%ds)", RoundToCeil(left));
		return false;
	}

	return true;
}

bool VisibleToSurvivors(const float point[3])
{
	float target[3];
	target = point;
	target[2] += g_Cfg.visibleRaise;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;

		float eye[3];
		GetClientEyePosition(i, eye);
		TR_TraceRayFilter(eye, target, MASK_VISIBLE, RayType_EndPoint, TraceFilter_NoPlayers);
		if (!TR_DidHit())
			return true;
	}
	return false;
}

bool IsSaferoom(Address area, const float point[3])
{
	if (L4D_GetNavArea_SpawnAttributes(area) & NAV_SPAWN_CHECKPOINT)
		return true;

	float pos[3];
	pos = point;
	return L4D_IsPositionInFirstCheckpoint(pos) || L4D_IsPositionInLastCheckpoint(pos);
}

void UpdatePlacement(int client)
{
	Item it;
	g_Items.GetArray(g_iArmed, it);

	bool wasValid = g_bPointValid;
	char oldReason[64];
	strcopy(oldReason, sizeof(oldReason), g_sReason);

	g_bPointValid = EvaluatePlacement(client, it, g_vPoint, g_sReason, sizeof(g_sReason));

	if (g_bHavePoint)
	{
		float ring[3];
		ring = g_vPoint;
		ring[2] += 5.0;
		int color[4] = { 255, 0, 0, 255 };
		if (g_bPointValid)
		{
			color[0] = 0;
			color[1] = 255;
		}
		TE_SetupBeamRingPoint(ring, RING_RADIUS, RING_RADIUS + 1.0, g_iBeam, g_iHalo, 0, 15, RING_LIFE, RING_WIDTH, 0.0, color, 0, 0);
		TE_SendToClient(client);
	}

	if (wasValid != g_bPointValid || !StrEqual(oldReason, g_sReason))
		ShowHint(client);
}

void TryPlace(int client)
{
	Item it;
	g_Items.GetArray(g_iArmed, it);

	float pos[3];
	char reason[64];
	if (!EvaluatePlacement(client, it, pos, reason, sizeof(reason)))
	{
		g_bPointValid = false;
		strcopy(g_sReason, sizeof(g_sReason), reason);
		ShowHint(client);
		return;
	}

	if (!SpawnItem(it, pos))
	{
		PrintToChat(client, "%s Spawn failed — no points spent.", CHAT_TAG);
		LogDirector("SPAWN FAILED %N item=%s pos=%.0f %.0f %.0f", client, it.key, pos[0], pos[1], pos[2]);
		return;
	}

	g_iPoints -= it.cost;
	if (it.cooldown > 0.0)
		g_smCooldownEnd.SetValue(it.key, GetEngineTime() + it.cooldown);
	RecordGroupBuy(it);
	RecordSpend(client, it);
	LogDirector("SPEND %N item=%s cost=%d points_left=%d pos=%.0f %.0f %.0f",
		client, it.key, it.cost, g_iPoints, pos[0], pos[1], pos[2]);

	Disarm(true);
	ShowHint(client);
}

// ---------------------------------------------------------------------------
// Spawning and tracking
// ---------------------------------------------------------------------------
int NearestSurvivor(const float pos[3], float &dist)
{
	int best = 0;
	float bestDist = -1.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		float p[3];
		GetClientAbsOrigin(i, p);
		float d = GetVectorDistance(p, pos);
		if (bestDist < 0.0 || d < bestDist)
		{
			bestDist = d;
			best = i;
		}
	}
	dist = bestDist;
	return best;
}

void FacingSurvivor(const float pos[3], float ang[3])
{
	ang[0] = 0.0;
	ang[1] = 0.0;
	ang[2] = 0.0;
	float dist;
	int target = NearestSurvivor(pos, dist);
	if (target == 0)
		return;
	float p[3], dir[3];
	GetClientAbsOrigin(target, p);
	SubtractVectors(p, pos, dir);
	GetVectorAngles(dir, ang);
	ang[0] = 0.0;
	ang[2] = 0.0;
}

bool SpawnItem(const Item it, const float pos[3])
{
	float ang[3];
	FacingSurvivor(pos, ang);

	int ent = -1;
	g_bSelfSpawn = true;
	switch (it.type)
	{
		case TYPE_SPECIAL: ent = L4D2_SpawnSpecial(it.zclass, pos, ang);
		case TYPE_TANK:    ent = L4D2_SpawnTank(pos, ang);
		case TYPE_WITCH:   ent = L4D2_SpawnWitch(pos, ang);
		case TYPE_MOB:
		{
			g_bSelfSpawn = false;
			if (it.panic)
			{
				g_fOwnPanicAt = GetEngineTime();
				L4D_ForcePanicEvent();
				return true;
			}
			return SpawnMob(pos, it.count) > 0;
		}
	}
	g_bSelfSpawn = false;

	if (ent <= 0 || !IsValidEntity(ent))
		return false;

	// The spawn natives don't always honour pos (Boomers have landed ~438
	// units under the map), so put the entity where the Director aimed.
	TeleportEntity(ent, pos, ang, view_as<float>({ 0.0, 0.0, 0.0 }));

	TrackEntity(ent, it.type);
	DebugLog("Spawned %s (%s) ent=%d", it.key, g_sTypeNames[it.type], ent);

	if (g_bDebug)
	{
		DataPack pack;
		CreateDataTimer(0.5, Timer_CheckSpawnPos, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(EntIndexToEntRef(ent));
		pack.WriteFloatArray(pos, 3);
	}
	return true;
}

Action Timer_CheckSpawnPos(Handle timer, DataPack pack)
{
	pack.Reset();
	int ent = EntRefToEntIndex(pack.ReadCell());
	float want[3], have[3];
	pack.ReadFloatArray(want, 3);
	if (ent == INVALID_ENT_REFERENCE)
		return Plugin_Stop;
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", have);
	DebugLog("Spawn check ent=%d aimed %.0f %.0f %.0f, now at %.0f %.0f %.0f (%.0f away)",
		ent, want[0], want[1], want[2], have[0], have[1], have[2], GetVectorDistance(want, have));
	return Plugin_Stop;
}

int SpawnMob(const float center[3], int count)
{
	float dist;
	int target = NearestSurvivor(center, dist);

	DataPack pack = new DataPack();
	pack.WriteCell(target > 0 ? GetClientUserId(target) : 0);
	pack.WriteFloat(dist + g_Cfg.mobSpread);
	DataPackPos countPos = pack.Position;
	pack.WriteCell(0);

	float ang[3];
	FacingSurvivor(center, ang);

	int spawned = 0;
	for (int i = 0; i < count; i++)
	{
		float p[3];
		float theta = GetRandomFloat(0.0, 6.2831853);
		float r = GetRandomFloat(0.0, g_Cfg.mobSpread);
		p[0] = center[0] + r * Cosine(theta);
		p[1] = center[1] + r * Sine(theta);
		p[2] = center[2];

		// Snap each common to the nav mesh; fall back to the target point.
		Address area = L4D_GetNearestNavArea(p, g_Cfg.navSnapDist, false, false, false, TEAM_INFECTED);
		if (area == Address_Null || L4D2Direct_GetTerrorNavArea(p) != area)
			p = center;

		int ent = CreateEntityByName("infected");
		if (ent == -1)
			continue;
		DispatchSpawn(ent);
		TeleportEntity(ent, p, ang, NULL_VECTOR);

		TrackEntity(ent, TYPE_MOB);
		pack.WriteCell(EntIndexToEntRef(ent));
		spawned++;
	}

	pack.Position = countPos;
	pack.WriteCell(spawned);

	if (spawned > 0)
		CreateTimer(MOB_COMMAND_DELAY, Timer_MobAttack, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
	else
		delete pack;

	DebugLog("Mob: %d/%d commons spawned", spawned, count);
	return spawned;
}

// Send the fresh commons straight at the nearest survivor.
Action Timer_MobAttack(Handle timer, DataPack pack)
{
	pack.Reset();
	int target = GetClientOfUserId(pack.ReadCell());
	float range = pack.ReadFloat();
	int count = pack.ReadCell();

	if (target == 0 || !IsClientInGame(target) || !IsPlayerAlive(target))
	{
		float dist;
		target = NearestSurvivor(g_vPoint, dist);
	}
	if (target == 0)
		return Plugin_Stop;

	int commanded = 0, failed = 0;
	for (int i = 0; i < count; i++)
	{
		int ent = EntRefToEntIndex(pack.ReadCell());
		if (ent == INVALID_ENT_REFERENCE)
			continue;
		if (L4D2_CommandABot(ent, target, BOT_CMD_ATTACK))
			commanded++;
		else
			failed++;
	}

	// If CommandABot refused any common, make everything near the victim rush.
	if (failed > 0)
		L4D2_RushVictim(target, range);

	DebugLog("Mob attack: %d commanded, %d failed (RushVictim %s)", commanded, failed, failed > 0 ? "used" : "not needed");
	return Plugin_Stop;
}

void TrackEntity(int entity, int type)
{
	Spawned s;
	s.ref = EntIndexToEntRef(entity);
	s.type = type;
	g_Spawned.PushArray(s);
}

void UntrackEntity(int entity)
{
	if (entity < 0)
		entity = EntRefToEntIndex(entity);
	if (entity <= 0)
		return;

	Spawned s;
	for (int i = g_Spawned.Length - 1; i >= 0; i--)
	{
		g_Spawned.GetArray(i, s);
		if (EntRefToEntIndex(s.ref) == entity)
			g_Spawned.Erase(i);
	}
}

bool IsTracked(int entity)
{
	if (entity <= 0)
		return false;
	Spawned s;
	for (int i = 0; i < g_Spawned.Length; i++)
	{
		g_Spawned.GetArray(i, s);
		if (EntRefToEntIndex(s.ref) == entity)
			return true;
	}
	return false;
}

int CountAlive(int type)
{
	int n = 0;
	Spawned s;
	for (int i = g_Spawned.Length - 1; i >= 0; i--)
	{
		g_Spawned.GetArray(i, s);
		int ent = EntRefToEntIndex(s.ref);
		if (ent == INVALID_ENT_REFERENCE || (ent <= MaxClients && (!IsClientInGame(ent) || !IsPlayerAlive(ent))))
		{
			g_Spawned.Erase(i);
			continue;
		}
		if (s.type == type)
			n++;
	}
	return n;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundLive = true;
	g_fCrescendoUntil = 0.0;
	g_bFinale = false;
	g_bSummaryPrinted = false;
	g_Spawned.Clear();

	// A restarted finale map plays the lead-up again under the Director.
	if (g_bSpendingDisabled)
	{
		g_bSpendingDisabled = false;
		ApplyAIState();
	}
}

// A panic the map started (car alarm, generator, gauntlet) lets the AI's
// hordes back on until the game says it is over, or crescendo max_seconds
// as a backstop for scripts that never finish. The Director's own Panic
// Horde fires the same event and is skipped.
void Event_PanicStart(Event event, const char[] name, bool dontBroadcast)
{
	float now = GetEngineTime();
	if (!g_Cfg.crescendoAIMobs || now - g_fOwnPanicAt < 1.0 || g_iDirectorUserId == 0)
		return;
	g_fCrescendoUntil = now + g_Cfg.crescendoMax;
	ApplyAIState();
	CreateTimer(g_Cfg.crescendoMax, Timer_CrescendoEnd, _, TIMER_FLAG_NO_MAPCHANGE);
	LogDirector("CRESCENDO started - AI hordes on");
}

void Event_PanicFinished(Event event, const char[] name, bool dontBroadcast)
{
	if (g_fCrescendoUntil <= 0.0)
		return;
	g_fCrescendoUntil = 0.0;
	ApplyAIState();
	LogDirector("CRESCENDO finished - AI hordes off");
}

Action Timer_CrescendoEnd(Handle timer)
{
	if (g_fCrescendoUntil > 0.0 && GetEngineTime() >= g_fCrescendoUntil)
	{
		g_fCrescendoUntil = 0.0;
		ApplyAIState();
		LogDirector("CRESCENDO timed out - AI hordes off");
	}
	return Plugin_Stop;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_fCrescendoUntil = 0.0;
	g_bRoundLive = false;
	Disarm(false);
	PrintSummary();
}

void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	PrintSummary();
}

void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bFinale = true;
	if (!g_Cfg.aiTakesOver)
		return;

	g_bSpendingDisabled = true;
	RestoreAI();
	LogDirector("FINALE AI takes over");

	int client = GetDirector();
	if (client > 0)
	{
		Disarm(false);
		PrintToChat(client, "%s Finale — the AI has the wheel.", CHAT_TAG);
		ShowHint(client);
		if (g_hOpenMenu != null)
			OpenItemMenu(client);
	}
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetBool("disconnect") || g_iDirectorUserId == 0)
		return;
	if (event.GetInt("userid") != g_iDirectorUserId)
		return;
	if (event.GetInt("team") == TEAM_SPECTATOR)
		return;
	if (g_bAwaitingReattach || GetEngineTime() < g_fGraceUntil)
	{
		// The game, not the player, moved them (map change). Put them back.
		CreateTimer(0.2, Timer_BackToSpectator, g_iDirectorUserId, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	ReleaseDirector("switched teams");
}

Action Timer_BackToSpectator(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && client == GetDirector() && !g_bAwaitingReattach
		&& GetClientTeam(client) != TEAM_SPECTATOR)
	{
		MoveToFreeCam(client);
	}
	return Plugin_Stop;
}

void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iDirectorUserId != 0 && event.GetInt("userid") == g_iDirectorUserId)
		ReleaseDirector("disconnected");
}

bool AttackerIsDirectorSpawn(Event event)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker > 0 && IsTracked(attacker))
		return true;
	int ent = event.GetInt("attackerentid");
	return ent > MaxClients && IsTracked(ent);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim == 0 || !IsClientInGame(victim))
		return;

	if (GetClientTeam(victim) == TEAM_SURVIVOR)
	{
		if (AttackerIsDirectorSpawn(event))
			g_iStatKills++;
	}
	else
	{
		UntrackEntity(victim);
	}
}

void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim > 0 && IsClientInGame(victim) && GetClientTeam(victim) == TEAM_SURVIVOR && AttackerIsDirectorSpawn(event))
		g_iStatIncaps++;
}

void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	UntrackEntity(event.GetInt("witchid"));
}

// ---------------------------------------------------------------------------
// Stats and logging
// ---------------------------------------------------------------------------
void ResetStats()
{
	g_StatLabels.Clear();
	g_StatCount.Clear();
	g_iStatSpent = 0;
	g_iStatIncaps = 0;
	g_iStatKills = 0;
	g_bSummaryPrinted = false;
	int client = GetDirector();
	if (client > 0)
		GetClientName(client, g_sStatName, sizeof(g_sStatName));
	else
		g_sStatName[0] = '\0';
}

// A panic item fires on selection: the game picks where the horde comes from,
// so there is nothing to place. The AI's mobs are let back on for the item's
// duration so the panic waves can spawn, then switched off again.
void StartPanic(int client, const Item it)
{
	if (!CanBuy(it))
	{
		CreateTimer(MENU_REOPEN_DELAY, Timer_ReopenMenu, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	float now = GetEngineTime();
	g_fPanicUntil = now + it.duration;
	ApplyAIState();
	SetPanicSize(it);
	g_fOwnPanicAt = now;
	L4D_ForcePanicEvent();
	CreateTimer(it.duration, Timer_PanicEnd, _, TIMER_FLAG_NO_MAPCHANGE);

	g_iPoints -= it.cost;
	if (it.cooldown > 0.0)
		g_smCooldownEnd.SetValue(it.key, now + it.cooldown);
	RecordGroupBuy(it);
	RecordSpend(client, it);
	LogDirector("SPEND %N item=%s cost=%d points_left=%d panic=%.0fs", client, it.key, it.cost, g_iPoints, it.duration);
	PrintToChat(client, "%s \x05%s\x01 started (%.0fs).", CHAT_TAG, it.label, it.duration);

	ShowHint(client);
	CreateTimer(MENU_REOPEN_DELAY, Timer_ReopenMenu, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_PanicEnd(Handle timer)
{
	if (GetEngineTime() >= g_fPanicUntil)
	{
		DebugLog("Panic window over");
		RestorePanicSize();
		ApplyAIState();
	}
	return Plugin_Stop;
}

// Panic waves are sized by z_mega_mob_size and capped by z_common_limit.
// Both are raised only for the panic window, then put back.
void SetPanicSize(const Item it)
{
	if (!g_bPanicSizeSet)
	{
		if (g_cvMegaMobSize != null)
			g_cvMegaMobSize.GetString(g_sSavedMegaMob, sizeof(g_sSavedMegaMob));
		if (g_cvCommonLimit != null)
			g_cvCommonLimit.GetString(g_sSavedCommonLimit, sizeof(g_sSavedCommonLimit));
		g_bPanicSizeSet = true;
	}

	char buf[16];
	if (it.hordeSize > 0 && g_cvMegaMobSize != null)
	{
		IntToString(it.hordeSize, buf, sizeof(buf));
		SetCvarIfDifferent(g_cvMegaMobSize, buf);
	}
	if (it.commonLimit > 0 && g_cvCommonLimit != null)
	{
		IntToString(it.commonLimit, buf, sizeof(buf));
		SetCvarIfDifferent(g_cvCommonLimit, buf);
	}
	DebugLog("Panic size: z_mega_mob_size=%d z_common_limit=%d",
		g_cvMegaMobSize != null ? g_cvMegaMobSize.IntValue : -1, g_cvCommonLimit != null ? g_cvCommonLimit.IntValue : -1);
}

void RestorePanicSize()
{
	if (!g_bPanicSizeSet)
		return;
	if (g_cvMegaMobSize != null)
		SetCvarIfDifferent(g_cvMegaMobSize, g_sSavedMegaMob);
	if (g_cvCommonLimit != null)
		SetCvarIfDifferent(g_cvCommonLimit, g_sSavedCommonLimit);
	g_bPanicSizeSet = false;
	DebugLog("Panic size restored");
}

void RecordSpend(int client, const Item it)
{
	int n;
	if (!g_StatCount.GetValue(it.label, n))
	{
		n = 0;
		g_StatLabels.PushString(it.label);
	}
	g_StatCount.SetValue(it.label, n + 1);
	g_iStatSpent += it.cost;
	GetClientName(client, g_sStatName, sizeof(g_sStatName));
}

void PrintSummary()
{
	if (g_bSummaryPrinted)
		return;
	if (g_iStatSpent == 0 && g_iDirectorUserId == 0)
		return;
	g_bSummaryPrinted = true;

	char parts[384], label[64];
	for (int i = 0; i < g_StatLabels.Length; i++)
	{
		g_StatLabels.GetString(i, label, sizeof(label));
		int n;
		g_StatCount.GetValue(label, n);
		Format(parts, sizeof(parts), "%s%s%s x%d", parts, i > 0 ? ", " : "", label, n);
	}
	if (parts[0] == '\0')
		strcopy(parts, sizeof(parts), "nothing");

	char name[MAX_NAME_LENGTH];
	strcopy(name, sizeof(name), g_sStatName);
	if (name[0] == '\0')
		strcopy(name, sizeof(name), "The Director");

	char line[512];
	FormatEx(line, sizeof(line), "%s %s spent %d pts: %s | Incaps caused: %d | Kills: %d",
		CHAT_TAG, name, g_iStatSpent, parts, g_iStatIncaps, g_iStatKills);
	PrintToChatAll("%s", line);

	char map[64];
	GetCurrentMap(map, sizeof(map));
	StripColors(line);
	LogDirector("SUMMARY map=%s %s", map, line);
}

void StripColors(char[] text)
{
	int j = 0;
	for (int i = 0; text[i] != '\0'; i++)
	{
		if (text[i] > 0x08)
			text[j++] = text[i];
	}
	text[j] = '\0';
}

void LogDirector(const char[] format, any ...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogToFileEx(g_sLogPath, "%s", buffer);
}

void DebugLog(const char[] format, any ...)
{
	if (!g_bDebug)
		return;
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogToFileEx(g_sLogPath, "[debug] %s", buffer);
	PrintToServer("[DIRECTOR debug] %s", buffer);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------
Action Cmd_Director(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[DIRECTOR] In-game only. Use sm_director_assign from the console.");
		return Plugin_Handled;
	}
	TryClaim(client, client, false);
	return Plugin_Handled;
}

Action Cmd_DirectorQuit(int client, int args)
{
	if (client == 0 || client != GetDirector())
	{
		ReplyToCommand(client, "[DIRECTOR] You are not the Director.");
		return Plugin_Handled;
	}
	ReleaseDirector("quit");
	return Plugin_Handled;
}

Action Cmd_DMenu(int client, int args)
{
	if (client == 0 || client != GetDirector())
	{
		ReplyToCommand(client, "[DIRECTOR] You are not the Director.");
		return Plugin_Handled;
	}
	Disarm(false);
	OpenItemMenu(client);
	return Plugin_Handled;
}

Action Cmd_Assign(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[DIRECTOR] Usage: sm_director_assign <target>");
		return Plugin_Handled;
	}
	char arg[MAX_NAME_LENGTH];
	GetCmdArg(1, arg, sizeof(arg));
	int target = FindTarget(client, arg, true, false);
	if (target == -1)
		return Plugin_Handled;
	if (TryClaim(target, client, true))
		ReplyToCommand(client, "[DIRECTOR] %N is now the Director.", target);
	return Plugin_Handled;
}

Action Cmd_Reload(int client, int args)
{
	char error[256];
	if (LoadConfig(error, sizeof(error)))
	{
		ReplyToCommand(client, "[DIRECTOR] Config reloaded: %d items.", g_Items.Length);
		LogDirector("RELOAD ok (%d items)", g_Items.Length);
		int director = GetDirector();
		if (director > 0 && g_hOpenMenu != null)
			OpenItemMenu(director);
	}
	else
	{
		ReplyToCommand(client, "[DIRECTOR] Reload failed, keeping the last good config: %s", error);
		LogDirector("RELOAD failed: %s", error);
	}
	return Plugin_Handled;
}

Action Cmd_Points(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[DIRECTOR] Points: %d/%d. Usage: sm_director_points <n>", g_iPoints, g_Cfg.cap);
		return Plugin_Handled;
	}
	int n = GetCmdArgInt(1);
	if (n < 0)
		n = 0;
	g_iPoints = n;
	ReplyToCommand(client, "[DIRECTOR] Points set to %d.", g_iPoints);
	return Plugin_Handled;
}

Action Cmd_Debug(int client, int args)
{
	g_bDebug = !g_bDebug;
	ReplyToCommand(client, "[DIRECTOR] Debug logging %s.", g_bDebug ? "on" : "off");
	return Plugin_Handled;
}
