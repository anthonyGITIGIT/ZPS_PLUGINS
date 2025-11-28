# Agent Guide: Custom Zombie Bot Framework for Zombie Panic! Source

This document explains how the project is structured and how you, as a GPT-based coding agent (Codex / GitHub agent), should work with it.

The project is a SourceMod plugin suite for Zombie Panic! Source, implementing a custom zombie bot framework using three cooperating plugins.

---

## 1. Quick-start checklist for the agent

Before making any changes:

1. Open and read these files from the `plugins/` folder in the repository:

   * `plugins/zps_waypoint_logic.sp`
   * `plugins/zps_bot_logic.sp`
   * `plugins/zps_director_logic.sp`

2. Treat those files as the single source of truth.
   Do not rely on outdated snippets or assumptions.

3. When the user requests changes:

   * First summarize a concrete plan (what you will change, in which file).
   * Wait for the user to confirm the plan.
   * Only then modify code.

4. Never change the signatures or semantics of the public natives/forwards:

   * `Waypoint_*` (from `zps_waypoint_logic.sp`)
   * `BotLogic_*` (from `zps_bot_logic.sp`)
   * Director commands/events in `zps_director_logic.sp`

The framework depends on these interfaces staying stable.

5. After implementing new behavior or changing existing behavior in a meaningful way, you must also:

   * Review `agent.md` for sections that describe that behavior.
   * Update those sections to match the new reality.
   * Remove or rewrite information that is now wrong or misleading.

---

## 2. High-level architecture

The project consists of three SourceMod plugins that work together via natives and forwards:

1. `zps_waypoint_logic.sp`

   * Maintains a per-map waypoint graph in memory.
   * Provides an in-game waypoint editor (`sm_wp`) with visual debug drawing.
   * Handles saving/loading waypoints to disk.
   * Exposes a pathfinding API (`Waypoint_*` natives) for other plugins.

2. `zps_bot_logic.sp`

   * Implements per-bot “brain” logic.
   * Maintains bot states, targets, and paths.
   * Decides between direct chase and waypoint-based pathing.
   * Implements stuck detection and recovery.
   * Drives movement through `OnPlayerRunCmd`.

3. `zps_director_logic.sp`

   * Spawns and manages custom zombie fake clients.
   * Registers/unregisters bots with `zps_bot_logic.sp`.
   * Future home for “director” logic (waves, difficulty, etc.).

Data flow:

* `zps_director_logic.sp` → uses `BotLogic_*` natives → `zps_bot_logic.sp`.
* `zps_bot_logic.sp` → uses `Waypoint_*` natives → `zps_waypoint_logic.sp`.
* `zps_waypoint_logic.sp` → standalone; only exposes natives, no direct dependency on the others.

All logic is for custom fake-client zombies only (not human players, not stock bots).

---

## 3. Waypoint system (`zps_waypoint_logic.sp`)

### 3.1 Core data model

Global arrays (size `MAX_WAYPOINTS = 512`):

* `g_WPUsed[id]` — slot in use.
* `g_WPOrigin[id][3]` — world position.
* `g_WPLinks[id][MAX_LINKS_PER_WP]` — adjacency list.
* `g_WPLinkCount[id]` — number of active links for each node.
* `g_WPDoorway[id]` — whether this node is a special “doorway” node.

Doorway nodes:

* Used by bot logic to enforce precise door crossing.
* Doorway nodes have tighter arrival radius and distinct visual representation.

Per-client editor state:

* `g_EditorOpen[client]` — true when the waypoint editor is active.
* `g_AimedNode[client]` — waypoint currently under crosshair.
* `g_SelectedNode[client]` — active selection for linking/unlinking.

### 3.2 Save/load

File path:

* Waypoints are stored under:

  * `addons/sourcemod/data/<mapname>_waypoints.cfg`

Save format:

* Header comments.

* `nodes <count>` line.

* For each node:

  node `<id> <x> <y> <z> <doorFlag>`
  links: `<neighborId> <neighborId> ...`

* For links, only neighbors `other >= id` are written to avoid duplicating undirected edges.

Load logic:

* Uses two-pass parsing with temporary edge buffers:

  1. Pass 1: parse `node` lines; fill `g_WPUsed`, `g_WPOrigin`, `g_WPDoorway`, reset link counts.
  2. Pass 2: parse `links` lines; store edge pairs `(from, to)` into local arrays.
  3. After reading the whole file, iterate collected edges and call `LinkWaypoints(from, to)` to rebuild adjacency lists.

* `#pragma dynamic 65536` is used to give enough heap for temporary arrays (visited[], parent[], edge arrays, etc.).

This design prevents the “links disappear after load” bug that happens when trying to link nodes before all of them are known.

### 3.3 Pathfinding API

Path is built via BFS:

* `BuildWaypointPath(int startId, int endId, int buffer[WP_PATH_MAX_NODES], int maxSize)`:

  * Standard BFS over `g_WPLinks`/`g_WPLinkCount`.
  * Uses arrays:

    * `queue[MAX_WAYPOINTS]`
    * `visited[MAX_WAYPOINTS]`
    * `parent[MAX_WAYPOINTS]`
  * After BFS:

    * Backtrack from `endId` through `parent[]` into a temporary path list.
    * Reverse into the output buffer.
  * Returns path length (clamped by `maxSize`), or `0` on failure.

Natives exposed to other plugins:

* `Waypoint_FindNearestToClient(int client)`
  Returns nearest waypoint id to `GetClientAbsOrigin(client)` or `-1`.

* `Waypoint_GetPath(int startId, int endId, int[] buffer, int maxSize)`
  Wraps BFS and writes the path into the caller’s array via `SetNativeArray`.

* `Waypoint_GetOrigin(int id, float pos[3])`
  Copies waypoint origin to caller, returns `true` on success.

* `Waypoint_IsDoorway(int id)`
  Returns `true` if node is marked “doorway”.

### 3.4 Editor and visualization

Editor command:

* `sm_wp` (admin only, typically `ADMFLAG_ROOT`) toggles the editor:

  * On open:

    * Calls `LoadWaypointsFromFile()`.
    * Sets `g_EditorOpen[client] = true`.
    * Clears aimed/selected.
    * Prints `[WP] Editor opened.` in chat.
    * Shows a menu with editor actions.
  * On close:

    * Clears flags.
    * Prints `[WP] Editor closed.`.

Menu actions include:

* Add node at player position.
* Remove aimed node.
* Select/link/unlink via aimed node.
* Toggle doorway flag on aimed node.
* Clear selection.
* Save waypoints.
* Close editor.

Drawing:

* A timer periodically calls `DrawWaypointsForClient(client)` for clients with the editor open.
* Culling:

  * A max draw distance (`NODE_DRAW_MAX_DIST`).
  * A floor delta (`NODE_FLOOR_DELTA_MAX`) to limit nodes to roughly the same vertical layer.
  * FOV-based hemisphere culling (nodes behind the player are hidden).
* Visual style:

  * Beams and rings using temporary entities.
  * Doorway nodes are taller and colored differently.
  * Aimed/selected nodes use distinct highlight colors.

---

## 4. Bot logic (`zps_bot_logic.sp`)

This plugin is the brain for managed bots.

### 4.1 Per-bot state and constants

States:

* `BotState_Idle`
* `BotState_MovingPath`
* `BotState_ChasingPlayer`
* `BotState_Regrouping`

Target types:

* `BotTarget_None`
* `BotTarget_Waypoint`
* `BotTarget_Player`
* `BotTarget_Position`

Core per-client data:

* `g_bIsCustomBot[client]` — set by director when this client is a framework-managed zombie bot.
* Target fields:

  * `g_BotTargetType[client]`
  * `g_BotTargetWaypoint[client]`
  * `g_BotTargetPlayer[client]`
  * `g_BotTargetPos[client][3]`
* Path fields:

  * `g_BotPath[client][BOTLOGIC_MAX_PATH_NODES]`
  * `g_BotPathLength[client]`
  * `g_BotPathIndex[client]`
* Movement:

  * `g_BotMoveDir[client][3]` — normalized direction we want to move.
  * `g_BotLastThink[client]` — timing guard for `BOTLOGIC_THINK_INTERVAL`.
* Stuck detection:

  * `g_BotLastPos[client][3]`
  * `g_BotStuckAccum[client]`
  * `g_BotStuckBounceUntil[client]`

Key constants:

* `BOTLOGIC_THINK_INTERVAL = 0.20`
* `BOTLOGIC_TARGET_RADIUS = 50.0`
* `BOTLOGIC_DOORWAY_RADIUS = 15.0`
* `BOTLOGIC_FORWARD_SPEED = 250.0`
* `BOTLOGIC_STUCK_DIST_SQ = 25.0` (~5 units)
* `BOTLOGIC_STUCK_TIME = 1.0`
* `BOTLOGIC_BOUNCE_DURATION = 0.5`
* `BOTLOGIC_AUTO_ACQUIRE_RANGE = 2000.0`

### 4.2 Direct chase vs waypoint pathing

Core decision function:

`HasClearLineToTarget(int bot, int target)`:

1. Eye ray (visual LOS):

   * Ray from bot eye to target eye with `TR_TraceRayFilterEx` and `MASK_SOLID`.
   * Uses `TraceFilter_IgnorePlayers` to ignore players.
   * If blocked → no LOS → must use waypoints.

2. Hull trace (movement LOS):

   * From bot feet to target feet via `TR_TraceHullFilterEx`.
   * Uses a player-sized hull:

     * `mins = { -16.0, -16.0, 0.0 }`
     * `maxs = { 16.0, 16.0, 64.0 }`
   * If hull trace hits geometry → path is blocked by walls or hip-high obstacles.

Returns `true` only if both ray and hull are clear.

Player target logic:

`ThinkPlayerTarget(int client)`:

* If target invalid/dead:

  * `ClearBotState`.

* If `HasClearLineToTarget` is `true`:

  * Direct chase:

    * Clear waypoint path.
    * Compute direction to target position.
    * Store in `g_BotMoveDir`.
    * State: `BotState_ChasingPlayer`.

* Else (no clear movement LOS):

  * Waypoint chase:

    * If no path or path exhausted:

      * Find target’s nearest waypoint (`Waypoint_FindNearestToClient(target)`).
      * Call `BuildPathToWaypoint(client, endId)` to create a path from bot’s nearest waypoint.
    * Follow path:

      * Move toward current node; when within radius, advance to next.
      * When path is finished, fall back to direct chase.

### 4.3 Stuck detection and recovery

`UpdateBotStuckState(int client, float now)`:

* Only active when `g_BotMoveDir` is non-zero.
* Compares current position with `g_BotLastPos`.
* If movement in XY is below threshold:

  * Increments `g_BotStuckAccum`.
  * When `g_BotStuckAccum >= BOTLOGIC_STUCK_TIME`:

    * Reset accumulator.
    * Set `g_BotStuckBounceUntil = now + BOTLOGIC_BOUNCE_DURATION`.
    * During this window the bot auto-presses jump+duck to bounce off obstacles.
    * Additionally:

      * If targeting a player (`BotTarget_Player`) and no waypoint path exists (`g_BotPathLength <= 0`):

        * Find target’s nearest waypoint and call `BuildPathToWaypoint(client, endId)` to switch to waypoint-based chase.

When movement is sufficient, accumulator resets and last position is updated.

### 4.4 Movement hook

`OnPlayerRunCmd`:

* Only applies if:

  * `g_bIsCustomBot[client]` is true.
  * Client is in-game, fake client, and alive.

Per command frame:

1. `now = GetGameTime()`.
2. `BotThink(client, now)` decides target and path.
3. `UpdateBotStuckState(client, now)` handles stuck recovery.
4. If `g_BotMoveDir` is zero → return `Plugin_Continue`.
5. Otherwise:

   * Compute yaw from `g_BotMoveDir`.
   * Set angles (pitch 0, roll 0, yaw towards direction).
   * Add `IN_FORWARD` to `buttons`.
   * Set `vel[0..1]` from direction scaled by `BOTLOGIC_FORWARD_SPEED`.
   * If `now < g_BotStuckBounceUntil[client]`:

     * Add `IN_JUMP` and `IN_DUCK`.
   * Return `Plugin_Changed`.

### 4.5 Natives provided by bot logic

From `AskPluginLoad2`:

* `BotLogic_IsCustomBot(int client)`
* `BotLogic_RegisterBot(int client)`
* `BotLogic_UnregisterBot(int client)`
* `BotLogic_SetBotTargetWaypoint(int client, int nodeId)`
* `BotLogic_SetBotTargetPlayer(int client, int target)`
* `BotLogic_SetBotTargetPosition(int client, float pos[3])`
* `BotLogic_ClearBotTarget(int client)`
* `BotLogic_ForceState(int client, int state)`

  * Bounds checked using `view_as<int>(BotState_*)` to avoid enum tag mismatch.
* `BotLogic_DebugPrint(int client)`

  * Logs state info to server console.

These signatures must remain stable for `zps_director_logic.sp` and any future plugins.

---

## 5. Director / spawner (`zps_director_logic.sp`)

This plugin handles custom zombie fake-client life cycle.

Typical responsibilities (exact commands are in the file):

* Admin spawn command (e.g. `sm_zps_spawnbot <count>`):

  * Creates fake clients using `CreateFakeClient`.
  * Sets them to the zombie team.
  * Calls `DispatchSpawn` so they spawn at normal zombie spawn points.
  * Calls `BotLogic_RegisterBot(client)` to hand them to `zps_bot_logic.sp`.

* Unregister / cleanup:

  * When bots are kicked or disconnected, calls `BotLogic_UnregisterBot(client)` to clean state.

Future work: wave director, dynamic difficulty, target prioritization, etc., should be implemented here using the existing `BotLogic_*` and `Waypoint_*` APIs.

---

## 6. Coding guidelines for this project

When you modify this project:

1. Always get user confirmation before coding

   * Present a brief plan:

     * Which file(s) will be changed.
     * What logic will be added/modified.
     * How it impacts existing APIs and behavior.
   * Only implement once the user approves.

2. Respect responsibilities and boundaries:

   * Pathfinding, waypoint storage, editing, and visualization belong in `zps_waypoint_logic.sp`.
   * Per-bot state machine, chase/waypoint decisions, and stuck handling belong in `zps_bot_logic.sp`.
   * Spawning/registration/direction belong in `zps_director_logic.sp`.

3. Do not break or rename public natives/forwards:

   * Keep `Waypoint_*` and `BotLogic_*` signatures and semantics stable.
   * If you need additional behavior, prefer adding new natives/forwards rather than changing existing ones.

4. SourceMod style:

   * Use `#pragma semicolon 1` and `#pragma newdecls required`.
   * Prefer `static` helpers for internal functions.
   * Keep logic in functions small and focused; use helper functions where necessary.
   * Use `IsClientInGame`, `IsPlayerAlive`, `IsFakeClient` checks appropriately.

5. Performance considerations:

   * Avoid heavy per-frame work; use existing think intervals and timers.
   * Use distance/FOV/floor culling for any rendering/debug logic.
   * Be mindful of array sizes (`MAX_WAYPOINTS`, `BOTLOGIC_MAX_PATH_NODES`) and stack usage.

6. Debugging and logging:

   * Use `PrintToServer` sparingly for debug output.
   * Avoid spamming chat for background logic; chat messages are for editor feedback and admin commands.

---

## 7. How to handle common user requests

When the user asks for:

1. Waypoint editor/visual changes

   * Work in `zps_waypoint_logic.sp`.
   * Possible tasks:

     * Adjust culling distances/FOV.
     * Change colors/sizes of beams/halos.
     * Extend menu actions (new node types, bulk operations).
     * Adjust save format carefully (keep backward compatibility if possible).

2. Bots getting stuck, dumb chase behavior, poor navigation

   * Work in `zps_bot_logic.sp`.
   * Consider:

     * Tweaking `HasClearLineToTarget` conditions.
     * Refining how and when `BuildPathToWaypoint` is used.
     * Adjusting stuck detection thresholds or recovery actions.
     * Adding new states only when necessary, keeping the state machine readable.

3. Bot spawn counts, wave behavior, map-specific director logic

   * Work in `zps_director_logic.sp`.
   * Use `BotLogic_*` and `Waypoint_*` as building blocks.

4. New high-level features involving all three plugins

   * Design with clear responsibilities:

     * Director decides what bots should do.
     * Bot logic decides how a bot carries out its orders.
     * Waypoint logic provides the navigation graph and paths.

---

## 8. Branch and workflow policy for agents

This repository expects the agent to work directly on the `main` branch by default.

1. Primary rule:

   * Always operate on the `main` branch.
   * Do not create feature branches.
   * Do not open pull requests unless explicitly requested by the user or strictly required by repository protections.

2. When applying changes:

   * Assume changes should be applied directly to `main` in-place.
   * When generating patches or commits, target `main` only.

3. If direct changes to `main` are technically blocked:

   * If repository/organization protections prevent direct commits to `main` (for example, mandatory PRs or branch protection rules):

     * Clearly explain to the user that direct edits to `main` are not possible.
     * Propose a minimal branch + PR workflow as a fallback, but only in this situation.

4. Never introduce branching on your own initiative:

   * Do not create new branches, PRs, or long-lived feature flows by default.
   * If the user explicitly instructs you to use branches or PRs, follow their instructions, but keep changes minimal and focused.

This policy is intended to keep the workflow simple and predictable: by default, the agent edits the current state of `main` directly, without introducing extra branches.

---

## 9. Self-maintenance of `agent.md`

This file is part of the project and must evolve with the codebase. As the agent, you are expected to keep it accurate and lean.

1. When you add or significantly change behavior, you must:

   * Identify which sections of `agent.md` describe that behavior (architecture, flow, APIs, policies, etc.).
   * Update those sections so they correctly describe the new implementation.
   * Remove or rewrite any statements that are now incorrect, misleading, or obsolete.

2. What to add:

   * For new features or patterns that a future agent needs to know, briefly document:

     * Where the feature lives (which plugin and roughly which area).
     * How it interacts with existing components (`Waypoint_*`, `BotLogic_*`, director).
     * Any new constraints or invariants that must be preserved.

3. What to remove:

   * Old behavior descriptions that no longer match the code.
   * “Historical” notes that only describe how things used to work, unless they are still relevant for understanding current design decisions.

4. Style and scope:

   * Keep `agent.md` concise and implementation-focused.
   * Do not duplicate comments that already exist clearly in code unless they are critical for high-level understanding.
   * Prefer updating existing sections over adding new ones if the topic overlaps.

5. Process:

   * Treat edits to `agent.md` as part of the same change set as the code you are modifying.
   * Mention in your commit message/summary that `agent.md` was updated to reflect the new behavior.

By following this, each new agent run will have an up-to-date description of how the system works, and `agent.md` will remain a reliable source of truth alongside the code.

---

## 10. Summary

* This repo implements a custom bot framework for Zombie Panic! Source using three cooperating SourceMod plugins.
* The main interactions are through well-defined `Waypoint_*` and `BotLogic_*` natives.
* Waypoints define the map’s navigation graph; bot logic uses that graph to navigate intelligently; the director plugin orchestrates bot creation and high-level behavior.
* As a coding agent, always:

  * Load `zps_waypoint_logic.sp`, `zps_bot_logic.sp`, and `zps_director_logic.sp` from the `plugins/` folder.
  * Keep changes scoped and backward compatible with existing natives.
  * Propose a plan, wait for user confirmation, then implement.
  * Work directly on the `main` branch by default and do not create branches or PRs unless strictly necessary.
  * Update `agent.md` whenever your changes alter behavior, and remove outdated information so this document stays current.
