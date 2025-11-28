/**
 * zps_waypoint_logic.sp
 *
 * Waypoint system + in-game editor for Zombie Panic! Source.
 *
 * Features:
 *  - In-memory waypoint graph (nodes + bidirectional links).
 *  - Visual debug:
 *      - Neon beacons + pulsing rings.
 *      - FOV culling so only nodes in front of the player are drawn.
 *  - Editor menu (sm_wp):
 *      - Add node at player position.
 *      - Remove aimed node.
 *      - Select/link/unlink nodes.
 *      - Save to per-map file.
 *  - Doorway waypoints:
 *      - Special waypoint type bots must pass through more precisely
 *        (bots use a tighter arrival radius on doorway nodes).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

#define MAX_WAYPOINTS          512
#define MAX_LINKS_PER_WP         8
#define WP_AIM_MAX_DIST         64.0
#define WP_PATH_MAX_NODES      512

// FOV culling: only hide nodes behind the player.
#define NODE_FOV_COS            0.0

// Draw distance (reduced to limit clutter).
#define NODE_DRAW_MAX_DIST      1500.0
#define NODE_DRAW_MAX_DIST_SQ   (NODE_DRAW_MAX_DIST * NODE_DRAW_MAX_DIST)

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

bool  g_WPUsed[MAX_WAYPOINTS];
float g_WPOrigin[MAX_WAYPOINTS][3];
int   g_WPLinks[MAX_WAYPOINTS][MAX_LINKS_PER_WP];
int   g_WPLinkCount[MAX_WAYPOINTS];

bool  g_WPDoorway[MAX_WAYPOINTS];

// Per-client editor state
int  g_AimedNode[MAXPLAYERS + 1];
int  g_SelectedNode[MAXPLAYERS + 1];
bool g_EditorOpen[MAXPLAYERS + 1];

Handle g_hAimTimer = INVALID_HANDLE;

// Tempent sprites
int g_iBeamSprite = -1;
int g_iHaloSprite = -1;

// ---------------------------------------------------------------------------
// Forward declarations for natives
// ---------------------------------------------------------------------------

public any Native_Waypoint_FindNearestToClient(Handle plugin, int numParams);
public any Native_Waypoint_GetPath(Handle plugin, int numParams);
public any Native_Waypoint_GetOrigin(Handle plugin, int numParams);
public any Native_Waypoint_IsDoorway(Handle plugin, int numParams);

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

static bool IsValidWaypointId(int id)
{
    return (id >= 0 && id < MAX_WAYPOINTS && g_WPUsed[id]);
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

// ---------------------------------------------------------------------------
// Core waypoint helpers
// ---------------------------------------------------------------------------

static void ClearAllWaypoints()
{
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        g_WPUsed[i]      = false;
        g_WPLinkCount[i] = 0;
        g_WPDoorway[i]   = false;
        ZeroVector(g_WPOrigin[i]);

        for (int j = 0; j < MAX_LINKS_PER_WP; j++)
        {
            g_WPLinks[i][j] = -1;
        }
    }
}

static int AllocateWaypoint()
{
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            g_WPUsed[i]      = true;
            g_WPLinkCount[i] = 0;
            g_WPDoorway[i]   = false;
            ZeroVector(g_WPOrigin[i]);

            for (int j = 0; j < MAX_LINKS_PER_WP; j++)
            {
                g_WPLinks[i][j] = -1;
            }

            return i;
        }
    }

    return -1;
}

static void DeleteWaypoint(int id)
{
    if (!IsValidWaypointId(id))
    {
        return;
    }

    // Remove references from other nodes
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i] || i == id)
        {
            continue;
        }

        int writeIdx = 0;
        for (int j = 0; j < g_WPLinkCount[i]; j++)
        {
            int other = g_WPLinks[i][j];
            if (other == id || !IsValidWaypointId(other))
            {
                continue;
            }

            g_WPLinks[i][writeIdx] = other;
            writeIdx++;
        }

        g_WPLinkCount[i] = writeIdx;

        for (int j = g_WPLinkCount[i]; j < MAX_LINKS_PER_WP; j++)
        {
            g_WPLinks[i][j] = -1;
        }
    }

    g_WPUsed[id]      = false;
    g_WPLinkCount[id] = 0;
    g_WPDoorway[id]   = false;
    ZeroVector(g_WPOrigin[id]);
}

static int FindNearestWaypointPos(const float pos[3], float maxDist)
{
    float maxDistSq = maxDist * maxDist;
    int   best      = -1;
    float bestSq    = maxDistSq;

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            continue;
        }

        float dx = g_WPOrigin[i][0] - pos[0];
        float dy = g_WPOrigin[i][1] - pos[1];
        float dz = g_WPOrigin[i][2] - pos[2];

        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq < bestSq)
        {
            best   = i;
            bestSq = distSq;
        }
    }

    return best;
}

static bool AreWaypointsLinked(int a, int b)
{
    if (!IsValidWaypointId(a) || !IsValidWaypointId(b))
    {
        return false;
    }

    for (int i = 0; i < g_WPLinkCount[a]; i++)
    {
        if (g_WPLinks[a][i] == b)
        {
            return true;
        }
    }

    return false;
}

static bool AddLinkOneWay(int from, int to)
{
    if (!IsValidWaypointId(from) || !IsValidWaypointId(to))
    {
        return false;
    }

    if (AreWaypointsLinked(from, to))
    {
        return true;
    }

    if (g_WPLinkCount[from] >= MAX_LINKS_PER_WP)
    {
        return false;
    }

    g_WPLinks[from][g_WPLinkCount[from]] = to;
    g_WPLinkCount[from]++;
    return true;
}

static bool LinkWaypoints(int a, int b)
{
    if (!IsValidWaypointId(a) || !IsValidWaypointId(b))
    {
        return false;
    }

    bool ok1 = AddLinkOneWay(a, b);
    bool ok2 = AddLinkOneWay(b, a);
    return ok1 && ok2;
}

static bool UnlinkWaypoints(int a, int b)
{
    if (!IsValidWaypointId(a) || !IsValidWaypointId(b))
    {
        return false;
    }

    bool changed = false;

    for (int k = 0; k < 2; k++)
    {
        int from = (k == 0) ? a : b;
        int to   = (k == 0) ? b : a;

        int writeIdx = 0;
        for (int i = 0; i < g_WPLinkCount[from]; i++)
        {
            int cur = g_WPLinks[from][i];
            if (cur == to || !IsValidWaypointId(cur))
            {
                changed = true;
                continue;
            }

            g_WPLinks[from][writeIdx] = cur;
            writeIdx++;
        }

        g_WPLinkCount[from] = writeIdx;
        for (int j = g_WPLinkCount[from]; j < MAX_LINKS_PER_WP; j++)
        {
            g_WPLinks[from][j] = -1;
        }
    }

    return changed;
}

// Nearest-to-client helper (native)
static int FindNearestWaypointToClient(int client, float maxDist)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return -1;
    }

    float pos[3];
    GetClientAbsOrigin(client, pos);
    return FindNearestWaypointPos(pos, maxDist);
}

// ---------------------------------------------------------------------------
// BFS pathfinding
// ---------------------------------------------------------------------------

static int BuildWaypointPath(int start, int goal, int[] outBuffer, int maxSize)
{
    if (!IsValidWaypointId(start) || !IsValidWaypointId(goal))
    {
        return 0;
    }

    int queue[MAX_WAYPOINTS];
    int head = 0;
    int tail = 0;

    int prev[MAX_WAYPOINTS];
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        prev[i] = -2;
    }

    queue[tail++] = start;
    prev[start]   = -1;

    bool found = false;

    while (head < tail)
    {
        int cur = queue[head++];
        if (cur == goal)
        {
            found = true;
            break;
        }

        for (int i = 0; i < g_WPLinkCount[cur]; i++)
        {
            int nxt = g_WPLinks[cur][i];
            if (!IsValidWaypointId(nxt))
            {
                continue;
            }

            if (prev[nxt] != -2)
            {
                continue;
            }

            prev[nxt]     = cur;
            queue[tail++] = nxt;
            if (tail >= MAX_WAYPOINTS)
            {
                break;
            }
        }
    }

    if (!found)
    {
        return 0;
    }

    int tmp[MAX_WAYPOINTS];
    int len = 0;
    int cur = goal;

    while (cur != -1 && len < MAX_WAYPOINTS)
    {
        tmp[len++] = cur;
        cur = prev[cur];
    }

    if (len <= 0)
    {
        return 0;
    }

    int outLen = 0;
    for (int i = len - 1; i >= 0 && outLen < maxSize; i--)
    {
        outBuffer[outLen++] = tmp[i];
    }

    return outLen;
}

// ---------------------------------------------------------------------------
// Doorway helpers
// ---------------------------------------------------------------------------

static void ToggleDoorway(int id)
{
    if (!IsValidWaypointId(id))
    {
        return;
    }

    g_WPDoorway[id] = !g_WPDoorway[id];
}

static void ClearEditorState(int client)
{
    g_AimedNode[client]    = -1;
    g_SelectedNode[client] = -1;
}

// ---------------------------------------------------------------------------
// Visual debug drawing
// ---------------------------------------------------------------------------

static void DrawWaypointsForClient(int client)
{
    if (g_iBeamSprite == -1)
    {
        return;
    }

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return;
    }

    if (!g_EditorOpen[client])
    {
        return;
    }

    int aimed    = g_AimedNode[client];
    int selected = g_SelectedNode[client];

    float eye[3];
    float ang[3];
    float fwd[3];

    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);

    bool visible[MAX_WAYPOINTS];
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        visible[i] = false;
    }

    // Determine which nodes are within FOV and draw distance
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            continue;
        }

        float toNode[3];
        toNode[0] = g_WPOrigin[i][0] - eye[0];
        toNode[1] = g_WPOrigin[i][1] - eye[1];
        toNode[2] = g_WPOrigin[i][2] - eye[2];

        float lenSq = toNode[0] * toNode[0] + toNode[1] * toNode[1] + toNode[2] * toNode[2];
        if (lenSq > NODE_DRAW_MAX_DIST_SQ)
        {
            continue;
        }

        if (lenSq <= 1.0)
        {
            continue;
        }

        float len    = SquareRoot(lenSq);
        float invLen = 1.0 / len;

        float dir[3];
        dir[0] = toNode[0] * invLen;
        dir[1] = toNode[1] * invLen;
        dir[2] = toNode[2] * invLen;

        float dot = fwd[0] * dir[0] + fwd[1] * dir[1] + fwd[2] * dir[2];
        if (dot >= NODE_FOV_COS)
        {
            visible[i] = true;
        }
    }

    // Draw links (white beams), visible if either endpoint is visible
    int linkColor[4] = {255, 255, 255, 255};
    float start[3], end[3];

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            continue;
        }

        for (int j = 0; j < g_WPLinkCount[i]; j++)
        {
            int other = g_WPLinks[i][j];
            if (!IsValidWaypointId(other))
            {
                continue;
            }

            if (other <= i)
            {
                continue;
            }

            if (!visible[i] && !visible[other])
            {
                continue;
            }

            CopyVector(g_WPOrigin[i], start);
            CopyVector(g_WPOrigin[other], end);
            start[2] += 10.0;
            end[2]   += 10.0;

            TE_SetupBeamPoints(start, end, g_iBeamSprite, 0,
                               0, 0, 0.30, 1.2, 1.0, 0, 0.0, linkColor, 0);
            TE_SendToClient(client);
        }
    }

    float time = GetGameTime();

    // Draw nodes: neon beacon + pulse ring
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i] || !visible[i])
        {
            continue;
        }

        float center[3];
        CopyVector(g_WPOrigin[i], center);
        center[2] += 4.0;

        float top[3];
        int   color[4];

        // Colors:
        //  - Normal: Cyan/Teal
        //  - Aimed: Lime
        //  - Selected: Red
        if (i == selected)
        {
            color[0] = 255; color[1] = 0;   color[2] = 0;   color[3] = 255;
        }
        else if (i == aimed)
        {
            color[0] = 128; color[1] = 255; color[2] = 0;   color[3] = 255;
        }
        else
        {
            color[0] = 0;   color[1] = 255; color[2] = 255; color[3] = 200;
        }

        float height = 32.0;
        if (g_WPDoorway[i])
        {
            height = 48.0;
        }

        top[0] = center[0];
        top[1] = center[1];
        top[2] = center[2] + height;

        // Pulsing thickness, clamped to avoid negative widths (DataTable m_fWidth/m_fEndWidth warnings)
        float pulse = Sine(time * 8.0) * 3.0;
        float width = 1.8 + pulse;
        float endWidth = 2.4 + pulse;
        if (width < 0.1)
        {
            width = 0.1;
        }
        if (endWidth < 0.1)
        {
            endWidth = 0.1;
        }

        // Vertical beacon
        TE_SetupBeamPoints(center, top, g_iBeamSprite, g_iHaloSprite,
                           0, 0,
                           0.40,
                           width,
                           endWidth,
                           0,
                           0.0,
                           color,
                           0);
        TE_SendToClient(client);

        // Pulse ring
        float ringHeight = center[2] + 5.0;
        float ringRadius = 15.0 + pulse;

        float ringOrigin[3];
        ringOrigin[0] = center[0];
        ringOrigin[1] = center[1];
        ringOrigin[2] = ringHeight;

        int ringColor[4];
        ringColor[0] = color[0];
        ringColor[1] = color[1];
        ringColor[2] = color[2];
        ringColor[3] = 200;

        TE_SetupBeamRingPoint(
            ringOrigin,
            ringRadius - 2.0,
            ringRadius + 2.0,
            g_iBeamSprite,
            g_iHaloSprite,
            0,          // StartFrame
            0,          // FrameRate
            0.40,       // Life
            4.0,        // Width
            0.0,        // Amplitude
            ringColor,
            0,          // Speed
            0           // Flags
        );
        TE_SendToClient(client);
    }
}

// ---------------------------------------------------------------------------
// Aiming logic (raycast under crosshair)
// ---------------------------------------------------------------------------

public bool TraceFilter_WaypointSight(int entity, int contentsMask, any data)
{
    if (entity >= 1 && entity <= MaxClients)
    {
        return false;
    }
    return true;
}

static int FindAimedWaypoint(int client)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return -1;
    }

    float eye[3];
    float ang[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);

    float dir[3];
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);

    float end[3];
    end[0] = eye[0] + dir[0] * 1024.0;
    end[1] = eye[1] + dir[1] * 1024.0;
    end[2] = eye[2] + dir[2] * 1024.0;

    Handle trace = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint, TraceFilter_WaypointSight, 0);
    float hit[3];

    if (TR_DidHit(trace))
    {
        TR_GetEndPosition(hit, trace);
    }
    else
    {
        CopyVector(end, hit);
    }

    CloseHandle(trace);

    return FindNearestWaypointPos(hit, WP_AIM_MAX_DIST);
}

// ---------------------------------------------------------------------------
// Timers and editor tick
// ---------------------------------------------------------------------------

public Action Timer_UpdateAimAndDraw(Handle timer, any data)
{
    if (g_iBeamSprite == -1)
    {
        return Plugin_Continue;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsPlayerAlive(client))
        {
            g_AimedNode[client] = -1;
            continue;
        }

        if (!g_EditorOpen[client])
        {
            g_AimedNode[client] = -1;
            continue;
        }

        g_AimedNode[client] = FindAimedWaypoint(client);
        DrawWaypointsForClient(client);
    }

    return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Saving / loading (with reindex to avoid ID holes)
// ---------------------------------------------------------------------------

static void ReindexWaypoints()
{
    int newIndex[MAX_WAYPOINTS];
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        newIndex[i] = -1;
    }

    int nextId = 0;
    for (int old = 0; old < MAX_WAYPOINTS; old++)
    {
        if (!g_WPUsed[old])
        {
            continue;
        }

        newIndex[old] = nextId;
        nextId++;
    }

    bool  newUsed[MAX_WAYPOINTS];
    float newOrigin[MAX_WAYPOINTS][3];
    int   newLinks[MAX_WAYPOINTS][MAX_LINKS_PER_WP];
    int   newLinkCount[MAX_WAYPOINTS];
    bool  newDoorway[MAX_WAYPOINTS];

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        newUsed[i]      = false;
        newLinkCount[i] = 0;
        newDoorway[i]   = false;
        ZeroVector(newOrigin[i]);
        for (int j = 0; j < MAX_LINKS_PER_WP; j++)
        {
            newLinks[i][j] = -1;
        }
    }

    for (int old = 0; old < MAX_WAYPOINTS; old++)
    {
        if (!g_WPUsed[old])
        {
            continue;
        }

        int ni = newIndex[old];
        if (ni < 0 || ni >= MAX_WAYPOINTS)
        {
            continue;
        }

        newUsed[ni] = true;
        CopyVector(g_WPOrigin[old], newOrigin[ni]);
        newDoorway[ni] = g_WPDoorway[old];

        int writeIdx = 0;
        for (int j = 0; j < g_WPLinkCount[old] && writeIdx < MAX_LINKS_PER_WP; j++)
        {
            int oldOther = g_WPLinks[old][j];
            if (!IsValidWaypointId(oldOther))
            {
                continue;
            }

            int newOther = newIndex[oldOther];
            if (newOther < 0 || newOther >= MAX_WAYPOINTS)
            {
                continue;
            }

            if (newOther == ni)
            {
                continue;
            }

            bool exists = false;
            for (int k = 0; k < writeIdx; k++)
            {
                if (newLinks[ni][k] == newOther)
                {
                    exists = true;
                    break;
                }
            }

            if (exists)
            {
                continue;
            }

            newLinks[ni][writeIdx] = newOther;
            writeIdx++;
        }

        newLinkCount[ni] = writeIdx;
    }

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        g_WPUsed[i]      = newUsed[i];
        g_WPLinkCount[i] = newLinkCount[i];
        g_WPDoorway[i]   = newDoorway[i];
        CopyVector(newOrigin[i], g_WPOrigin[i]);

        for (int j = 0; j < MAX_LINKS_PER_WP; j++)
        {
            g_WPLinks[i][j] = newLinks[i][j];
        }
    }
}

static void SaveWaypointsToFile(int client)
{
    ReindexWaypoints();

    char map[64];
    GetCurrentMap(map, sizeof(map));

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/%s_waypoints.cfg", map);

    File file = OpenFile(path, "w");
    if (file == null)
    {
        if (client > 0 && IsClientInGame(client))
        {
            PrintToChat(client, "[WP] Failed to open waypoint file for writing.");
        }
        return;
    }

    int count = 0;
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (g_WPUsed[i])
        {
            count++;
        }
    }

    file.WriteLine("// Waypoint data for map: %s", map);
    file.WriteLine("// Id, Position, Doorway Flag, Linked Ids");
    file.WriteLine("nodes %d", count);

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            continue;
        }

        float x = g_WPOrigin[i][0];
        float y = g_WPOrigin[i][1];
        float z = g_WPOrigin[i][2];

        int doorFlag = g_WPDoorway[i] ? 1 : 0;

        file.WriteLine("");
        file.WriteLine("node %d %.1f %.1f %.1f %d", i, x, y, z, doorFlag);

        if (g_WPLinkCount[i] > 0)
        {
            // Write "links:" prefix without newline
            file.WriteString("links:", false);

            char buf[32];

            for (int j = 0; j < g_WPLinkCount[i]; j++)
            {
                int other = g_WPLinks[i][j];
                if (!IsValidWaypointId(other))
                {
                    continue;
                }

                if (other < i)
                {
                    continue;
                }

                Format(buf, sizeof(buf), " %d", other);
                // Append id without newline
                file.WriteString(buf, false);
            }

            // Finish the line
            file.WriteLine("");
        }
    }

    CloseHandle(file);

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[WP] Waypoints saved.");
    }
}

static void LoadWaypointsFromFile()
{
    ClearAllWaypoints();

    char map[64];
    GetCurrentMap(map, sizeof(map));

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/%s_waypoints.cfg", map);

    File file = OpenFile(path, "r");
    if (file == null)
    {
        return;
    }

    char line[256];
    int  lastNodeId = -1;

    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);

        if (line[0] == '\0' || line[0] == '/' || line[0] == '#')
        {
            continue;
        }

        // Header like "nodes N"
        if (StrContains(line, "nodes") == 0)
        {
            continue;
        }

        // Node line: "node <id> <x> <y> <z> [door]"
        if (StrContains(line, "node ") == 0)
        {
            char parts[6][32];
            int count = ExplodeString(line, " ", parts, 6, 32);

            if (count < 5)
            {
                continue;
            }

            int   id = StringToInt(parts[1]);
            float x  = StringToFloat(parts[2]);
            float y  = StringToFloat(parts[3]);
            float z  = StringToFloat(parts[4]);

            int doorFlag = 0;
            if (count >= 6)
            {
                doorFlag = StringToInt(parts[5]);
            }

            if (id < 0 || id >= MAX_WAYPOINTS)
            {
                continue;
            }

            g_WPUsed[id]       = true;
            g_WPOrigin[id][0]  = x;
            g_WPOrigin[id][1]  = y;
            g_WPOrigin[id][2]  = z;
            g_WPDoorway[id]    = (doorFlag != 0);
            g_WPLinkCount[id]  = 0;

            lastNodeId = id;
            continue;
        }

        // Links line for the last node: "links: <id> <id> ..."
        if (StrContains(line, "links:") == 0)
        {
            if (lastNodeId < 0 || !IsValidWaypointId(lastNodeId))
            {
                continue;
            }

            char parts[16][32];
            int count = ExplodeString(line, " ", parts, 16, 32);
            if (count <= 1)
            {
                continue;
            }

            for (int i = 1; i < count; i++)
            {
                if (parts[i][0] == '\0')
                {
                    continue;
                }

                int other = StringToInt(parts[i]);
                if (!IsValidWaypointId(other))
                {
                    continue;
                }

                LinkWaypoints(lastNodeId, other);
            }

            continue;
        }
    }

    CloseHandle(file);
}

// ---------------------------------------------------------------------------
// Menu helpers
// ---------------------------------------------------------------------------

public int WaypointMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    int client = param1;

    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        g_EditorOpen[client] = false;
        ClearEditorState(client);
        PrintToChat(client, "[WP] Editor closed.");
    }
    else if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "add"))
        {
            float pos[3];
            GetClientAbsOrigin(client, pos);

            int id = AllocateWaypoint();
            if (id == -1)
            {
                PrintToChat(client, "[WP] No free slots for new waypoint.");
            }
            else
            {
                CopyVector(pos, g_WPOrigin[id]);
                PrintToChat(client, "[WP] Added waypoint %d.", id);
            }

            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "remove_aimed"))
        {
            int aimed = g_AimedNode[client];
            if (!IsValidWaypointId(aimed))
            {
                PrintToChat(client, "[WP] No aimed waypoint to remove.");
            }
            else
            {
                PrintToChat(client, "[WP] Removed waypoint %d.", aimed);
                DeleteWaypoint(aimed);
            }

            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "select_aimed"))
        {
            int aimed = g_AimedNode[client];
            if (!IsValidWaypointId(aimed))
            {
                PrintToChat(client, "[WP] No aimed waypoint to select.");
            }
            else
            {
                if (g_SelectedNode[client] == -1)
                {
                    g_SelectedNode[client] = aimed;
                    PrintToChat(client, "[WP] Selected waypoint %d.", aimed);
                }
                else
                {
                    int a = g_SelectedNode[client];
                    int b = aimed;

                    if (a == b)
                    {
                        PrintToChat(client, "[WP] Same waypoint selected.");
                    }
                    else
                    {
                        if (AreWaypointsLinked(a, b))
                        {
                            UnlinkWaypoints(a, b);
                            PrintToChat(client, "[WP] Unlinked %d <-> %d.", a, b);
                        }
                        else
                        {
                            if (LinkWaypoints(a, b))
                            {
                                PrintToChat(client, "[WP] Linked %d <-> %d.", a, b);
                            }
                            else
                            {
                                PrintToChat(client, "[WP] Failed to link %d <-> %d (link limit).", a, b);
                            }
                        }

                        g_SelectedNode[client] = b;
                    }
                }
            }

            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "toggle_doorway"))
        {
            int aimed = g_AimedNode[client];
            if (!IsValidWaypointId(aimed))
            {
                PrintToChat(client, "[WP] Aim at a waypoint to toggle doorway flag.");
            }
            else
            {
                ToggleDoorway(aimed);
                PrintToChat(client, "[WP] Waypoint %d doorway flag is now %s.", aimed, g_WPDoorway[aimed] ? "ON" : "OFF");
            }

            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "clear_selection"))
        {
            g_SelectedNode[client] = -1;
            PrintToChat(client, "[WP] Selection cleared.");
            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "save"))
        {
            SaveWaypointsToFile(client);
            ShowWaypointMenu(client);
        }
        else if (StrEqual(info, "close"))
        {
            g_EditorOpen[client] = false;
            ClearEditorState(client);
            PrintToChat(client, "[WP] Editor closed.");
        }
    }

    return 0;
}

static void ShowWaypointMenu(int client)
{
    Menu menu = new Menu(WaypointMenuHandler, MenuAction_Select | MenuAction_Cancel | MenuAction_End);
    menu.SetTitle("Waypoint Editor");

    menu.AddItem("add",            "Add node at player");
    menu.AddItem("remove_aimed",   "Remove aimed node");
    menu.AddItem("select_aimed",   "Select/link via aimed node");
    menu.AddItem("toggle_doorway", "Toggle doorway flag on aimed node");
    menu.AddItem("clear_selection","Clear selection");
    menu.AddItem("save",           "Save waypoints");
    menu.AddItem("close",          "Close editor");

    menu.Display(client, 0);
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

public Action Command_WaypointEditor(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (g_EditorOpen[client])
    {
        g_EditorOpen[client] = false;
        ClearEditorState(client);
        PrintToChat(client, "[WP] Editor closed.");
    }
    else
    {
        LoadWaypointsFromFile();
        g_EditorOpen[client] = true;
        ClearEditorState(client);
        PrintToChat(client, "[WP] Editor opened.");
        ShowWaypointMenu(client);
    }

    return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("waypoint_logic");

    CreateNative("Waypoint_FindNearestToClient", Native_Waypoint_FindNearestToClient);
    CreateNative("Waypoint_GetPath",             Native_Waypoint_GetPath);
    CreateNative("Waypoint_GetOrigin",           Native_Waypoint_GetOrigin);
    CreateNative("Waypoint_IsDoorway",           Native_Waypoint_IsDoorway);

    return APLRes_Success;
}

public any Native_Waypoint_FindNearestToClient(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
    {
        return -1;
    }

    return FindNearestWaypointToClient(client, 99999.0);
}

public any Native_Waypoint_GetPath(Handle plugin, int numParams)
{
    int startId = GetNativeCell(1);
    int endId   = GetNativeCell(2);

    if (!IsValidWaypointId(startId) || !IsValidWaypointId(endId))
    {
        return 0;
    }

    int maxSize = GetNativeCell(4);
    if (maxSize <= 0)
    {
        return 0;
    }

    if (maxSize > WP_PATH_MAX_NODES)
    {
        maxSize = WP_PATH_MAX_NODES;
    }

    int buffer[WP_PATH_MAX_NODES];
    int len = BuildWaypointPath(startId, endId, buffer, maxSize);
    if (len <= 0)
    {
        return 0;
    }

    SetNativeArray(3, buffer, len);
    return len;
}

public any Native_Waypoint_GetOrigin(Handle plugin, int numParams)
{
    int id = GetNativeCell(1);
    if (!IsValidWaypointId(id))
    {
        return false;
    }

    float tmp[3];
    tmp[0] = g_WPOrigin[id][0];
    tmp[1] = g_WPOrigin[id][1];
    tmp[2] = g_WPOrigin[id][2];

    SetNativeArray(2, tmp, 3);
    return true;
}

public any Native_Waypoint_IsDoorway(Handle plugin, int numParams)
{
    int id = GetNativeCell(1);
    if (!IsValidWaypointId(id))
    {
        return false;
    }

    return g_WPDoorway[id];
}

// ---------------------------------------------------------------------------
// Plugin lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    RegAdminCmd("sm_wp", Command_WaypointEditor, ADMFLAG_GENERIC, "Open/close the waypoint editor.");

    ClearAllWaypoints();

    char map[64];
    GetCurrentMap(map, sizeof(map));
    LoadWaypointsFromFile();

    g_iBeamSprite = PrecacheModel("sprites/laser.vmt");
    g_iHaloSprite = PrecacheModel("sprites/glow01.vmt");

    if (g_hAimTimer != INVALID_HANDLE)
    {
        CloseHandle(g_hAimTimer);
        g_hAimTimer = INVALID_HANDLE;
    }

    g_hAimTimer = CreateTimer(0.25, Timer_UpdateAimAndDraw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_EditorOpen[i]   = false;
        g_AimedNode[i]    = -1;
        g_SelectedNode[i] = -1;
    }
}

public void OnMapStart()
{
    ClearAllWaypoints();

    char map[64];
    GetCurrentMap(map, sizeof(map));
    LoadWaypointsFromFile();

    g_iBeamSprite = PrecacheModel("sprites/laser.vmt");
    g_iHaloSprite = PrecacheModel("sprites/glow01.vmt");

    if (g_hAimTimer != INVALID_HANDLE)
    {
        CloseHandle(g_hAimTimer);
        g_hAimTimer = INVALID_HANDLE;
    }

    g_hAimTimer = CreateTimer(0.25, Timer_UpdateAimAndDraw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_EditorOpen[client]   = false;
    g_AimedNode[client]    = -1;
    g_SelectedNode[client] = -1;
}

// ---------------------------------------------------------------------------
// Plugin info
// ---------------------------------------------------------------------------

public Plugin myinfo =
{
    name        = "ZPS Waypoint Logic",
    author      = "ChatGPT (bot framework)",
    description = "Waypoint web + editor for custom zombie bots",
    version     = "0.6.6",
    url         = ""
};
