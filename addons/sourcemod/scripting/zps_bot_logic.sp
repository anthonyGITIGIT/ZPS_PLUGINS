#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define THINK_INTERVAL 0.2
#define WAYPOINT_RECHECK_DISTANCE 64.0
#define ATTACK_RANGE 120.0
#define MOVE_SPEED 220.0

native int Waypoint_GetNearestToPosition(float origin[3]);
native int Waypoint_GetNearestToPlayer(int client);
native bool Waypoint_GetPosition(int wpId, float origin[3]);
native int Waypoint_GetNextOnPath(int fromWpId, int toWpId);

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("Waypoint_GetNearestToPosition");
    MarkNativeAsOptional("Waypoint_GetNearestToPlayer");
    MarkNativeAsOptional("Waypoint_GetPosition");
    MarkNativeAsOptional("Waypoint_GetNextOnPath");
    return APLRes_Success;
}

enum struct BotState
{
    int targetClient;
    int currentWaypoint;
    int nextWaypoint;
    bool usingPath;
    bool lastUsingPath;
    int lastDebugTarget;
}

BotState g_BotState[MAXPLAYERS + 1];
ConVar g_hDebug;
bool g_bWaypointLib = false;

public Plugin myinfo = {
    name = "ZPS Bot Logic",
    author = "ChatGPT",
    description = "Zombie bot movement using waypoint network",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart()
{
    g_hDebug = CreateConVar("zps_bot_debug", "0", "Enable bot debug logging", 0, true, 0.0, true, 1.0);
    CreateTimer(THINK_INTERVAL, Timer_BotThink, _, TIMER_REPEAT);
}

public void OnAllPluginsLoaded()
{
    g_bWaypointLib = LibraryExists("zps_waypoint_logic");
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "zps_waypoint_logic"))
    {
        g_bWaypointLib = true;
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "zps_waypoint_logic"))
    {
        g_bWaypointLib = false;
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        return;
    }
    ResetBotState(client);
}

public void OnClientDisconnect(int client)
{
    ResetBotState(client);
}

void ResetBotState(int client)
{
    g_BotState[client].targetClient = -1;
    g_BotState[client].currentWaypoint = -1;
    g_BotState[client].nextWaypoint = -1;
    g_BotState[client].usingPath = false;
    g_BotState[client].lastUsingPath = false;
    g_BotState[client].lastDebugTarget = -1;
}

public Action Timer_BotThink(Handle timer, any data)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
        {
            continue;
        }

        int target = FindNearestHuman(client);
        if (target == -1)
        {
            ResetBotState(client);
            continue;
        }

        g_BotState[client].targetClient = target;

        if (g_hDebug != null && g_hDebug.IntValue != 0 && g_BotState[client].lastDebugTarget != target)
        {
            LogDebug(client, "Target acquired: %N", target);
        }
        g_BotState[client].lastDebugTarget = target;

        bool hasWaypointSupport = g_bWaypointLib;
        if (hasWaypointSupport)
        {
            TickBotWithWaypoints(client, target);
        }
        else
        {
            bool logChase = (g_BotState[client].lastDebugTarget != target) || g_BotState[client].lastUsingPath;
            DirectChase(client, target, logChase);
        }

        g_BotState[client].lastUsingPath = g_BotState[client].usingPath;
    }

    return Plugin_Continue;
}

void TickBotWithWaypoints(int bot, int target)
{
    float botPos[3];
    GetClientAbsOrigin(bot, botPos);

    int botWp = Waypoint_GetNearestToPlayer(bot);
    int targetWp = Waypoint_GetNearestToPlayer(target);

    if (botWp == -1 || targetWp == -1)
    {
        DirectChase(bot, target, g_BotState[bot].lastUsingPath);
        return;
    }

    g_BotState[bot].currentWaypoint = botWp;

    int next = Waypoint_GetNextOnPath(botWp, targetWp);
    if (next == -1)
    {
        DirectChase(bot, target, g_BotState[bot].lastUsingPath);
        g_BotState[bot].usingPath = false;
        return;
    }

    g_BotState[bot].nextWaypoint = next;
    g_BotState[bot].usingPath = true;

    if (g_hDebug != null && g_hDebug.IntValue != 0 && !g_BotState[bot].lastUsingPath)
    {
        LogDebug(bot, "Pathing toward %N via waypoint %d", target, next);
    }

    float dest[3];
    if (!Waypoint_GetPosition(next, dest))
    {
        DirectChase(bot, target, true);
        return;
    }

    float distance = GetVectorDistance(botPos, dest);
    if (distance < WAYPOINT_RECHECK_DISTANCE)
    {
        // Close enough, move to next segment on next tick
        AttemptAttack(bot, target);
        return;
    }

    MoveBotTowards(bot, dest);
    AttemptAttack(bot, target);
}

void DirectChase(int bot, int target, bool log)
{
    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    MoveBotTowards(bot, targetPos);
    AttemptAttack(bot, target);

    g_BotState[bot].usingPath = false;

    if (log)
    {
        LogDebug(bot, "Direct chasing target %d", target);
    }
}

void MoveBotTowards(int client, const float dest[3])
{
    float pos[3];
    GetClientAbsOrigin(client, pos);

    float dir[3];
    dir[0] = dest[0] - pos[0];
    dir[1] = dest[1] - pos[1];
    dir[2] = dest[2] - pos[2];

    float length = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    if (length > 0.0)
    {
        dir[0] /= length;
        dir[1] /= length;
        dir[2] /= length;
    }

    float angles[3];
    GetVectorAngles(dir, angles);
    angles[0] = 0.0; // keep head level for simplicity

    float velocity[3];
    velocity[0] = dir[0] * MOVE_SPEED;
    velocity[1] = dir[1] * MOVE_SPEED;
    velocity[2] = 0.0;

    TeleportEntity(client, NULL_VECTOR, angles, velocity);
}

void AttemptAttack(int bot, int target)
{
    if (!IsPlayerAlive(target))
    {
        return;
    }
    float botPos[3], targetPos[3];
    GetClientAbsOrigin(bot, botPos);
    GetClientAbsOrigin(target, targetPos);
    float distance = GetVectorDistance(botPos, targetPos);

    if (distance <= ATTACK_RANGE)
    {
        FakeClientCommand(bot, "+attack");
        CreateTimer(0.1, Timer_StopAttack, GetClientUserId(bot));
    }
}

public Action Timer_StopAttack(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client != 0 && IsClientInGame(client))
    {
        FakeClientCommand(client, "-attack");
    }
    return Plugin_Stop;
}

int FindNearestHuman(int bot)
{
    float botPos[3];
    GetClientAbsOrigin(bot, botPos);

    int best = -1;
    float bestDist = -1.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        int team = GetClientTeam(i);
        if (team <= 1)
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float d = GetVectorDistance(botPos, pos);
        if (best == -1 || d < bestDist)
        {
            best = i;
            bestDist = d;
        }
    }
    return best;
}

void LogDebug(int client, const char[] fmt, any ...)
{
    if (g_hDebug == null || g_hDebug.IntValue == 0)
    {
        return;
    }
    char buffer[192];
    VFormat(buffer, sizeof(buffer), fmt, 3);
    PrintToServer("[Bot %d] %s", client, buffer);
}
