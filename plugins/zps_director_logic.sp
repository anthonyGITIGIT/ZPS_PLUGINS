/**
 * zps_director_logic.sp
 *
 * Very basic director plugin for Zombie Panic! Source.
 *
 * Current feature set:
 * - Simple debug command to spawn a custom zombie bot using base-game
 *   zombie spawn logic (info_player_zombie).
 * - Registers spawned bots with bot_logic.sp.
 *
 * Command:
 *   sm_zps_spawnbot [count]
 *     - Admin-only (ADMFLAG_CHEATS)
 *     - Spawns 1 or more zombie bots (default 1).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// ---------------------------------------------------------------------------
// Team constants (ZPS uses 2 = Survivor, 3 = Zombie in practice)
// ---------------------------------------------------------------------------

#define TEAM_UNASSIGNED 0
#define TEAM_SPECTATOR  1
#define TEAM_SURVIVOR   2
#define TEAM_ZOMBIE     3

// ---------------------------------------------------------------------------
// bot_logic API (natives we consume)
// ---------------------------------------------------------------------------

native bool BotLogic_IsCustomBot(int client);
native bool BotLogic_RegisterBot(int client);
native bool BotLogic_UnregisterBot(int client);
native bool BotLogic_SetBotTargetWaypoint(int client, int waypointId);
native bool BotLogic_SetBotTargetPlayer(int client, int targetClient);
native bool BotLogic_ClearBotTarget(int client);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

bool g_bManagedBot[MAXPLAYERS + 1];
int  g_iNextBotId = 1;
bool g_bBotLogicAvailable = false;

static void RefreshBotLogicAvailability()
{
    g_bBotLogicAvailable = (GetFeatureStatus(FeatureType_Native, "BotLogic_RegisterBot") == FeatureStatus_Available);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool IsValidClientIndex(int client)
{
    return (client >= 1 && client <= MaxClients);
}

static bool IsClientReady(int client)
{
    return IsValidClientIndex(client) && IsClientInGame(client);
}

/**
 * Safely call BotLogic_RegisterBot only if the native is available.
 */
static bool SafeRegisterBotLogic(int client)
{
    RefreshBotLogicAvailability();

    if (!g_bBotLogicAvailable)
    {
        return false;
    }

    return BotLogic_RegisterBot(client);
}

/**
 * Safely call BotLogic_UnregisterBot only if the native is available.
 */
static void SafeUnregisterBotLogic(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "BotLogic_UnregisterBot") != FeatureStatus_Available)
    {
        return;
    }

    BotLogic_UnregisterBot(client);
}

// ---------------------------------------------------------------------------
// Debug bot spawner
// ---------------------------------------------------------------------------

/**
 * Core: spawn one zombie bot and register it with bot_logic.
 * Uses base game spawn system (info_player_zombie) by:
 *  - Creating a fake client.
 *  - Putting it on the zombie team.
 *  - Calling DispatchSpawn so the game uses zombie spawn entities.
 */
static bool SpawnOneZombieBot()
{
    char name[32];
    Format(name, sizeof(name), "ZPS_Bot_%d", g_iNextBotId);
    g_iNextBotId++;

    int bot = CreateFakeClient(name);
    if (bot == 0)
    {
        PrintToServer("[Director] CreateFakeClient failed, cannot spawn bot.");
        return false;
    }

    // Put the fake client on zombie team.
    ChangeClientTeam(bot, TEAM_ZOMBIE);

    // Let the game spawn it at a zombie spawn (info_player_zombie).
    DispatchSpawn(bot);

    // Register with bot_logic, if available.
    bool registered = SafeRegisterBotLogic(bot);
    g_bManagedBot[bot] = registered;

    if (!registered)
    {
        PrintToServer("[Director] Warning: bot_logic not available or registration failed for bot %d.", bot);
    }
    else
    {
        PrintToServer("[Director] Spawned and registered zombie bot: #%d (client %d).", g_iNextBotId - 1, bot);
    }

    return true;
}

/**
 * Admin command: sm_zps_spawnbot [count]
 * Spawns one or more zombie bots.
 */
public Action Cmd_SpawnDebugBot(int client, int args)
{
    int count = 1;

    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        count = StringToInt(arg);
        if (count <= 0)
        {
            count = 1;
        }
        if (count > 16)
        {
            count = 16; // simple hard limit
        }
    }

    int spawned = 0;
    for (int i = 0; i < count; i++)
    {
        if (SpawnOneZombieBot())
        {
            spawned++;
        }
    }

    if (client != 0)
    {
        ReplyToCommand(client, "[Director] Requested %d bot(s), spawned %d.", count, spawned);
    }
    else
    {
        PrintToServer("[Director] Requested %d bot(s), spawned %d.", count, spawned);
    }

    return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("director_logic");

    // Mark bot_logic natives as optional so this plugin can still load
    // even if bot_logic is not present yet.
    MarkNativeAsOptional("BotLogic_IsCustomBot");
    MarkNativeAsOptional("BotLogic_RegisterBot");
    MarkNativeAsOptional("BotLogic_UnregisterBot");
    MarkNativeAsOptional("BotLogic_SetBotTargetWaypoint");
    MarkNativeAsOptional("BotLogic_SetBotTargetPlayer");
    MarkNativeAsOptional("BotLogic_ClearBotTarget");

    return APLRes_Success;
}

public void OnPluginStart()
{
    // Admin-only debug command to spawn zombie bots.
    RegAdminCmd("sm_zps_spawnbot", Cmd_SpawnDebugBot, ADMFLAG_CHEATS,
        "Spawn one or more debug zombie bots using base game zombie spawn entities.");

    RefreshBotLogicAvailability();

    // Clear state
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bManagedBot[i] = false;
    }
    g_iNextBotId = 1;
}

public void OnMapStart()
{
    // Reset only the ID counter; bots will be recreated per map anyway.
    g_iNextBotId = 1;
}

public void OnClientDisconnect(int client)
{
    if (!IsValidClientIndex(client))
    {
        return;
    }

    if (g_bManagedBot[client])
    {
        SafeUnregisterBotLogic(client);
        g_bManagedBot[client] = false;
    }
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "bot_logic"))
    {
        RefreshBotLogicAvailability();

        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_bManagedBot[i])
            {
                SafeRegisterBotLogic(i);
            }
        }
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "bot_logic"))
    {
        g_bBotLogicAvailable = false;
    }
}

// ---------------------------------------------------------------------------
// Plugin info
// ---------------------------------------------------------------------------

public Plugin myinfo =
{
    name        = "ZPS Director Logic (Basic)",
    author      = "ChatGPT (director framework)",
    description = "Very basic director with debug zombie bot spawner for ZPS",
    version     = "0.1.0",
    url         = ""
};
