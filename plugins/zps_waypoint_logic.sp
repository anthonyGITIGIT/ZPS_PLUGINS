/**

zps_waypoint_logic.sp

Waypoint system + in-game editor for Zombie Panic! Source.
*/

#pragma semicolon 1
#pragma newdecls required
#pragma dynamic 65536

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

#define MAX_WAYPOINTS 512
#define MAX_LINKS_PER_WP 8
#define WP_AIM_MAX_DIST 64.0
#define WP_PATH_MAX_NODES 512

// FOV culling: only hide nodes behind the player.
#define NODE_FOV_COS 0.0

// Draw distance (aggressive culling).
#define NODE_DRAW_MAX_DIST 400.0
#define NODE_DRAW_MAX_DIST_SQ (NODE_DRAW_MAX_DIST * NODE_DRAW_MAX_DIST)
#define NODE_FLOOR_DELTA_MAX 96.0

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

// Node usage
bool g_WPUsed[MAX_WAYPOINTS];

// Node origin
float g_WPOrigin[MAX_WAYPOINTS][3];

// Adjacency list (bidirectional graph with limited degree)
int g_WPLinks[MAX_WAYPOINTS][MAX_LINKS_PER_WP];
int g_WPLinkCount[MAX_WAYPOINTS];

// Special flag: doorway node (bots treat these more precisely)
bool g_WPDoorway[MAX_WAYPOINTS];

// Per-client editor state
int g_AimedNode[MAXPLAYERS + 1];
int g_SelectedNode[MAXPLAYERS + 1];
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

static void CopyVector(const float src[3], float dest[3])
{
dest[0] = src[0];
dest[1] = src[1];
dest[2] = src[2];
}

// ---------------------------------------------------------------------------
// Waypoint allocation / graph operations
// ---------------------------------------------------------------------------

static int AllocateWaypoint(const float pos[3])
{
for (int i = 0; i < MAX_WAYPOINTS; i++)
{
if (!g_WPUsed[i])
{
g_WPUsed[i] = true;
CopyVector(pos, g_WPOrigin[i]);
g_WPLinkCount[i] = 0;
g_WPDoorway[i] = false;
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
    if (!g_WPUsed[i])
    {
        continue;
    }

    for (int j = 0; j < g_WPLinkCount[i]; j++)
    {
        if (g_WPLinks[i][j] == id)
        {
            // Shift down
            for (int k = j; k < g_WPLinkCount[i] - 1; k++)
            {
                g_WPLinks[i][k] = g_WPLinks[i][k + 1];
            }
            g_WPLinkCount[i]--;
            j--;
        }
    }
}

g_WPUsed[id] = false;
g_WPLinkCount[id] = 0;
g_WPDoorway[id] = false;


}

static bool LinkWaypoints(int a, int b)
{
if (!IsValidWaypointId(a) || !IsValidWaypointId(b) || a == b)
{
return false;
}

// Already linked?
for (int i = 0; i < g_WPLinkCount[a]; i++)
{
    if (g_WPLinks[a][i] == b)
    {
        return true;
    }
}

// Capacity check
if (g_WPLinkCount[a] >= MAX_LINKS_PER_WP || g_WPLinkCount[b] >= MAX_LINKS_PER_WP)
{
    return false;
}

g_WPLinks[a][g_WPLinkCount[a]++] = b;
g_WPLinks[b][g_WPLinkCount[b]++] = a;

return true;


}

static void UnlinkWaypoints(int a, int b)
{
if (!IsValidWaypointId(a) || !IsValidWaypointId(b) || a == b)
{
return;
}

for (int i = 0; i < g_WPLinkCount[a]; i++)
{
    if (g_WPLinks[a][i] == b)
    {
        for (int k = i; k < g_WPLinkCount[a] - 1; k++)
        {
            g_WPLinks[a][k] = g_WPLinks[a][k + 1];
        }
        g_WPLinkCount[a]--;
        break;
    }
}

for (int j = 0; j < g_WPLinkCount[b]; j++)
{
    if (g_WPLinks[b][j] == a)
    {
        for (int k = j; k < g_WPLinkCount[b] - 1; k++)
        {
            g_WPLinks[b][k] = g_WPLinks[b][k + 1];
        }
        g_WPLinkCount[b]--;
        break;
    }
}


}

static void ClearWaypoints()
{
for (int i = 0; i < MAX_WAYPOINTS; i++)
{
g_WPUsed[i] = false;
g_WPLinkCount[i] = 0;
g_WPDoorway[i] = false;
}
}

// ---------------------------------------------------------------------------
// Reindexing: compact IDs and rebuild links
// ---------------------------------------------------------------------------

static void ReindexWaypoints()
{
int remap[MAX_WAYPOINTS];
int next = 0;

// Build mapping oldId -> newId, compacted
for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    if (g_WPUsed[i])
    {
        remap[i] = next++;
    }
    else
    {
        remap[i] = -1;
    }
}

if (next == 0)
{
    // No waypoints, just clear
    ClearWaypoints();
    return;
}

bool  newUsed[MAX_WAYPOINTS];
float newOrigin[MAX_WAYPOINTS][3];
int   newLinks[MAX_WAYPOINTS][MAX_LINKS_PER_WP];
int   newLinkCount[MAX_WAYPOINTS];
bool  newDoorway[MAX_WAYPOINTS];

for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    newUsed[i] = false;
    newLinkCount[i] = 0;
    newDoorway[i] = false;
}

for (int oldId = 0; oldId < MAX_WAYPOINTS; oldId++)
{
    int newId = remap[oldId];
    if (newId == -1)
    {
        continue;
    }

    newUsed[newId] = true;
    CopyVector(g_WPOrigin[oldId], newOrigin[newId]);
    newDoorway[newId] = g_WPDoorway[oldId];

    // Remap links for this node, skip invalid and self
    for (int j = 0; j < g_WPLinkCount[oldId]; j++)
    {
        int oldNeighbor = g_WPLinks[oldId][j];
        int newNeighbor = (oldNeighbor >= 0 && oldNeighbor < MAX_WAYPOINTS) ? remap[oldNeighbor] : -1;

        if (newNeighbor == -1 || newNeighbor == newId)
        {
            continue;
        }

        // Deduplicate
        bool exists = false;
        for (int k = 0; k < newLinkCount[newId]; k++)
        {
            if (newLinks[newId][k] == newNeighbor)
            {
                exists = true;
                break;
            }
        }

        if (!exists && newLinkCount[newId] < MAX_LINKS_PER_WP)
        {
            newLinks[newId][newLinkCount[newId]++] = newNeighbor;
        }
    }
}

// Copy back
for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    g_WPUsed[i] = newUsed[i];
    CopyVector(newOrigin[i], g_WPOrigin[i]);
    g_WPLinkCount[i] = newLinkCount[i];
    g_WPDoorway[i] = newDoorway[i];

    for (int j = 0; j < newLinkCount[i]; j++)
    {
        g_WPLinks[i][j] = newLinks[i][j];
    }
}


}

// ---------------------------------------------------------------------------
// File I/O (per-map waypoints)
// ---------------------------------------------------------------------------

static void GetWaypointFilePath(char path[PLATFORM_MAX_PATH])
{
char map[64];
GetCurrentMap(map, sizeof(map));

BuildPath(Path_SM, path, sizeof(path), "data/%s_waypoints.cfg", map);


}

static void SaveWaypointsToFile()
{
ReindexWaypoints();

char path[PLATFORM_MAX_PATH];
GetWaypointFilePath(path);

File file = OpenFile(path, "w");
if (file == null)
{
    PrintToServer("[WP] Failed to open %s for writing.", path);
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

file.WriteLine("// Waypoint data for map");
file.WriteLine("// Id, Position, Doorway Flag, Linked Ids");
file.WriteLine("nodes %d", count);

for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    if (!g_WPUsed[i])
    {
        continue;
    }

    int doorFlag = g_WPDoorway[i] ? 1 : 0;

    file.WriteLine("node %d %.2f %.2f %.2f %d",
                   i,
                   g_WPOrigin[i][0],
                   g_WPOrigin[i][1],
                   g_WPOrigin[i][2],
                   doorFlag);

    char buffer[256];
    Format(buffer, sizeof(buffer), "links:");

    for (int j = 0; j < g_WPLinkCount[i]; j++)
    {
        int other = g_WPLinks[i][j];
        if (!IsValidWaypointId(other))
        {
            continue;
        }

        // Only write links where other >= i to avoid duplicates
        if (other < i)
        {
            continue;
        }

        char tmp[32];
        Format(tmp, sizeof(tmp), " %d", other);
        StrCat(buffer, sizeof(buffer), tmp);
    }

    file.WriteString(buffer, false);
    file.WriteLine("");
}

delete file;

PrintToServer("[WP] Waypoints saved to %s", path);


}

static void LoadWaypointsFromFile()
{
char path[PLATFORM_MAX_PATH];
char line[256];
int lastNodeId = -1;

const int MAX_TEMP_EDGES = 4096;
int edgeFrom[MAX_TEMP_EDGES];
int edgeTo[MAX_TEMP_EDGES];
int edgeCount = 0;

ClearWaypoints();
GetWaypointFilePath(path);

if (!FileExists(path))
{
    PrintToServer("[WP] No waypoint file for this map yet (%s).", path);
    return;
}

File file = OpenFile(path, "r");
if (file == null)
{
    PrintToServer("[WP] Failed to open %s for reading.", path);
    return;
}

while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
{
    // Trim leading/trailing whitespace
    TrimString(line);

    if (line[0] == '\0' || line[0] == '/')
    {
        continue;
    }

    // Skip "nodes <count>" header
    if (StrContains(line, "nodes", false) == 0)
    {
        continue;
    }

    // Node line: "node <id> <x> <y> <z> <doorFlag>"
    if (StrContains(line, "node", false) == 0)
    {
        char tokens[6][32];
        int  tcount = ExplodeString(line, " ", tokens, sizeof(tokens), sizeof(tokens[]));

        if (tcount >= 6 && StrEqual(tokens[0], "node", false))
        {
            int   id       = StringToInt(tokens[1]);
            float x        = StringToFloat(tokens[2]);
            float y        = StringToFloat(tokens[3]);
            float z        = StringToFloat(tokens[4]);
            int   doorFlag = StringToInt(tokens[5]);

            if (id >= 0 && id < MAX_WAYPOINTS)
            {
                g_WPUsed[id]       = true;
                g_WPOrigin[id][0]  = x;
                g_WPOrigin[id][1]  = y;
                g_WPOrigin[id][2]  = z;
                g_WPLinkCount[id]  = 0;
                g_WPDoorway[id]    = (doorFlag != 0);

                lastNodeId = id;
            }
        }
        continue;
    }

    // Links line: accepts both "links: 1 2" and "links 1 2"
    if (StrContains(line, "links", false) == 0 && lastNodeId != -1)
    {
        char pieces[16][16];
        int  count = ExplodeString(line, " ", pieces, sizeof(pieces), sizeof(pieces[]));

        // pieces[0] is "links" or "links:", neighbors start at index 1
        for (int i = 1; i < count; i++)
        {
            if (pieces[i][0] == '\0')
            {
                continue;
            }

            int other = StringToInt(pieces[i]);
            if (other < 0 || other >= MAX_WAYPOINTS)
            {
                continue;
            }

            if (edgeCount >= MAX_TEMP_EDGES)
            {
                continue;
            }

            int a = lastNodeId;
            int b = other;

            if (a == b)
            {
                continue;
            }

            edgeFrom[edgeCount] = a;
            edgeTo[edgeCount]   = b;
            edgeCount++;
        }

        continue;
    }
}

delete file;

// Now that all nodes are known, build the actual graph
for (int i = 0; i < edgeCount; i++)
{
    LinkWaypoints(edgeFrom[i], edgeTo[i]);
}

PrintToServer("[WP] Waypoints loaded from %s (nodes: %d, links: %d)",
              path,
              GetWaypointCount(),
              edgeCount);


}

// Helper to count used waypoints for debug print
static int GetWaypointCount()
{
int count = 0;
for (int i = 0; i < MAX_WAYPOINTS; i++)
{
if (g_WPUsed[i])
{
count++;
}
}
return count;
}

// ---------------------------------------------------------------------------
// Pathfinding (BFS)
// ---------------------------------------------------------------------------

static int BuildWaypointPath(int startId, int endId, int buffer[WP_PATH_MAX_NODES], int maxSize)
{
if (!IsValidWaypointId(startId) || !IsValidWaypointId(endId))
{
return 0;
}

if (startId == endId)
{
    if (maxSize >= 1)
    {
        buffer[0] = startId;
        return 1;
    }
    return 0;
}

int queue[MAX_WAYPOINTS];
int head = 0;
int tail = 0;

int parent[MAX_WAYPOINTS];
bool visited[MAX_WAYPOINTS];

for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    visited[i] = false;
    parent[i] = -1;
}

visited[startId] = true;
queue[tail++] = startId;

bool found = false;

while (head < tail)
{
    int current = queue[head++];

    if (current == endId)
    {
        found = true;
        break;
    }

    for (int i = 0; i < g_WPLinkCount[current]; i++)
    {
        int neighbor = g_WPLinks[current][i];
        if (!IsValidWaypointId(neighbor))
        {
            continue;
        }

        if (!visited[neighbor])
        {
            visited[neighbor] = true;
            parent[neighbor] = current;
            queue[tail++] = neighbor;
        }
    }
}

if (!found)
{
    return 0;
}

int pathNodes[WP_PATH_MAX_NODES];
int pathLength = 0;

int node = endId;
while (node != -1 && pathLength < WP_PATH_MAX_NODES)
{
    pathNodes[pathLength++] = node;
    node = parent[node];
}

if (node != -1)
{
    return 0;
}

if (pathLength > maxSize)
{
    pathLength = maxSize;
}

for (int i = 0; i < pathLength; i++)
{
    buffer[i] = pathNodes[pathLength - 1 - i];
}

return pathLength;


}

// ---------------------------------------------------------------------------
// Tempent setup and drawing
// ---------------------------------------------------------------------------

static void PrecacheTempEntSprites()
{
g_iBeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
g_iHaloSprite = PrecacheModel("materials/sprites/light_glow03.vmt");
}

void DrawWaypointsForClient(int client)
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

// Determine which nodes are within FOV, draw distance, and same floor
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

    float dz = toNode[2];
    if (dz > NODE_FLOOR_DELTA_MAX || dz < -NODE_FLOOR_DELTA_MAX)
    {
        continue;
    }

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

// Draw links (white beams), only when both endpoints are visible
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

        if (!visible[i] || !visible[other])
        {
            continue;
        }

        CopyVector(g_WPOrigin[i], start);
        CopyVector(g_WPOrigin[other], end);
        start[2] += 10.0;
        end[2]   += 10.0;

        // Thinner link beam
        TE_SetupBeamPoints(start, end, g_iBeamSprite, 0,
                           0, 0, 0.30, 0.8, 0.6, 0, 0.0, linkColor, 0);
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
    //  - Doorway: Orange (when not aimed/selected)
    if (i == selected)
    {
        color[0] = 255; color[1] = 0;   color[2] = 0;   color[3] = 255;
    }
    else if (i == aimed)
    {
        color[0] = 128; color[1] = 255; color[2] = 0;   color[3] = 255;
    }
    else if (g_WPDoorway[i])
    {
        color[0] = 255; color[1] = 165; color[2] = 0;   color[3] = 255;
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

    // Pulsing thickness, reduced base + amplitude
    float pulse         = Sine(time * 8.0) * 2.0;
    float baseWidth     = 1.2;
    float baseEndWidth  = 1.6;
    float width         = baseWidth + pulse;
    float endWidth      = baseEndWidth + pulse;
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

    // Narrower ring width
    TE_SetupBeamRingPoint(
        ringOrigin,
        ringRadius - 2.0,
        ringRadius + 2.0,
        g_iBeamSprite,
        g_iHaloSprite,
        0,
        0,
        0.40,
        2.0,   // width
        0.0,
        ringColor,
        0,
        0
    );
    TE_SendToClient(client);
}


}

// Trace filter: ignore players (including the client) so the ray hits world/props.
public bool TraceEntityFilterPlayers(int entity, int contentsMask, any data)
{
int client = view_as<int>(data);

if (entity == client)
{
    return false;
}

if (entity >= 1 && entity <= MaxClients)
{
    return false;
}

return true;


}

// ---------------------------------------------------------------------------
// Aiming + periodic draw timer
// ---------------------------------------------------------------------------

static int FindAimedWaypoint(int client)
{
float eye[3];
float ang[3];
float fwd[3];

GetClientEyePosition(client, eye);
GetClientEyeAngles(client, ang);
GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);

float end[3];
end[0] = eye[0] + fwd[0] * WP_AIM_MAX_DIST;
end[1] = eye[1] + fwd[1] * WP_AIM_MAX_DIST;
end[2] = eye[2] + fwd[2] * WP_AIM_MAX_DIST;

Handle trace = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint, TraceEntityFilterPlayers, client);

if (trace != null)
{
    float hitPos[3];
    TR_GetEndPosition(hitPos, trace);
    delete trace;

    int best = -1;
    float bestDistSq = WP_AIM_MAX_DIST * WP_AIM_MAX_DIST;

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_WPUsed[i])
        {
            continue;
        }

        float dx = g_WPOrigin[i][0] - hitPos[0];
        float dy = g_WPOrigin[i][1] - hitPos[1];
        float dz = g_WPOrigin[i][2] - hitPos[2];

        float distSq = dx*dx + dy*dy + dz*dz;
        if (distSq < bestDistSq)
        {
            bestDistSq = distSq;
            best = i;
        }
    }

    return best;
}

return -1;


}

public Action Timer_UpdateAimAndDraw(Handle timer)
{
for (int client = 1; client <= MaxClients; client++)
{
if (!IsClientInGame(client) || !IsPlayerAlive(client))
{
g_AimedNode[client] = -1;
continue;
}

    if (g_EditorOpen[client])
    {
        g_AimedNode[client] = FindAimedWaypoint(client);
        DrawWaypointsForClient(client);
    }
    else
    {
        g_AimedNode[client] = -1;
    }
}

return Plugin_Continue;


}

// ---------------------------------------------------------------------------
// Editor command + menu
// ---------------------------------------------------------------------------

public void ShowWaypointMenu(int client);

public Action Command_WaypointEditor(int client, int args)
{
if (client <= 0 || !IsClientInGame(client))
{
return Plugin_Handled;
}

if ((GetUserFlagBits(client) & ADMFLAG_ROOT) == 0)
{
    PrintToChat(client, "[WP] You do not have permission to use the waypoint editor.");
    return Plugin_Handled;
}

if (!g_EditorOpen[client])
{
    LoadWaypointsFromFile();

    g_EditorOpen[client] = true;
    g_AimedNode[client] = -1;
    g_SelectedNode[client] = -1;

    PrintToChat(client, "[WP] Editor opened.");
    ShowWaypointMenu(client);
}
else
{
    g_EditorOpen[client] = false;
    g_AimedNode[client] = -1;
    g_SelectedNode[client] = -1;

    PrintToChat(client, "[WP] Editor closed.");
}

return Plugin_Handled;


}

public void ShowWaypointMenu(int client)
{
Menu menu = new Menu(MenuHandler_WaypointEditor);
menu.SetTitle("Waypoint Editor");

menu.AddItem("add_node",         "Add node at player");
menu.AddItem("remove_aimed",     "Remove aimed node");
menu.AddItem("select_link",      "Select/link via aimed node");
menu.AddItem("toggle_doorway",   "Toggle doorway flag on aimed node");
menu.AddItem("clear_selection",  "Clear selection");
menu.AddItem("save",             "Save waypoints");
menu.AddItem("close",            "Close editor");

menu.Display(client, 20);


}

public int MenuHandler_WaypointEditor(Menu menu, MenuAction action, int client, int param)
{
if (action == MenuAction_End)
{
delete menu;
return 0;
}

if (action != MenuAction_Select)
{
    return 0;
}

char info[32];
menu.GetItem(param, info, sizeof(info));

if (StrEqual(info, "add_node"))
{
    float pos[3];
    GetClientAbsOrigin(client, pos);

    int id = AllocateWaypoint(pos);
    if (id == -1)
    {
        PrintToChat(client, "[WP] Failed to allocate new waypoint (max %d).", MAX_WAYPOINTS);
    }
    else
    {
        PrintToChat(client, "[WP] Added waypoint %d at your position.", id);
    }

    ShowWaypointMenu(client);
}
else if (StrEqual(info, "remove_aimed"))
{
    int aimed = g_AimedNode[client];
    if (aimed == -1 || !IsValidWaypointId(aimed))
    {
        PrintToChat(client, "[WP] No aimed waypoint to remove.");
    }
    else
    {
        DeleteWaypoint(aimed);
        PrintToChat(client, "[WP] Removed waypoint %d.", aimed);
    }

    ShowWaypointMenu(client);
}
else if (StrEqual(info, "select_link"))
{
    int aimed = g_AimedNode[client];
    if (aimed == -1 || !IsValidWaypointId(aimed))
    {
        PrintToChat(client, "[WP] Aim at a waypoint first.");
        ShowWaypointMenu(client);
        return 0;
    }

    int selected = g_SelectedNode[client];
    if (selected == -1)
    {
        g_SelectedNode[client] = aimed;
        PrintToChat(client, "[WP] Selected waypoint %d.", aimed);
    }
    else if (selected == aimed)
    {
        PrintToChat(client, "[WP] Already selected waypoint %d.", aimed);
    }
    else
    {
        bool linked = false;
        for (int i = 0; i < g_WPLinkCount[selected]; i++)
        {
            if (g_WPLinks[selected][i] == aimed)
            {
                linked = true;
                break;
            }
        }

        if (linked)
        {
            UnlinkWaypoints(selected, aimed);
            PrintToChat(client, "[WP] Unlinked %d <-> %d.", selected, aimed);
        }
        else
        {
            if (LinkWaypoints(selected, aimed))
            {
                PrintToChat(client, "[WP] Linked %d <-> %d.", selected, aimed);
            }
            else
            {
                PrintToChat(client, "[WP] Failed to link %d <-> %d (link capacity).", selected, aimed);
            }
        }

        g_SelectedNode[client] = aimed;
    }

    ShowWaypointMenu(client);
}
else if (StrEqual(info, "toggle_doorway"))
{
    int aimed = g_AimedNode[client];
    if (aimed == -1 || !IsValidWaypointId(aimed))
    {
        PrintToChat(client, "[WP] Aim at a waypoint first.");
    }
    else
    {
        g_WPDoorway[aimed] = !g_WPDoorway[aimed];
        PrintToChat(client, "[WP] Waypoint %d doorway flag is now: %s.", aimed, g_WPDoorway[aimed] ? "ON" : "OFF");
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
    SaveWaypointsToFile();
    PrintToChat(client, "[WP] Waypoints saved.");
    ShowWaypointMenu(client);
}
else if (StrEqual(info, "close"))
{
    g_EditorOpen[client] = false;
    g_AimedNode[client] = -1;
    g_SelectedNode[client] = -1;
    PrintToChat(client, "[WP] Editor closed.");
}

return 0;


}

// ---------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------

public any Native_Waypoint_FindNearestToClient(Handle plugin, int numParams)
{
int client = GetNativeCell(1);

if (client <= 0 || !IsClientInGame(client))
{
    return -1;
}

float origin[3];
GetClientAbsOrigin(client, origin);

float bestDistSq = 0.0;
int   bestId     = -1;

for (int i = 0; i < MAX_WAYPOINTS; i++)
{
    if (!g_WPUsed[i])
    {
        continue;
    }

    float dx = g_WPOrigin[i][0] - origin[0];
    float dy = g_WPOrigin[i][1] - origin[1];
    float dz = g_WPOrigin[i][2] - origin[2];

    float distSq = dx*dx + dy*dy + dz*dz;
    if (bestId == -1 || distSq < bestDistSq)
    {
        bestDistSq = distSq;
        bestId = i;
    }
}

return bestId;


}

public any Native_Waypoint_GetPath(Handle plugin, int numParams)
{
int startId = GetNativeCell(1);
int endId = GetNativeCell(2);

int maxSize = GetNativeCell(4);
if (maxSize <= 0)
{
    return 0;
}

int temp[WP_PATH_MAX_NODES];
int length = BuildWaypointPath(startId, endId, temp, sizeof(temp));

if (length <= 0)
{
    return 0;
}

if (length > maxSize)
{
    length = maxSize;
}

// Copy path back to caller (3rd native parameter = buffer)
SetNativeArray(3, temp, length);

return length;


}

public any Native_Waypoint_GetOrigin(Handle plugin, int numParams)
{
int id = GetNativeCell(1);

if (!IsValidWaypointId(id))
{
    return false;
}

// Copy 3 floats into the caller's float[3] array (2nd param)
SetNativeArray(2, g_WPOrigin[id], 3);

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
RegAdminCmd("sm_wp", Command_WaypointEditor, ADMFLAG_ROOT, "Open/close the waypoint editor.");

PrecacheTempEntSprites();

g_hAimTimer = CreateTimer(0.25, Timer_UpdateAimAndDraw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

RegPluginLibrary("waypoint_logic");
CreateNative("Waypoint_FindNearestToClient", Native_Waypoint_FindNearestToClient);
CreateNative("Waypoint_GetPath",            Native_Waypoint_GetPath);
CreateNative("Waypoint_GetOrigin",          Native_Waypoint_GetOrigin);
CreateNative("Waypoint_IsDoorway",          Native_Waypoint_IsDoorway);


}

public void OnMapStart()
{
PrecacheTempEntSprites();
}

public void OnPluginEnd()
{
if (g_hAimTimer != INVALID_HANDLE)
{
KillTimer(g_hAimTimer);
g_hAimTimer = INVALID_HANDLE;
}
}