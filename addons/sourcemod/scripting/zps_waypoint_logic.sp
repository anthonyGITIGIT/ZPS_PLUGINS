#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define MAX_WAYPOINTS 512
#define MAX_LINKS_PER_WAYPOINT 8
#define WAYPOINT_FILE_DIR "addons/sourcemod/data/zps_waypoints"

#define DRAW_INTERVAL 0.25
#define WAYPOINT_SELECT_RADIUS 120.0
#define WAYPOINT_REACH_DISTANCE 80.0

#define FLAG_GENERIC 1

int g_iWaypointCount;
bool g_bWaypointUsed[MAX_WAYPOINTS];
float g_fWaypointPos[MAX_WAYPOINTS][3];
int g_iWaypointFlags[MAX_WAYPOINTS];
int g_iLinkCount[MAX_WAYPOINTS];
int g_iLinks[MAX_WAYPOINTS][MAX_LINKS_PER_WAYPOINT];
char g_sMapName[PLATFORM_MAX_PATH];

int g_iSelectedWp[MAXPLAYERS + 1];
bool g_bDrawEnabled[MAXPLAYERS + 1];
Handle g_hDrawTimer = INVALID_HANDLE;
int g_iBeamModel;
int g_iHaloModel;
bool g_bMapInitialized;

public Plugin myinfo = {
    name = "ZPS Waypoint Logic",
    author = "ChatGPT",
    description = "Waypoint editor and pathfinding for ZPS bots",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart()
{
    RegPluginLibrary("zps_waypoint_logic");

    CreateNative("Waypoint_GetNearestToPosition", Native_GetNearestToPosition);
    CreateNative("Waypoint_GetNearestToPlayer", Native_GetNearestToPlayer);
    CreateNative("Waypoint_GetPosition", Native_GetPosition);
    CreateNative("Waypoint_GetNextOnPath", Native_GetNextOnPath);

    RegAdminCmd("sm_wp", Command_WaypointMenu, ADMFLAG_GENERIC, "Open waypoint editor menu");
    RegAdminCmd("sm_wp_draw", Command_DrawToggle, ADMFLAG_GENERIC, "Toggle waypoint drawing");

    ClearWaypoints();
    g_bMapInitialized = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iSelectedWp[i] = -1;
    }
}

public void OnMapStart()
{
    g_bMapInitialized = false;
    InitializeMapData();
}

public void OnMapEnd()
{
    if (g_hDrawTimer != INVALID_HANDLE)
    {
        CloseHandle(g_hDrawTimer);
        g_hDrawTimer = INVALID_HANDLE;
    }
}

public void OnClientDisconnect(int client)
{
    g_bDrawEnabled[client] = false;
    g_iSelectedWp[client] = -1;
}

public void OnConfigsExecuted()
{
    InitializeMapData();
}

// =============================
// Native registration
// =============================
public int Native_GetNearestToPosition(Handle plugin, int numParams)
{
    float origin[3];
    GetNativeArray(1, origin, 3);
    int id = FindNearestWaypoint(origin);
    return id;
}

public int Native_GetNearestToPlayer(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (!IsClientInGame(client))
    {
        return -1;
    }
    float origin[3];
    GetClientAbsOrigin(client, origin);
    return FindNearestWaypoint(origin);
}

public int Native_GetPosition(Handle plugin, int numParams)
{
    int id = GetNativeCell(1);
    float origin[3];
    bool ok = GetWaypointPosition(id, origin);
    SetNativeArray(2, origin, 3);
    return ok;
}

public int Native_GetNextOnPath(Handle plugin, int numParams)
{
    int fromId = GetNativeCell(1);
    int toId = GetNativeCell(2);
    return GetNextOnPath(fromId, toId);
}

// =============================
// Command handlers
// =============================
public Action Command_WaypointMenu(int client, int args)
{
    if (!IsValidAdmin(client))
    {
        return Plugin_Handled;
    }

    InitializeMapData();
    g_bDrawEnabled[client] = true;
    EnsureDrawTimer();
    ShowWaypointMenu(client);
    return Plugin_Handled;
}

public Action Command_DrawToggle(int client, int args)
{
    if (!IsValidAdmin(client))
    {
        return Plugin_Handled;
    }

    InitializeMapData();

    g_bDrawEnabled[client] = !g_bDrawEnabled[client];
    if (g_bDrawEnabled[client])
    {
        PrintToChat(client, "[WP] Drawing enabled.");
        EnsureDrawTimer();
    }
    else
    {
        PrintToChat(client, "[WP] Drawing disabled.");
    }
    return Plugin_Handled;
}

// =============================
// Menu
// =============================
void ShowWaypointMenu(int client)
{
    InitializeMapData();
    g_bDrawEnabled[client] = true;
    EnsureDrawTimer();

    Menu menu = new Menu(MenuHandler_Waypoint);
    char title[64];
    if (g_iSelectedWp[client] != -1)
    {
        Format(title, sizeof(title), "Waypoint Editor (Selected: %d)", g_iSelectedWp[client]);
    }
    else
    {
        strcopy(title, sizeof(title), "Waypoint Editor (No selection)");
    }
    menu.SetTitle(title);

    menu.AddItem("add", "Add waypoint here");
    menu.AddItem("remove", "Remove aimed waypoint");
    menu.AddItem("select", "Select aimed waypoint");
    menu.AddItem("link", "Link selected -> aimed");
    menu.AddItem("unlink", "Unlink selected -> aimed");
    menu.AddItem("save", "Save waypoints");
    menu.AddItem("reload", "Reload waypoints");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Waypoint(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "add"))
        {
            float origin[3];
            GetClientAbsOrigin(client, origin);
            int id = AddWaypoint(origin, FLAG_GENERIC);
            if (id != -1)
            {
                PrintToChat(client, "[WP] Added waypoint %d.", id);
            }
            else
            {
                PrintToChat(client, "[WP] Failed to add waypoint (limit reached).");
            }
        }
        else if (StrEqual(info, "remove"))
        {
            int target = GetWaypointPlayerIsAiming(client);
            if (target != -1)
            {
                RemoveWaypoint(target);
                PrintToChat(client, "[WP] Removed waypoint %d.", target);
                if (g_iSelectedWp[client] == target)
                {
                    g_iSelectedWp[client] = -1;
                }
            }
            else
            {
                PrintToChat(client, "[WP] No waypoint in sight to remove.");
            }
        }
        else if (StrEqual(info, "select"))
        {
            int target = GetWaypointPlayerIsAiming(client);
            if (target != -1)
            {
                g_iSelectedWp[client] = target;
                PrintToChat(client, "[WP] Selected waypoint %d.", target);
            }
            else
            {
                PrintToChat(client, "[WP] No waypoint in sight to select.");
            }
        }
        else if (StrEqual(info, "link"))
        {
            int selected = g_iSelectedWp[client];
            int target = GetWaypointPlayerIsAiming(client);
            if (selected == -1 || target == -1)
            {
                PrintToChat(client, "[WP] Need both selected and aimed waypoints.");
            }
            else if (selected == target)
            {
                PrintToChat(client, "[WP] Cannot link waypoint to itself.");
            }
            else if (LinkWaypoints(selected, target))
            {
                PrintToChat(client, "[WP] Linked %d <-> %d.", selected, target);
            }
            else
            {
                PrintToChat(client, "[WP] Failed to link (maybe already linked or full).");
            }
        }
        else if (StrEqual(info, "unlink"))
        {
            int selected = g_iSelectedWp[client];
            int target = GetWaypointPlayerIsAiming(client);
            if (selected == -1 || target == -1)
            {
                PrintToChat(client, "[WP] Need both selected and aimed waypoints.");
            }
            else if (UnlinkWaypoints(selected, target))
            {
                PrintToChat(client, "[WP] Unlinked %d <-> %d.", selected, target);
            }
            else
            {
                PrintToChat(client, "[WP] No link existed between %d and %d.", selected, target);
            }
        }
        else if (StrEqual(info, "save"))
        {
            if (SaveWaypointsForMap())
            {
                PrintToChat(client, "[WP] Waypoints saved.");
            }
            else
            {
                PrintToChat(client, "[WP] Failed to save waypoints.");
            }
        }
        else if (StrEqual(info, "reload"))
        {
            if (LoadWaypointsForMap())
            {
                PrintToChat(client, "[WP] Waypoints reloaded.");
            }
            else
            {
                PrintToChat(client, "[WP] Failed to load waypoints.");
            }
        }

        ShowWaypointMenu(client);
    }
    return 0;
}

bool IsValidAdmin(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }
    if (!CheckCommandAccess(client, "sm_wp", ADMFLAG_GENERIC, true))
    {
        return false;
    }
    return true;
}

// =============================
// Waypoint helpers
// =============================
void ClearWaypoints()
{
    g_iWaypointCount = 0;
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        g_bWaypointUsed[i] = false;
        g_iWaypointFlags[i] = 0;
        g_iLinkCount[i] = 0;
        for (int j = 0; j < MAX_LINKS_PER_WAYPOINT; j++)
        {
            g_iLinks[i][j] = -1;
        }
    }
}

int AddWaypoint(const float origin[3], int flags)
{
    int id = -1;
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            id = i;
            break;
        }
    }

    if (id == -1)
    {
        return -1;
    }

    g_bWaypointUsed[id] = true;
    g_iWaypointFlags[id] = flags;
    g_iLinkCount[id] = 0;
    g_fWaypointPos[id][0] = origin[0];
    g_fWaypointPos[id][1] = origin[1];
    g_fWaypointPos[id][2] = origin[2];

    if (id >= g_iWaypointCount)
    {
        g_iWaypointCount = id + 1;
    }

    return id;
}

void RemoveWaypoint(int id)
{
    if (id < 0 || id >= MAX_WAYPOINTS || !g_bWaypointUsed[id])
    {
        return;
    }

    // Remove links referencing this waypoint
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            continue;
        }
        UnlinkWaypoints(i, id);
    }

    g_bWaypointUsed[id] = false;
    g_iLinkCount[id] = 0;
}

bool LinkWaypoints(int a, int b)
{
    if (!IsValidWaypoint(a) || !IsValidWaypoint(b))
    {
        return false;
    }

    if (AreWaypointsLinked(a, b))
    {
        return false;
    }

    if (g_iLinkCount[a] >= MAX_LINKS_PER_WAYPOINT || g_iLinkCount[b] >= MAX_LINKS_PER_WAYPOINT)
    {
        return false;
    }

    g_iLinks[a][g_iLinkCount[a]++] = b;
    g_iLinks[b][g_iLinkCount[b]++] = a;
    return true;
}

bool UnlinkWaypoints(int a, int b)
{
    if (!IsValidWaypoint(a) || !IsValidWaypoint(b))
    {
        return false;
    }

    bool removed = false;
    for (int i = 0; i < g_iLinkCount[a]; i++)
    {
        if (g_iLinks[a][i] == b)
        {
            for (int j = i; j < g_iLinkCount[a] - 1; j++)
            {
                g_iLinks[a][j] = g_iLinks[a][j + 1];
            }
            g_iLinks[a][g_iLinkCount[a] - 1] = -1;
            g_iLinkCount[a]--;
            removed = true;
            break;
        }
    }

    for (int i = 0; i < g_iLinkCount[b]; i++)
    {
        if (g_iLinks[b][i] == a)
        {
            for (int j = i; j < g_iLinkCount[b] - 1; j++)
            {
                g_iLinks[b][j] = g_iLinks[b][j + 1];
            }
            g_iLinks[b][g_iLinkCount[b] - 1] = -1;
            g_iLinkCount[b]--;
            removed = true;
            break;
        }
    }

    return removed;
}

bool AreWaypointsLinked(int a, int b)
{
    if (!IsValidWaypoint(a) || !IsValidWaypoint(b))
    {
        return false;
    }

    for (int i = 0; i < g_iLinkCount[a]; i++)
    {
        if (g_iLinks[a][i] == b)
        {
            return true;
        }
    }
    return false;
}

bool IsValidWaypoint(int id)
{
    return (id >= 0 && id < MAX_WAYPOINTS && g_bWaypointUsed[id]);
}

int FindNearestWaypoint(const float origin[3])
{
    float bestDist = -1.0;
    int bestId = -1;

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            continue;
        }
        float d = GetVectorDistance(origin, g_fWaypointPos[i]);
        if (bestDist < 0.0 || d < bestDist)
        {
            bestDist = d;
            bestId = i;
        }
    }
    return bestId;
}

bool GetWaypointPosition(int id, float origin[3])
{
    if (!IsValidWaypoint(id))
    {
        return false;
    }
    origin[0] = g_fWaypointPos[id][0];
    origin[1] = g_fWaypointPos[id][1];
    origin[2] = g_fWaypointPos[id][2];
    return true;
}

int GetWaypointPlayerIsAiming(int client)
{
    float eye[3];
    float angles[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, angles);

    float end[3];
    TR_TraceRayFilter(eye, angles, MASK_SOLID, RayType_Infinite, TraceEntityFilterPlayers, client);
    TR_GetEndPosition(end);

    int nearest = -1;
    float bestDist = WAYPOINT_SELECT_RADIUS * WAYPOINT_SELECT_RADIUS;
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            continue;
        }
        float d = GetVectorDistance(end, g_fWaypointPos[i]);
        if (d <= WAYPOINT_SELECT_RADIUS && d < bestDist)
        {
            bestDist = d;
            nearest = i;
        }
    }

    if (nearest == -1)
    {
        // Try a direct distance check to player position
        float origin[3];
        GetClientAbsOrigin(client, origin);
        for (int i = 0; i < MAX_WAYPOINTS; i++)
        {
            if (!g_bWaypointUsed[i])
            {
                continue;
            }
            float d = GetVectorDistance(origin, g_fWaypointPos[i]);
            if (d <= WAYPOINT_SELECT_RADIUS && (nearest == -1 || d < bestDist))
            {
                bestDist = d;
                nearest = i;
            }
        }
    }
    return nearest;
}

public bool TraceEntityFilterPlayers(int entity, int contentsMask, any data)
{
    int ignore = data;
    if (entity == ignore)
    {
        return false;
    }
    if (entity >= 1 && entity <= MaxClients)
    {
        return false;
    }
    return true;
}

// =============================
// Pathfinding
// =============================
int GetNextOnPath(int fromId, int toId)
{
    if (!IsValidWaypoint(fromId) || !IsValidWaypoint(toId))
    {
        return -1;
    }
    if (fromId == toId)
    {
        return toId;
    }

    float dist[MAX_WAYPOINTS];
    int prev[MAX_WAYPOINTS];
    bool visited[MAX_WAYPOINTS];

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        dist[i] = -1.0;
        prev[i] = -1;
        visited[i] = false;
    }

    dist[fromId] = 0.0;

    for (int iter = 0; iter < MAX_WAYPOINTS; iter++)
    {
        int current = -1;
        float best = -1.0;
        for (int i = 0; i < MAX_WAYPOINTS; i++)
        {
            if (!g_bWaypointUsed[i] || visited[i] || dist[i] < 0.0)
            {
                continue;
            }
            if (best < 0.0 || dist[i] < best)
            {
                best = dist[i];
                current = i;
            }
        }

        if (current == -1)
        {
            break;
        }
        if (current == toId)
        {
            break;
        }

        visited[current] = true;

        for (int j = 0; j < g_iLinkCount[current]; j++)
        {
            int neighbor = g_iLinks[current][j];
            if (!IsValidWaypoint(neighbor))
            {
                continue;
            }
            float cost = GetVectorDistance(g_fWaypointPos[current], g_fWaypointPos[neighbor]);
            float newDist = dist[current] + cost;
            if (dist[neighbor] < 0.0 || newDist < dist[neighbor])
            {
                dist[neighbor] = newDist;
                prev[neighbor] = current;
            }
        }
    }

    if (prev[toId] == -1)
    {
        return -1;
    }

    int step = toId;
    while (prev[step] != -1 && prev[step] != fromId)
    {
        step = prev[step];
    }

    if (prev[step] == -1)
    {
        return -1;
    }
    return step;
}

// =============================
// Storage
// =============================

bool SaveWaypointsForMap()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s/%s.cfg", WAYPOINT_FILE_DIR, g_sMapName);

    File file = OpenFile(path, "w");
    if (file == null)
    {
        return false;
    }

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            continue;
        }
        WriteWaypointLine(file, i);
    }

    delete file;
    return true;
}

bool LoadWaypointsForMap()
{
    char path[PLATFORM_MAX_PATH];
    GetCurrentMap(g_sMapName, sizeof(g_sMapName));
    BuildPath(Path_SM, path, sizeof(path), "%s/%s.cfg", WAYPOINT_FILE_DIR, g_sMapName);

    if (!FileExists(path))
    {
        ClearWaypoints();
        return true;
    }

    File file = OpenFile(path, "r");
    if (file == null)
    {
        return false;
    }

    ClearWaypoints();

    char line[256];
    while (!file.EndOfFile())
    {
        file.ReadLine(line, sizeof(line));
        TrimString(line);
        if (line[0] == '\0' || line[0] == ';' || line[0] == '#')
        {
            continue;
        }
        ParseWaypointLine(line);
    }

    delete file;
    return true;
}

void WriteWaypointLine(File file, int id)
{
    char buffer[256];
    Format(buffer, sizeof(buffer), "%d %.2f %.2f %.2f %d %d", id, g_fWaypointPos[id][0], g_fWaypointPos[id][1], g_fWaypointPos[id][2], g_iWaypointFlags[id], g_iLinkCount[id]);

    for (int i = 0; i < g_iLinkCount[id]; i++)
    {
        Format(buffer, sizeof(buffer), "%s %d", buffer, g_iLinks[id][i]);
    }
    file.WriteLine(buffer);
}

void ParseWaypointLine(const char[] line)
{
    char tokens[16][16];
    int items = ExplodeString(line, " ", tokens, sizeof(tokens), sizeof(tokens[]));
    if (items < 6)
    {
        return;
    }

    int id = StringToInt(tokens[0]);
    if (id < 0 || id >= MAX_WAYPOINTS)
    {
        return;
    }

    float pos[3];
    pos[0] = StringToFloat(tokens[1]);
    pos[1] = StringToFloat(tokens[2]);
    pos[2] = StringToFloat(tokens[3]);
    int flags = StringToInt(tokens[4]);
    int linkCount = StringToInt(tokens[5]);

    if (!g_bWaypointUsed[id])
    {
        g_bWaypointUsed[id] = true;
        g_iWaypointFlags[id] = flags;
        g_fWaypointPos[id][0] = pos[0];
        g_fWaypointPos[id][1] = pos[1];
        g_fWaypointPos[id][2] = pos[2];
        if (id >= g_iWaypointCount)
        {
            g_iWaypointCount = id + 1;
        }
    }

    g_iLinkCount[id] = 0;
    for (int i = 0; i < linkCount && (6 + i) < items && i < MAX_LINKS_PER_WAYPOINT; i++)
    {
        int neighbor = StringToInt(tokens[6 + i]);
        if (neighbor >= 0 && neighbor < MAX_WAYPOINTS)
        {
            g_iLinks[id][g_iLinkCount[id]++] = neighbor;
        }
    }
}

// =============================
// Drawing
// =============================
void EnsureDrawTimer()
{
    InitializeMapData();

    if (g_hDrawTimer == INVALID_HANDLE)
    {
        g_hDrawTimer = CreateTimer(DRAW_INTERVAL, Timer_DrawWaypoints, _, TIMER_REPEAT);
    }
}

public Action Timer_DrawWaypoints(Handle timer, any data)
{
    bool any = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bDrawEnabled[i] && IsClientInGame(i))
        {
            DrawWaypointsForClient(i);
            any = true;
        }
    }

    if (!any)
    {
        g_hDrawTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

void DrawWaypointsForClient(int client)
{
    int count = 0;
    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (g_bWaypointUsed[i])
        {
            count++;
        }
    }
    if (count == 0)
    {
        return;
    }

    int colorNode[4] = {0, 200, 255, 255};
    int colorLink[4] = {0, 255, 0, 255};

    for (int i = 0; i < MAX_WAYPOINTS; i++)
    {
        if (!g_bWaypointUsed[i])
        {
            continue;
        }
        float start[3];
        start[0] = g_fWaypointPos[i][0];
        start[1] = g_fWaypointPos[i][1];
        start[2] = g_fWaypointPos[i][2] + 10.0;

        TE_SetupBeamRingPoint(start, 8.0, 32.0, g_iBeamModel, g_iHaloModel, 0, 10, DRAW_INTERVAL, 2.0, 0.0, colorNode, 10, 0);
        TE_SendToClient(client);

        for (int j = 0; j < g_iLinkCount[i]; j++)
        {
            int target = g_iLinks[i][j];
            if (!IsValidWaypoint(target) || target <= i)
            {
                continue; // avoid duplicate lines
            }
            float end[3];
            end[0] = g_fWaypointPos[target][0];
            end[1] = g_fWaypointPos[target][1];
            end[2] = g_fWaypointPos[target][2] + 10.0;

            TE_SetupBeamPoints(start, end, g_iBeamModel, g_iHaloModel, 0, 10, DRAW_INTERVAL, 4.0, 4.0, 0, 0.0, colorLink, 20);
            TE_SendToClient(client);
        }
    }
}

void Precache()
{
    if (g_iBeamModel == 0)
    {
        g_iBeamModel = PrecacheModel("materials/sprites/laserbeam.vmt");
    }
    if (g_iHaloModel == 0)
    {
        g_iHaloModel = PrecacheModel("materials/sprites/halo01.vmt");
    }
}

// =============================
// Utility
// =============================
void InitializeMapData()
{
    if (g_bMapInitialized)
    {
        return;
    }

    GetCurrentMap(g_sMapName, sizeof(g_sMapName));
    CreateDirectory(WAYPOINT_FILE_DIR, 511);
    Precache();
    LoadWaypointsForMap();

    g_bMapInitialized = true;
}
