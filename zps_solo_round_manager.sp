#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// Adjust if your server uses different team indices
#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_ZOMBIE    3

bool g_bSoloEnabled = false;

public Plugin myinfo =
{
    name        = "ZPS Solo Mode Manager",
    author      = "ChatGPT",
    description = "Toggles sv_zps_solo based on a single alive human player.",
    version     = "1.1",
    url         = ""
};

public void OnPluginStart()
{
    // ZPS-specific events
    HookEvent("player_connected",    Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_disconnected", Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_spawn",        Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("spawned_player",      Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_feed",         Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("endslate",            Event_PlayerStateChanged, EventHookMode_Post);

    // Generic Source event for team changes
    HookEvent("player_team",         Event_PlayerStateChanged, EventHookMode_Post);

    // Generic death event (extra safety)
    HookEvent("player_death",        Event_PlayerStateChanged, EventHookMode_Post);

    // Safety poll: re-check state 5 times per second
    CreateTimer(0.2, Timer_EvaluateSolo, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// After configs and map cvars are executed, evaluate once.
public void OnConfigsExecuted()
{
    EvaluateSoloMode();
}

// When a client fully enters the game (non-bot)
public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        EvaluateSoloMode();
    }
}

// When a client disconnects
public void OnClientDisconnect(int client)
{
    EvaluateSoloMode();
}

// Any hooked event that may change solo state lands here
public void Event_PlayerStateChanged(Event event, const char[] name, bool dontBroadcast)
{
    // We still recompute from scratch; no incremental state to desync.
    EvaluateSoloMode();
}

// Timer: periodically re-evaluate, so we catch deaths / transitions
// even if the engine updates its state slightly after the event fires.
public Action Timer_EvaluateSolo(Handle timer)
{
    EvaluateSoloMode();
    return Plugin_Continue;
}

// Core logic: decide whether sv_zps_solo should be 1 or 0 and send the command if needed.
static void EvaluateSoloMode()
{
    int realCount        = 0;
    int aliveHumanCount  = 0;

    int maxClients = MaxClients;
    for (int i = 1; i <= maxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;

        if (IsFakeClient(i))
            continue;

        realCount++;

        if (GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
        {
            aliveHumanCount++;
        }
    }

    // Condition from your spec:
    // - exactly 1 real player on the server
    // - that player is human (survivor team) AND alive
    bool shouldEnable = (realCount == 1 && aliveHumanCount == 1);

    if (shouldEnable == g_bSoloEnabled)
    {
        // No state change -> do nothing, avoid spamming the command.
        return;
    }

    g_bSoloEnabled = shouldEnable;

    // Fire the server console command.
    // When true  => sv_zps_solo 1
    // When false => sv_zps_solo 0
    ServerCommand("sv_zps_solo %d", shouldEnable ? 1 : 0);
}
