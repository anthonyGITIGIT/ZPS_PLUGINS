/**

zps_bot_logic.sp

Core brain and movement logic for custom Zombie Panic! Source zombie bots.

Only controls zombie bots (fake clients).

Movement is driven by simulating "holding W" and applying forward movement.

If there is a clear line of sight to the target player, bots run straight at them.

If line of sight is blocked and waypoints are available, bots path through the waypoint web

toward the player's nearest waypoint, and as soon as LOS is restored they drop the path and

resume direct chasing.
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#define BOTLOGIC_MAX_PATH_NODES 32
#define BOTLOGIC_THINK_INTERVAL 0.20
#define BOTLOGIC_TARGET_RADIUS 50.0
#define BOTLOGIC_DOORWAY_RADIUS 15.0
#define BOTLOGIC_DOORWAY_SPEED_SCALE 0.70
#define BOTLOGIC_FORWARD_SPEED 250.0

#define BOTLOGIC_STUCK_DIST_SQ 25.0 // ~5 units in XY
#define BOTLOGIC_STUCK_TIME 1.0 // seconds before we consider the bot stuck
#define BOTLOGIC_BOUNCE_DURATION 0.5 // seconds to keep jump/crouch bounce active
#define BOTLOGIC_BACKOFF_DURATION 0.35 // seconds to move backward before bouncing
#define BOTLOGIC_BOUNCE_COOLDOWN 1.5 // seconds between bounce attempts

#define BOTLOGIC_PATH_CACHE_DURATION 2.0
#define BOTLOGIC_PATH_RETRY_COOLDOWN 0.5

#define BOTLOGIC_RETARGET_COOLDOWN 1.0

#define BOTLOGIC_AUTO_ACQUIRE_RANGE 2000.0

// ---------------------------------------------------------------------------
// Waypoint natives (provided by zps_waypoint_logic)
// ---------------------------------------------------------------------------

native int Waypoint_FindNearestToClient(int client);
native int Waypoint_GetPath(int startId, int endId, int[] buffer, int maxSize);
native bool Waypoint_GetOrigin(int id, float pos[3]);
native bool Waypoint_IsDoorway(int id);

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum BotState
{
BotState_Idle = 0,
BotState_MovingPath,
BotState_ChasingPlayer,
BotState_Regrouping
};

enum BotTargetType
{
BotTarget_None = 0,
BotTarget_Waypoint,
BotTarget_Player,
BotTarget_Position
};

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

bool g_bIsCustomBot[MAXPLAYERS + 1];

BotState g_BotState[MAXPLAYERS + 1];
BotTargetType g_BotTargetType[MAXPLAYERS + 1];

int g_BotTargetWaypoint[MAXPLAYERS + 1];
int g_BotTargetPlayer[MAXPLAYERS + 1];
float g_BotTargetPos[MAXPLAYERS + 1][3];

int g_BotPath[MAXPLAYERS + 1][BOTLOGIC_MAX_PATH_NODES];
int g_BotPathLength[MAXPLAYERS + 1];
int g_BotPathIndex[MAXPLAYERS + 1];

int g_BotCachedPath[MAXPLAYERS + 1][BOTLOGIC_MAX_PATH_NODES];
int g_BotCachedPathLength[MAXPLAYERS + 1];
float g_BotCachedPathTime[MAXPLAYERS + 1];
float g_BotNextPathRebuild[MAXPLAYERS + 1];

float g_BotMoveDir[MAXPLAYERS + 1][3];
float g_BotLastThink[MAXPLAYERS + 1];
float g_BotSpeedScale[MAXPLAYERS + 1];

float g_BotLastPos[MAXPLAYERS + 1][3];
float g_BotStuckAccum[MAXPLAYERS + 1];
float g_BotBackoffDir[MAXPLAYERS + 1][3];
float g_BotBackoffUntil[MAXPLAYERS + 1];
float g_BotBounceStart[MAXPLAYERS + 1];
float g_BotBounceEnd[MAXPLAYERS + 1];
float g_BotBounceCooldownUntil[MAXPLAYERS + 1];

float g_BotNextRetargetTime[MAXPLAYERS + 1];

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

static bool IsClientReady(int client)
{
return (client >= 1 && client <= MaxClients && IsClientInGame(client));
}

static void ZeroVector(float vec[3])
{
vec[0] = 0.0;
vec[1] = 0.0;
vec[2] = 0.0;
}

static void CopyVector(const float src[3], float dest[3])
{
dest[0] = src[0];
dest[1] = src[1];
dest[2] = src[2];
}

static float GetDistanceSquared2D(const float a[3], const float b[3])
{
float dx = a[0] - b[0];
float dy = a[1] - b[1];
return dx * dx + dy * dy;
}

static bool ComputeDirectionToPosition(int client, const float targetPos[3], float dirOut[3], float &distOut)
{
float origin[3];
GetClientAbsOrigin(client, origin);

float dx = targetPos[0] - origin[0];
float dy = targetPos[1] - origin[1];
float dz = targetPos[2] - origin[2];

float distSq = dx * dx + dy * dy + dz * dz;
if (distSq <= 0.0)
{
    ZeroVector(dirOut);
    distOut = 0.0;
    return false;
}

float invDist = 1.0 / SquareRoot(distSq);
dirOut[0] = dx * invDist;
dirOut[1] = dy * invDist;
dirOut[2] = dz * invDist;

distOut = SquareRoot(distSq);
return true;


}

static void YawFromDirection(const float dir[3], float &yawOut)
{
yawOut = RadToDeg(ArcTangent2(dir[1], dir[0]));
}

// ---------------------------------------------------------------------------
// Line-of-sight helpers
// ---------------------------------------------------------------------------

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask, any data)
{
if (entity >= 1 && entity <= MaxClients)
{
return false; // ignore players
}
return true;
}

/**

Returns true if there are no solid/movement obstacles between bot and target player.

Step 1: cheap eye ray (visual LOS).

Step 2: player-sized hull trace (movement LOS).
*/
static bool HasClearLineToTarget(int bot, int target)
{
if (!IsClientReady(bot) || !IsClientReady(target))
{
return false;
}

// Step 1: eye-level ray
float botEye[3], targetEye[3];
GetClientEyePosition(bot, botEye);
GetClientEyePosition(target, targetEye);

Handle ray = TR_TraceRayFilterEx(botEye, targetEye, MASK_SOLID, RayType_EndPoint, TraceFilter_IgnorePlayers, 0);
bool blocked = TR_DidHit(ray);
CloseHandle(ray);

if (blocked)
{
return false;
}

// Step 2: hull trace approximating the player collision box
float botPos[3], targetPos[3];
GetClientAbsOrigin(bot, botPos);
GetClientAbsOrigin(target, targetPos);

float mins[3] = { -16.0, -16.0, 0.0 };
float maxs[3] = { 16.0, 16.0, 64.0 };

Handle hullTrace = TR_TraceHullFilterEx(botPos, targetPos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_IgnorePlayers, 0);
bool hullBlocked = TR_DidHit(hullTrace);
CloseHandle(hullTrace);

return !hullBlocked;
}

// ---------------------------------------------------------------------------
// Waypoint helpers
// ---------------------------------------------------------------------------

/**

Build a waypoint path from the client's nearest waypoint to the given endId.
*/
static bool BuildPathToWaypoint(int client, int endId)
{
int startId = Waypoint_FindNearestToClient(client);
if (startId < 0 || endId < 0)
{
return false;
}

int tempPath[BOTLOGIC_MAX_PATH_NODES];
int pathLen = Waypoint_GetPath(startId, endId, tempPath, BOTLOGIC_MAX_PATH_NODES);
if (pathLen <= 0)
{
return false;
}

g_BotPathLength[client] = pathLen;
g_BotPathIndex[client] = 0;

    for (int i = 0; i < pathLen; i++)
    {
        g_BotPath[client][i] = tempPath[i];
    }

    float now = GetGameTime();
    g_BotCachedPathLength[client] = pathLen;
    g_BotCachedPathTime[client]   = now;
    for (int i = 0; i < pathLen; i++)
    {
        g_BotCachedPath[client][i] = tempPath[i];
    }

    g_BotNextPathRebuild[client] = now + BOTLOGIC_PATH_RETRY_COOLDOWN;

    return true;
}

// ---------------------------------------------------------------------------
// Core bot state helpers
// ---------------------------------------------------------------------------

static void ClearBotState(int client)
{
    g_BotState[client] = BotState_Idle;
    g_BotTargetType[client] = BotTarget_None;
    g_BotTargetWaypoint[client] = -1;
    g_BotTargetPlayer[client] = 0;
    ZeroVector(g_BotTargetPos[client]);
    g_BotPathLength[client] = 0;
    g_BotPathIndex[client] = 0;
    g_BotCachedPathLength[client] = 0;
    g_BotCachedPathTime[client] = 0.0;
    g_BotNextPathRebuild[client] = 0.0;
    ZeroVector(g_BotMoveDir[client]);
    g_BotSpeedScale[client] = 1.0;
    ZeroVector(g_BotBackoffDir[client]);
    g_BotBackoffUntil[client] = 0.0;
    g_BotBounceStart[client] = 0.0;
    g_BotBounceEnd[client] = 0.0;
    g_BotBounceCooldownUntil[client] = 0.0;
    g_BotNextRetargetTime[client] = 0.0;
}

static void AutoAcquireTarget(int client, float now)
{
    float myPos[3];
    GetClientAbsOrigin(client, myPos);

    float bestDistSq = BOTLOGIC_AUTO_ACQUIRE_RANGE * BOTLOGIC_AUTO_ACQUIRE_RANGE;
    int   bestTarget = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientReady(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        if (GetClientTeam(i) == GetClientTeam(client))
        {
            continue;
        }

        float otherPos[3];
        GetClientAbsOrigin(i, otherPos);

        float distSq = GetDistanceSquared2D(myPos, otherPos);
        if (distSq < bestDistSq)
        {
            bestDistSq = distSq;
            bestTarget = i;
        }
    }

    if (bestTarget != 0)
    {
        g_BotTargetType[client]   = BotTarget_Player;
        g_BotTargetPlayer[client] = bestTarget;
        g_BotPathLength[client]   = 0;
        g_BotPathIndex[client]    = 0;
        g_BotState[client]        = BotState_ChasingPlayer;
        g_BotNextRetargetTime[client] = now + BOTLOGIC_RETARGET_COOLDOWN;
    }
}

// ---------------------------------------------------------------------------
// Target-specific think functions
// ---------------------------------------------------------------------------

static void ThinkPlayerTarget(int client, float now)
{
    int target = g_BotTargetPlayer[client];

    if (!IsClientReady(target) || !IsPlayerAlive(target))
    {
        if (now >= g_BotNextRetargetTime[client])
        {
            AutoAcquireTarget(client, now);
        }
        else
        {
            ClearBotState(client);
        }
        return;
    }

    // Prefer direct chase if we have a truly walkable LOS path.
    if (HasClearLineToTarget(client, target))
    {
        g_BotPathLength[client] = 0;
        g_BotPathIndex[client]  = 0;

        float targetPos[3];
        GetClientAbsOrigin(target, targetPos);

        float dir[3];
        float dist;
        if (!ComputeDirectionToPosition(client, targetPos, dir, dist))
        {
            ZeroVector(g_BotMoveDir[client]);
            g_BotState[client] = BotState_ChasingPlayer;
            return;
        }

        CopyVector(dir, g_BotMoveDir[client]);
        g_BotState[client] = BotState_ChasingPlayer;
        return;
    }

    // No clear movement LOS: fall back to waypoint pathing toward the player's nearest waypoint.
    if (g_BotPathLength[client] <= 0 || g_BotPathIndex[client] >= g_BotPathLength[client])
    {
        bool usedCache = false;
        if (g_BotCachedPathLength[client] > 0 && (now - g_BotCachedPathTime[client]) <= BOTLOGIC_PATH_CACHE_DURATION)
        {
            g_BotPathLength[client] = g_BotCachedPathLength[client];
            g_BotPathIndex[client]  = 0;
            for (int i = 0; i < g_BotCachedPathLength[client]; i++)
            {
                g_BotPath[client][i] = g_BotCachedPath[client][i];
            }
            usedCache = true;
        }

        if (!usedCache && now >= g_BotNextPathRebuild[client])
        {
            int endId = Waypoint_FindNearestToClient(target);
            if (endId >= 0)
            {
                BuildPathToWaypoint(client, endId);
            }
            else
            {
                g_BotNextPathRebuild[client] = now + BOTLOGIC_PATH_RETRY_COOLDOWN;
            }
        }

        if (g_BotPathLength[client] <= 0)
        {
            ZeroVector(g_BotMoveDir[client]);
            g_BotState[client] = BotState_ChasingPlayer;
            return;
        }
    }

    int nodeId = g_BotPath[client][g_BotPathIndex[client]];

    float nodePos[3];
    if (!Waypoint_GetOrigin(nodeId, nodePos))
    {
        g_BotPathIndex[client]++;
        if (g_BotPathIndex[client] >= g_BotPathLength[client])
        {
            ZeroVector(g_BotMoveDir[client]);
            g_BotState[client] = BotState_ChasingPlayer;
            return;
        }

        nodeId = g_BotPath[client][g_BotPathIndex[client]];
        if (!Waypoint_GetOrigin(nodeId, nodePos))
        {
            ZeroVector(g_BotMoveDir[client]);
            g_BotState[client] = BotState_ChasingPlayer;
            return;
        }
    }

    float origin[3];
    GetClientAbsOrigin(client, origin);

    float distSq = GetDistanceSquared2D(origin, nodePos);
    if (distSq <= BOTLOGIC_TARGET_RADIUS * BOTLOGIC_TARGET_RADIUS)
    {
        g_BotPathIndex[client]++;
        if (g_BotPathIndex[client] >= g_BotPathLength[client])
        {
            ZeroVector(g_BotMoveDir[client]);
            g_BotState[client] = BotState_ChasingPlayer;
            return;
        }

        // Recurse into next node this frame for smoother path transitions.
        ThinkPlayerTarget(client, now);
        return;
    }

    float dir2[3];
    float dummyDist;
    if (!ComputeDirectionToPosition(client, nodePos, dir2, dummyDist))
    {
        ZeroVector(g_BotMoveDir[client]);
        g_BotState[client] = BotState_ChasingPlayer;
        return;
    }

    CopyVector(dir2, g_BotMoveDir[client]);
    g_BotState[client] = BotState_MovingPath;

    if (Waypoint_IsDoorway(nodeId) && distSq <= (BOTLOGIC_TARGET_RADIUS * BOTLOGIC_TARGET_RADIUS * 4.0))
    {
        g_BotSpeedScale[client] = BOTLOGIC_DOORWAY_SPEED_SCALE;
    }
}

static void ThinkWaypointTarget(int client)
{
    int nodeId = g_BotTargetWaypoint[client];
    if (nodeId < 0)
    {
        ClearBotState(client);
        return;
    }

    float nodePos[3];
    if (!Waypoint_GetOrigin(nodeId, nodePos))
    {
        ClearBotState(client);
        return;
    }

    float origin[3];
    GetClientAbsOrigin(client, origin);

    float distSq = GetDistanceSquared2D(origin, nodePos);
    float radius = Waypoint_IsDoorway(nodeId) ? BOTLOGIC_DOORWAY_RADIUS : BOTLOGIC_TARGET_RADIUS;

    if (distSq <= radius * radius)
    {
        ClearBotState(client);
        return;
    }

    float dir[3];
    float dummyDist;
    if (!ComputeDirectionToPosition(client, nodePos, dir, dummyDist))
    {
        ClearBotState(client);
        return;
    }

    CopyVector(dir, g_BotMoveDir[client]);
    g_BotState[client] = BotState_MovingPath;

    if (Waypoint_IsDoorway(nodeId) && distSq <= (radius * radius * 4.0))
    {
        g_BotSpeedScale[client] = BOTLOGIC_DOORWAY_SPEED_SCALE;
    }
}

static void ThinkPositionTarget(int client)
{
    float targetPos[3];
    CopyVector(g_BotTargetPos[client], targetPos);

    float dir[3];
    float dist;
    if (!ComputeDirectionToPosition(client, targetPos, dir, dist))
    {
        ClearBotState(client);
        return;
    }

    if (dist <= BOTLOGIC_TARGET_RADIUS)
    {
        ClearBotState(client);
        return;
    }

    CopyVector(dir, g_BotMoveDir[client]);
    g_BotState[client] = BotState_MovingPath;
}

// ---------------------------------------------------------------------------
// Main think
// ---------------------------------------------------------------------------

static void BotThink(int client, float now)
{
if (!g_bIsCustomBot[client])
{
return;
}

if (!IsClientReady(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
{
    ClearBotState(client);
    return;
}

float lastThink = g_BotLastThink[client];
if (now - lastThink < BOTLOGIC_THINK_INTERVAL)
{
    return;
}

g_BotLastThink[client] = now;

g_BotSpeedScale[client] = 1.0;

if (g_BotTargetType[client] == BotTarget_None)
{
    if (now >= g_BotNextRetargetTime[client])
    {
        AutoAcquireTarget(client, now);
    }
    if (g_BotTargetType[client] == BotTarget_None)
    {
        ClearBotState(client);
        return;
    }
}

if (g_BotTargetType[client] == BotTarget_Player)
{
    ThinkPlayerTarget(client, now);
}
else if (g_BotTargetType[client] == BotTarget_Waypoint)
{
    ThinkWaypointTarget(client);
}
else if (g_BotTargetType[client] == BotTarget_Position)
{
    ThinkPositionTarget(client);
}
else
{
    ClearBotState(client);
}


}

// ---------------------------------------------------------------------------
// Stuck detection and recovery
// ---------------------------------------------------------------------------

static void UpdateBotStuckState(int client, float now)
{
float dir[3];
CopyVector(g_BotMoveDir[client], dir);

bool wantsMove = (dir[0] != 0.0 || dir[1] != 0.0 || dir[2] != 0.0);
if (!wantsMove)
{
    g_BotStuckAccum[client] = 0.0;
    ZeroVector(g_BotLastPos[client]);
    return;
}

float pos[3];
GetClientAbsOrigin(client, pos);

if (g_BotLastPos[client][0] == 0.0 && g_BotLastPos[client][1] == 0.0 && g_BotLastPos[client][2] == 0.0)
{
    CopyVector(pos, g_BotLastPos[client]);
    g_BotStuckAccum[client] = 0.0;
    return;
}

float dx = pos[0] - g_BotLastPos[client][0];
float dy = pos[1] - g_BotLastPos[client][1];
float distSq = dx * dx + dy * dy;

if (distSq < BOTLOGIC_STUCK_DIST_SQ)
{
    g_BotStuckAccum[client] += BOTLOGIC_THINK_INTERVAL;
    if (g_BotStuckAccum[client] >= BOTLOGIC_STUCK_TIME && now >= g_BotBounceCooldownUntil[client])
    {
        g_BotStuckAccum[client]       = 0.0;
        float mag = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
        if (mag > 0.0)
        {
            g_BotBackoffDir[client][0] = -dir[0] / mag;
            g_BotBackoffDir[client][1] = -dir[1] / mag;
            g_BotBackoffDir[client][2] = 0.0;
        }
        else
        {
            g_BotBackoffDir[client][0] = -1.0;
            g_BotBackoffDir[client][1] = 0.0;
            g_BotBackoffDir[client][2] = 0.0;
        }

        g_BotBackoffUntil[client] = now + BOTLOGIC_BACKOFF_DURATION;
        g_BotBounceStart[client]  = g_BotBackoffUntil[client];
        g_BotBounceEnd[client]    = g_BotBounceStart[client] + BOTLOGIC_BOUNCE_DURATION;
        g_BotBounceCooldownUntil[client] = now + BOTLOGIC_BOUNCE_COOLDOWN;

        // If we're chasing a player directly and have no waypoint path yet,
        // try to switch to a waypoint-based path to get around obstacles.
        if (g_BotTargetType[client] == BotTarget_Player && g_BotPathLength[client] <= 0)
        {
            int target = g_BotTargetPlayer[client];
            if (IsClientReady(target) && IsPlayerAlive(target))
            {
                int endId = Waypoint_FindNearestToClient(target);
                if (endId >= 0)
                {
                    BuildPathToWaypoint(client, endId);
                }
            }
        }
    }
}
else
{
    g_BotStuckAccum[client] = 0.0;
}

CopyVector(pos, g_BotLastPos[client]);


}

// ---------------------------------------------------------------------------
// Natives and plugin API
// ---------------------------------------------------------------------------

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
RegPluginLibrary("bot_logic");

CreateNative("BotLogic_IsCustomBot",           Native_BotLogic_IsCustomBot);
CreateNative("BotLogic_RegisterBot",          Native_BotLogic_RegisterBot);
CreateNative("BotLogic_UnregisterBot",        Native_BotLogic_UnregisterBot);

CreateNative("BotLogic_SetBotTargetWaypoint", Native_BotLogic_SetBotTargetWaypoint);
CreateNative("BotLogic_SetBotTargetPlayer",   Native_BotLogic_SetBotTargetPlayer);
CreateNative("BotLogic_SetBotTargetPosition", Native_BotLogic_SetBotTargetPosition);
CreateNative("BotLogic_ClearBotTarget",       Native_BotLogic_ClearBotTarget);

CreateNative("BotLogic_ForceState",           Native_BotLogic_ForceState);
CreateNative("BotLogic_DebugPrint",           Native_BotLogic_DebugPrint);

return APLRes_Success;


}

public void OnPluginStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bIsCustomBot[i] = false;
        g_BotState[i] = BotState_Idle;
        g_BotTargetType[i] = BotTarget_None;
        g_BotTargetWaypoint[i] = -1;
        g_BotTargetPlayer[i] = 0;
        ZeroVector(g_BotTargetPos[i]);
        g_BotPathLength[i] = 0;
        g_BotPathIndex[i] = 0;
        g_BotCachedPathLength[i] = 0;
        g_BotCachedPathTime[i] = 0.0;
        g_BotNextPathRebuild[i] = 0.0;
        ZeroVector(g_BotMoveDir[i]);
        g_BotSpeedScale[i] = 1.0;
        g_BotLastThink[i] = 0.0;
        ZeroVector(g_BotLastPos[i]);
        g_BotStuckAccum[i] = 0.0;
        ZeroVector(g_BotBackoffDir[i]);
        g_BotBackoffUntil[i] = 0.0;
        g_BotBounceStart[i] = 0.0;
        g_BotBounceEnd[i] = 0.0;
        g_BotBounceCooldownUntil[i] = 0.0;
        g_BotNextRetargetTime[i] = 0.0;
    }
}

public void OnMapStart()
{
for (int i = 1; i <= MaxClients; i++)
{
if (g_bIsCustomBot[i])
{
ClearBotState(i);
}
}
}

public void OnClientDisconnect(int client)
{
if (client < 1 || client > MaxClients)
{
return;
}

if (g_bIsCustomBot[client])
{
    g_bIsCustomBot[client] = false;
    ClearBotState(client);
}


}

// ---------------------------------------------------------------------------
// Native implementations
// ---------------------------------------------------------------------------

public int Native_BotLogic_IsCustomBot(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
if (client < 1 || client > MaxClients)
{
return 0;
}

return g_bIsCustomBot[client] ? 1 : 0;


}

public int Native_BotLogic_RegisterBot(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
if (client < 1 || client > MaxClients)
{
return 0;
}

g_bIsCustomBot[client] = true;
ClearBotState(client);
return 1;


}

public int Native_BotLogic_UnregisterBot(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
if (client < 1 || client > MaxClients)
{
return 0;
}

g_bIsCustomBot[client] = false;
ClearBotState(client);
return 1;


}

public int Native_BotLogic_SetBotTargetWaypoint(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
int nodeId = GetNativeCell(2);

if (client < 1 || client > MaxClients)
{
    return 0;
}

g_BotTargetType[client]     = BotTarget_Waypoint;
g_BotTargetWaypoint[client] = nodeId;
g_BotPathLength[client]     = 0;
g_BotPathIndex[client]      = 0;
ZeroVector(g_BotMoveDir[client]);
g_BotState[client]          = BotState_MovingPath;

return 1;


}

public int Native_BotLogic_SetBotTargetPlayer(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
int target = GetNativeCell(2);

if (client < 1 || client > MaxClients)
{
    return 0;
}

g_BotTargetType[client]   = BotTarget_Player;
g_BotTargetPlayer[client] = target;
g_BotPathLength[client]   = 0;
g_BotPathIndex[client]    = 0;
ZeroVector(g_BotMoveDir[client]);
g_BotState[client]        = BotState_ChasingPlayer;
g_BotNextRetargetTime[client] = GetGameTime() + BOTLOGIC_RETARGET_COOLDOWN;

return 1;


}

public int Native_BotLogic_SetBotTargetPosition(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
float pos[3];
GetNativeArray(2, pos, sizeof(pos));

if (client < 1 || client > MaxClients)
{
    return 0;
}

g_BotTargetType[client] = BotTarget_Position;
CopyVector(pos, g_BotTargetPos[client]);
g_BotPathLength[client] = 0;
g_BotPathIndex[client]  = 0;
ZeroVector(g_BotMoveDir[client]);
g_BotState[client]      = BotState_MovingPath;

return 1;


}

public int Native_BotLogic_ClearBotTarget(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
if (client < 1 || client > MaxClients)
{
return 0;
}

ClearBotState(client);
return 1;


}

public int Native_BotLogic_ForceState(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
int rawState = GetNativeCell(2);

if (client < 1 || client > MaxClients)
{
    return 0;
}

if (rawState < view_as<int>(BotState_Idle) || rawState > view_as<int>(BotState_Regrouping))
{
    return 0;
}

g_BotState[client] = view_as<BotState>(rawState);
return 1;


}

public int Native_BotLogic_DebugPrint(Handle plugin, int numParams)
{
int client = GetNativeCell(1);
if (client < 1 || client > MaxClients)
{
return 0;
}

PrintToServer("[BotLogic] Client %d: isCustom=%d state=%d targetType=%d pathLen=%d pathIndex=%d",
              client,
              g_bIsCustomBot[client] ? 1 : 0,
              g_BotState[client],
              g_BotTargetType[client],
              g_BotPathLength[client],
              g_BotPathIndex[client]);
return 1;


}

// ---------------------------------------------------------------------------
// Movement hook
// ---------------------------------------------------------------------------

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
if (!g_bIsCustomBot[client] || !IsClientReady(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
{
return Plugin_Continue;
}

float now = GetGameTime();

BotThink(client, now);
UpdateBotStuckState(client, now);

float dir[3];
CopyVector(g_BotMoveDir[client], dir);

bool wantsMove = (dir[0] != 0.0 || dir[1] != 0.0 || dir[2] != 0.0);
if (!wantsMove)
{
    return Plugin_Continue;
}

if (now < g_BotBackoffUntil[client])
{
    CopyVector(g_BotBackoffDir[client], dir);
}

wantsMove = (dir[0] != 0.0 || dir[1] != 0.0 || dir[2] != 0.0);
if (!wantsMove)
{
    return Plugin_Continue;
}

    float yaw;
    YawFromDirection(dir, yaw);

    angles[0] = 0.0;
    angles[1] = yaw;
    angles[2] = 0.0;

    buttons |= IN_FORWARD;

    vel[0] = BOTLOGIC_FORWARD_SPEED * g_BotSpeedScale[client];
    vel[1] = 0.0;
    vel[2] = 0.0;

if (now >= g_BotBounceStart[client] && now <= g_BotBounceEnd[client])
{
    buttons |= IN_JUMP;
    buttons |= IN_DUCK;
}

return Plugin_Changed;


}

// ---------------------------------------------------------------------------
// Plugin info
// ---------------------------------------------------------------------------

public Plugin myinfo =
{
name = "ZPS Bot Logic",
author = "Custom Framework",
description = "Core movement and targeting logic for custom zombie bots",
version = "0.4.0",
url = ""
};
