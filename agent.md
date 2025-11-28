This document explains how the project is structured and how you, as a GPT-based coding agent (Codex / GitHub agent), should work with it.

The project is a SourceMod plugin suite for Zombie Panic! Source, implementing a custom zombie bot framework using three cooperating plugins.

1. Quick-start checklist for the agent

Before making any changes:

Open and read these files from the plugins/ folder in the repository:

plugins/zps_waypoint_logic.sp

plugins/zps_bot_logic.sp

plugins/zps_director_logic.sp

Treat those files as the single source of truth.
Do not rely on outdated snippets or assumptions.

When the user requests changes:

First summarize a concrete plan (what you will change, in which file).

Wait for the user to confirm the plan.

Only then modify code.

Never change the signatures or semantics of the public natives/forwards:

Waypoint_* (from zps_waypoint_logic.sp)

BotLogic_* (from zps_bot_logic.sp)

Director commands/events in zps_director_logic.sp

The framework depends on these interfaces staying stable.

2. High-level architecture

The project consists of three SourceMod plugins that work together via natives and forwards:

zps_waypoint_logic.sp

Maintains a per-map waypoint graph in memory.

Provides an in-game waypoint editor (sm_wp) with visual debug drawing.

Handles saving/loading waypoints to disk.

Exposes a pathfinding API (Waypoint_* natives) for other plugins.

zps_bot_logic.sp

Implements per-bot “brain” logic.

Maintains bot states, targets, and paths.

Decides between direct chase and waypoint-based pathing.

Implements stuck detection and recovery.

Drives movement through OnPlayerRunCmd.

zps_director_logic.sp

Spawns and manages custom zombie fake clients.

Registers/unregisters bots with zps_bot_logic.sp.

Future home for “director” logic (waves, difficulty, etc.).

Data flow:

zps_director_logic.sp → uses BotLogic_* natives → zps_bot_logic.sp.

zps_bot_logic.sp → uses Waypoint_* natives → zps_waypoint_logic.sp.

zps_waypoint_logic.sp → standalone; only exposes natives, no direct dependency on the others.

All logic is for custom fake-client zombies only (not human players, not stock bots).

3. Waypoint system (zps_waypoint_logic.sp)
3.1 Core data model

Global arrays (size MAX_WAYPOINTS = 512):

g_WPUsed[id] — slot in use.

g_WPOrigin[id][3] — world position.

g_WPLinks[id][MAX_LINKS_PER_WP] — adjacency list.

g_WPLinkCount[id] — number of active links for each node.

g_WPDoorway[id] — whether this node is a special “doorway” node.

Doorway nodes:

Used by bot logic to enforce precise door crossing.

Doorway nodes have tighter arrival radius and distinct visual representation.

Per-client editor state:

g_EditorOpen[client] — true when the waypoint editor is active.

g_AimedNode[client] — waypoint currently under crosshair.

g_SelectedNode[client] — active selection for linking/unlinking.

3.2 Save/load

File path:

Waypoints are stored under:

addons/sourcemod/data/<mapname>_waypoints.cfg

Save format:

Header comments.

nodes <count> line.

For each node:

node <id> <x> <y> <z> <doorFlag>
links: <neighborId> <neighborId> ...


For links, only neighbors other >= id are written to avoid duplicating undirected edges.

Load logic:

Uses two-pass parsing with temporary edge buffers:

Pass 1: parse node lines; fill g_WPUsed, g_WPOrigin, g_WPDoorway, reset link counts.

Pass 2: parse links lines; store edge pairs (from, to) into local arrays.

After reading the whole file, iterate collected edges and call LinkWaypoints(from, to) to rebuild adjacency lists.

#pragma dynamic 65536 is used to give enough heap for temporary arrays (visited[], parent[], edge arrays, etc.).

This design prevents the “links disappear after load” bug that happens when trying to link nodes before all of them are known.

3.3 Pathfinding API

Path is built via BFS:

BuildWaypointPath(int startId, int endId, int buffer[WP_PATH_MAX_NODES], int maxSize):

Standard BFS over g_WPLinks/g_WPLinkCount.

Uses arrays:

queue[MAX_WAYPOINTS]

visited[MAX_WAYPOINTS]

parent[MAX_WAYPOINTS]

After BFS:

Backtrack from endId through parent[] into a temporary path list.

Reverse into the output buffer.

Returns path length (clamped by maxSize), or 0 on failure.

Natives exposed to other plugins:

Waypoint_FindNearestToClient(int client)

Returns nearest waypoint id to GetClientAbsOrigin(client) or -1.

Waypoint_GetPath(int startId, int endId, int[] buffer, int maxSize)

Wraps BFS and writes the path into the caller’s array via SetNativeArray.

Waypoint_GetOrigin(int id, float pos[3])

Copies waypoint origin to caller, returns true on success.

Waypoint_IsDoorway(int id)

Returns true if node is marked “doorway”.

3.4 Editor and visualization

Editor command:

sm_wp (admin only, typically ADMFLAG_ROOT) toggles the editor:

On open:

Calls LoadWaypointsFromFile().

Sets g_EditorOpen[client] = true.

Clears aimed/selected.

Prints "[WP] Editor opened." in chat.

Shows a menu with editor actions.

On close:

Clears flags.

Prints "[WP] Editor closed.".

Menu actions include:

Add node at player position.

Remove aimed node.

Select/link/unlink via aimed node.

Toggle doorway flag on aimed node.

Clear selection.

Save waypoints.

Close editor.

Drawing:

The timer periodically calls DrawWaypointsForClient(client) for clients with the editor open.

Culling:

A max draw distance (NODE_DRAW_MAX_DIST).

A floor delta (NODE_FLOOR_DELTA_MAX) to limit nodes to roughly the same vertical layer.

FOV-based hemisphere culling (nodes behind the player are hidden).

Visual style:

Beams and rings using temporary entities.

Doorway nodes are taller and colored differently (e.g. orange).

Aimed/selected nodes use distinct highlight colors.

4. Bot logic (zps_bot_logic.sp)

This plugin is the brain for managed bots.

4.1 Per-bot state and constants

States:

BotState_Idle

BotState_MovingPath

BotState_ChasingPlayer

BotState_Regrouping (reserved for future use)

Target types:

BotTarget_None

BotTarget_Waypoint

BotTarget_Player

BotTarget_Position

Core per-client data:

g_bIsCustomBot[client] — set by director when this client is a framework-managed zombie bot.

Target fields:

g_BotTargetType[client]

g_BotTargetWaypoint[client]

g_BotTargetPlayer[client]

g_BotTargetPos[client][3]

Path fields:

g_BotPath[client][BOTLOGIC_MAX_PATH_NODES]

g_BotPathLength[client]

g_BotPathIndex[client]

Movement:

g_BotMoveDir[client][3] — normalized XY direction.

g_BotLastThink[client] — timing guard for BOTLOGIC_THINK_INTERVAL.

Stuck detection:

g_BotLastPos[client][3]

g_BotStuckAccum[client]

g_BotStuckBounceUntil[client]

Key constants:

BOTLOGIC_THINK_INTERVAL = 0.20

BOTLOGIC_TARGET_RADIUS = 50.0

BOTLOGIC_DOORWAY_RADIUS = 15.0

BOTLOGIC_FORWARD_SPEED = 250.0

BOTLOGIC_STUCK_DIST_SQ = 25.0 (~5 units)

BOTLOGIC_STUCK_TIME = 1.0

BOTLOGIC_BOUNCE_DURATION = 0.5

BOTLOGIC_AUTO_ACQUIRE_RANGE = 2000.0

4.2 Direct chase vs waypoint pathing

Core decision function:

HasClearLineToTarget(int bot, int target):

Eye ray (visual LOS):

Ray from bot eye to target eye with TR_TraceRayFilterEx and MASK_SOLID.

Uses TraceFilter_IgnorePlayers to ignore players.

If blocked → no LOS → must use waypoints.

Hull trace (movement LOS):

From bot feet to target feet via TR_TraceHullFilterEx.

Uses a player-sized hull:

mins = { -16.0, -16.0, 0.0 }

maxs = { 16.0, 16.0, 64.0 }

If hull trace hits geometry → path is blocked by walls/hip-high obstacles.

Returns true only if both ray and hull are clear.

Player target logic:

ThinkPlayerTarget(int client):

If target invalid/dead:

ClearBotState.

If HasClearLineToTarget is true:

Direct chase:

Clear waypoint path.

Compute direction to target position.

Store in g_BotMoveDir.

State: BotState_ChasingPlayer.

Else (no clear movement LOS):

Waypoint chase:

If no path or path exhausted:

Find target’s nearest waypoint (Waypoint_FindNearestToClient(target)).

Call BuildPathToWaypoint(client, endId) to create a path from bot’s nearest waypoint.

Follow current path:

Fetch current node origin via Waypoint_GetOrigin.

If within BOTLOGIC_TARGET_RADIUS, advance to next node; if finished, go back to direct chase.

Otherwise, set movement direction toward that node.

4.3 Stuck detection & recovery

UpdateBotStuckState(int client, float now):

Only active when g_BotMoveDir is non-zero.

Compares current position with g_BotLastPos.

If movement in XY is below threshold:

Increments g_BotStuckAccum.

When g_BotStuckAccum >= BOTLOGIC_STUCK_TIME:

Reset accumulator.

Set g_BotStuckBounceUntil = now + BOTLOGIC_BOUNCE_DURATION.

During this window, the bot will press jump+duck to “bounce” out.

Path fallback on stuck:

If currently targeting a player (BotTarget_Player) and no waypoint path exists (g_BotPathLength <= 0):

If target is valid:

Find target’s nearest waypoint.

Call BuildPathToWaypoint(client, endId) to switch into waypoint-based chase.

This helps bots recover when direct chase is stuck in awkward geometry.

4.4 Movement hook

OnPlayerRunCmd:

Only applies if:

g_bIsCustomBot[client] is true.

Client is in-game, fake client, and alive.

Per command frame:

Compute now = GetGameTime().

Call BotThink(client, now) (state & targeting logic).

Call UpdateBotStuckState(client, now).

Copy g_BotMoveDir to local dir.

If zero vector → Plugin_Continue.

Otherwise:

Compute yaw from dir.

Set view angles [pitch=0, yaw, roll=0].

Add IN_FORWARD to buttons.

Set velocity vel[0..1] = dir[0..1] * BOTLOGIC_FORWARD_SPEED.

If now < g_BotStuckBounceUntil[client]:

Set IN_JUMP | IN_DUCK.

Return Plugin_Changed.

4.5 Natives provided by bot logic

From AskPluginLoad2:

BotLogic_IsCustomBot(int client)

BotLogic_RegisterBot(int client)

BotLogic_UnregisterBot(int client)

BotLogic_SetBotTargetWaypoint(int client, int nodeId)

BotLogic_SetBotTargetPlayer(int client, int target)

BotLogic_SetBotTargetPosition(int client, float pos[3])

BotLogic_ClearBotTarget(int client)

BotLogic_ForceState(int client, int state)

Bounds checked using view_as<int>(BotState_*) to avoid enum tag mismatch.

BotLogic_DebugPrint(int client)

Logs state info to server console.

These signatures must remain stable for zps_director_logic.sp and any future plugins.

5. Director / spawner (zps_director_logic.sp)

This plugin handles custom zombie fake-client life cycle.

Typical responsibilities (check actual file for exact commands):

Admin spawn command (e.g. sm_zps_spawnbot <count>):

Creates fake clients using CreateFakeClient.

Sets them to the zombie team.

Calls DispatchSpawn so they spawn at normal zombie spawn points.

Calls BotLogic_RegisterBot(client) to hand them to zps_bot_logic.sp.

Unregister / cleanup:

When bots are kicked or disconnected, calls BotLogic_UnregisterBot(client) to clean state.

Future work: wave director, dynamic difficulty, target prioritization, etc., should be implemented here using the existing BotLogic_* and Waypoint_* APIs.

6. Coding guidelines for this project

When you modify this project:

Always get user confirmation before coding

Present a brief plan:

Which file(s) will be changed.

What logic will be added/modified.

How it impacts existing APIs and behavior.

Only implement once the user approves.

Respect responsibilities and boundaries:

Pathfinding, waypoint storage, editing, and visualization belong in zps_waypoint_logic.sp.

Per-bot state machine, chase/waypoint decisions, and stuck handling belong in zps_bot_logic.sp.

Spawning/registration/direction belong in zps_director_logic.sp.

Do not break or rename public natives/forwards:

Keep Waypoint_* and BotLogic_* signatures and semantics stable.

If you need additional behavior, prefer adding new natives/forwards rather than changing existing ones.

SourceMod style:

Use #pragma semicolon 1 and #pragma newdecls required.

Prefer static helpers for internal functions.

Keep logic in functions small and focused; use helper functions where necessary.

Use IsClientInGame, IsPlayerAlive, IsFakeClient checks appropriately.

Performance considerations:

Avoid heavy per-frame work; use existing think intervals and timers.

Preferive view/distance/FOV culling for any rendering/debug logic.

Be mindful of array sizes (MAX_WAYPOINTS, BOTLOGIC_MAX_PATH_NODES) and stack usage.

Debugging and logging:

Use PrintToServer sparingly for debug output, ideally behind optional flags/conditions if you add more logging.

Avoid spamming chat for background logic; chat messages are used mainly for editor feedback and admin commands.

7. How to handle common user requests

When the user asks for:

Waypoint editor/visual changes

Work in zps_waypoint_logic.sp.

Example tasks:

Adjust culling distances/FOV.

Change colors/sizes of lines/halos.

Extend menu actions (new node types, bulk operations).

Adjust save format carefully (keep backward compatibility if possible).

Bots getting stuck, dumb chase behavior, poor navigation

Work in zps_bot_logic.sp.

Consider:

Improving HasClearLineToTarget conditions.

Enhancing BuildPathToWaypoint usage.

Refining stuck detection thresholds or recovery actions.

Adding new states if needed, but keep state machine clear.

Bot spawn counts, wave behavior, map-specific director logic

Work in zps_director_logic.sp.

Use BotLogic_* and Waypoint_* as building blocks.

New high-level features involving all three plugins

Design with clear responsibilities:

Director decides what bots should do.

Bot logic decides how a bot carries out its orders.

Waypoint logic provides the navigation graph and paths.

8. Summary

This repo implements a custom bot framework for Zombie Panic! Source using three cooperating SourceMod plugins.

The main interactions are through well-defined Waypoint_* and BotLogic_* natives.

Waypoints define the map’s navigation graph; bot logic uses that graph to navigate intelligently; the director plugin orchestrates bot creation and high-level behavior.

As a coding agent, always:

Load zps_waypoint_logic.sp, zps_bot_logic.sp, and zps_director_logic.sp from the plugins/ folder.

Keep changes scoped and backward compatible with existing natives.

Propose a plan, wait for user confirmation, then implement.

Use this document as your reference for how the project fits together and where each kind of change should go.