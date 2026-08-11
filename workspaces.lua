-- workspaces.lua — virtual workspaces via off-screen window parking
--
-- Each workspace is a separate horizontal scrolling strip managed by Codex.
-- Only the active workspace's windows are tiled on-screen. Inactive workspace
-- windows are parked off-screen (AeroSpace-style). Codex's event handler
-- ignores parked windows via State.isHidden().

local Spaces <const> = hs.spaces
local Screen <const> = hs.screen
local Timer <const> = hs.timer
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter

local Workspaces = {}

-- Spoon reference (set by init)
local codex = nil

-- Data structures
local ws_windows = {}    -- name -> { [window_id] = true }
local win_ws = {}        -- window_id -> workspace name
local win_pid = {}       -- window_id -> pid (cached to avoid AX lookups)
local ws_snapshots = {}  -- name -> Codex snapshot (window_list + x_positions)
local ws_frames = {}     -- window_id -> saved {x, y, w, h} frame
local ws_focused = {}    -- name -> last focused window id
local current = nil      -- active workspace name
local switching = false  -- re-entrancy guard for switchTo
local focus_timer = nil  -- debounce timer for onWindowFocused
local app_rules = {}     -- appName -> workspace name
local title_rules = {}   -- ordered list of { pattern=string, workspace=string }
local screen_changed = false  -- set by screen watcher, forces retile on next switch
local ws_pending = {}         -- name -> { {id=number, win=window_ref}, ... }
local screen_watcher = nil    -- hs.screen.watcher instance
local ws_layout = {}    -- name -> "scrolling" | "unmanaged"
local ws_order = {}     -- ordered list of workspace names, as configured
local ws_filter = nil    -- separate window filter for workspace lifecycle hooks
local toggle_back = false -- when true, pressing the same switch/jump key toggles back
local focus_follows_off = {} -- appName -> true (apps that DON'T trigger workspace switch on focus)
local jump_targets = {}  -- category -> { workspace -> appName | {app,title,launch} }
local jump_window = {}   -- "category:workspace" -> window ref (lazy-validated cache)
local prev_jump = nil    -- { workspace = name, window_id = id } for toggle-jump
local app_jump_from = {} -- workspace_name -> window_id (for app-jump toggle)

---user callback, called with workspace name after switching
---@type fun(name: string)|nil
Workspaces.onSwitch = nil

---initialize workspaces module with reference to the Codex spoon
---@param spoon table Codex spoon instance
function Workspaces.init(spoon)
    codex = spoon
end

---strip invisible Unicode characters (LRM, RLM, ZWS, ZWNJ, ZWJ, BOM)
---macOS Catalyst/iOS apps embed these in their app names
---@param s string
---@return string
local function stripInvisible(s)
    if not s then return s end
    return s:gsub("\xe2\x80[\x8b-\x8f]", ""):gsub("\xef\xbb\xbf", "")
end

---resolve the workspace for a window using title rules then app rules
---@param win userdata hs.window
---@return string|nil workspace name, or nil to use default
local function resolveWorkspace(win)
    local title = win:title()
    if title then
        for _, rule in ipairs(title_rules) do
            if title:match(rule.pattern) then return rule.workspace end
        end
    end
    local app = win:application()
    if app then return app_rules[stripInvisible(app:title())] end
    return nil
end

---park coordinates at the bottom-right corner of the visible screen
---window top-left lands at the corner so the rest hangs off-screen,
---but macOS doesn't clamp because top-left is technically on-screen (by 1px).
---this is exactly how AeroSpace hides windows.
---@return number, number x, y
local function parkCoords()
    local screen = Screen.mainScreen()
    if not screen then return 9999, 9999 end
    local sf = screen:frame()
    return sf.x2 - 1, sf.y2 - 1
end

---remove a window from a stored snapshot (for cleanup on window destruction)
---@param name string workspace name
---@param dead_id number window id to remove
local function removeFromSnapshot(name, dead_id)
    local snap = ws_snapshots[name]
    if not snap or not snap.window_list then return end

    -- Walk the snapshot's window_list and remove the dead window
    for col = #snap.window_list, 1, -1 do
        local rows = snap.window_list[col]
        for row = #rows, 1, -1 do
            local win = rows[row]
            if win and win.id and win:id() == dead_id then
                table.remove(rows, row)
            end
        end
        if #rows == 0 then table.remove(snap.window_list, col) end
    end

    -- Remove from x_positions
    if snap.x_positions then
        snap.x_positions[dead_id] = nil
    end
end

---validate a snapshot, removing any stale window references
---checks against ws_windows tracking (no AX calls) instead of Window.get()
---@param snap table|nil snapshot to validate
---@param ws_name string workspace name to validate against
---@return table|nil cleaned snapshot
local function validateSnapshot(snap, ws_name)
    if not snap or not snap.window_list then return snap end

    local tracked = ws_windows[ws_name] or {}

    for col = #snap.window_list, 1, -1 do
        local rows = snap.window_list[col]
        for row = #rows, 1, -1 do
            local win = rows[row]
            local id = win and win.id and win:id()
            if not id or not tracked[id] then
                table.remove(rows, row)
                if id and snap.x_positions then
                    snap.x_positions[id] = nil
                end
            end
        end
        if #rows == 0 then table.remove(snap.window_list, col) end
    end

    return snap
end

---capture current position as jump point (workspace + focused window)
local function saveJumpPoint()
    local focused = Window.focusedWindow()
    if not focused then return end
    local id = focused:id()
    if not id then return end
    prev_jump = { workspace = current, window_id = id }
end

---remove a window id from ws_pending for a workspace, cleaning up empty tables
---@param ws string workspace name
---@param id number window id to remove
local function _removePendingEntry(ws, id)
    if not ws_pending[ws] then return end
    local p = ws_pending[ws]
    for i = #p, 1, -1 do
        if p[i].id == id then table.remove(p, i) end
    end
    if #p == 0 then ws_pending[ws] = nil end
end

---park a single window off-screen: mark hidden, stop watcher, save frame, move
---@param id number window id
---@param win userdata hs.window ref (used to read frame)
local function _parkWindow(id, win)
    codex.state.setHidden(id, true)
    codex.state.uiWatcherStop(id)
    ws_frames[id] = win:frame()
    local park_x, park_y = parkCoords()
    codex.transport.moveWindows({
        { id = id, pid = win_pid[id], x = park_x, y = park_y, w = 0, h = 0 }
    })
end

---find adjacent window in tiling order (neighbor to focus after removing a window)
---@param space number macOS space id
---@param idx table { col, row } index of the window being removed
---@return userdata|nil neighbor window ref
local function _findNeighbor(space, idx)
    local col_wins = codex.state.windowList(space, idx.col)
    local neighbor = nil
    if col_wins then
        -- Try same column, adjacent row
        neighbor = codex.state.windowList(space, idx.col, idx.row - 1)
            or codex.state.windowList(space, idx.col, idx.row + 1)
    end
    if not neighbor then
        -- Try adjacent column
        local prev_col = codex.state.windowList(space, idx.col - 1)
        local next_col = codex.state.windowList(space, idx.col + 1)
        if prev_col then neighbor = prev_col[1] end
        if not neighbor and next_col then neighbor = next_col[1] end
    end
    return neighbor
end

---park non-current workspace windows during initial setup
---called synchronously from setup() after window filter is created
local function _initialPark()
    local screen = Screen.mainScreen()
    if not screen then switching = false; return end
    local space = Spaces.activeSpaces()[screen:getUUID()]
    if not space then switching = false; return end

    -- Ensure all windows are in the tiling state with correct on-screen
    -- frames. On reload, the window filter's async event delivery may not
    -- have completed yet — refreshWindows does the same work synchronously.
    codex.windows.refreshWindows()

    local park_x, park_y = parkCoords()

    -- Pause events to avoid per-window retiling
    codex.events.paused = true

    -- Build snapshots for non-current workspaces before removing their windows.
    -- All windows share one macOS space, so partition the tiling state by workspace.
    local full_snap = codex.state.snapshotSpace(space)
    if full_snap and full_snap.window_list then
        for _, col in ipairs(full_snap.window_list) do
            local by_ws = {}
            for _, win in ipairs(col) do
                local ws = win_ws[win:id()]
                if ws and ws ~= current then
                    by_ws[ws] = by_ws[ws] or {}
                    by_ws[ws][#by_ws[ws] + 1] = win
                end
            end
            for ws, wins in pairs(by_ws) do
                ws_snapshots[ws] = ws_snapshots[ws] or { window_list = {}, x_positions = {} }
                ws_snapshots[ws].window_list[#ws_snapshots[ws].window_list + 1] = wins
            end
        end
        if full_snap.x_positions then
            for _, snap in pairs(ws_snapshots) do
                for _, col in ipairs(snap.window_list) do
                    for _, win in ipairs(col) do
                        local x = full_snap.x_positions[win:id()]
                        if x then snap.x_positions[win:id()] = x end
                    end
                end
            end
        end
    end

    -- Build id→ref lookup from filter (Window.get calls allWindows internally
    -- and can fail during hs.reload when AX hasn't caught up yet)
    local all_wins = codex.window_filter:getWindows()
    local win_by_id = {}
    for _, w in ipairs(all_wins) do
        local wid = w:id()
        if wid then win_by_id[wid] = w end
    end

    -- Remove non-current workspace windows from tiling and collect park ops
    -- (batched into one moveWindows call for initial setup performance)
    local park_ops = {}
    for name, ids in pairs(ws_windows) do
        if name ~= current then
            for id in pairs(ids) do
                local win = win_by_id[id]
                if win then
                    codex.windows.removeWindow(win, true)
                    codex.state.setHidden(id, true)
                    codex.state.uiWatcherStop(id)
                    ws_frames[id] = win:frame()
                    park_ops[#park_ops + 1] = {
                        id = id, pid = win_pid[id],
                        x = park_x, y = park_y, w = 0, h = 0,
                    }
                end
            end
        end
    end

    codex.transport.moveWindows(park_ops)

    -- Snapshot current workspace (which now only has current ws windows)
    ws_snapshots[current] = codex.state.snapshotSpace(space)

    codex.events.paused = false
    codex:tileSpace(space)

    switching = false
end

---expand app-centric config into internal tables
---@param apps table appName -> config | config[]
local function _expandApps(apps)
    for appName, config in pairs(apps) do
        -- Normalize: single config → iterate once, array → iterate each
        local entries = config
        if not config[1] then entries = { config } end

        for _, entry in ipairs(entries) do
            if entry.title then
                title_rules[#title_rules + 1] = {
                    pattern = entry.title,
                    workspace = entry.workspace,
                }
            else
                app_rules[appName] = entry.workspace
            end

            if entry.jump then
                jump_targets[entry.jump] = jump_targets[entry.jump] or {}
                if entry.title or entry.launch then
                    jump_targets[entry.jump][entry.workspace] = {
                        app = appName,
                        title = entry.title,
                        launch = entry.launch,
                    }
                else
                    jump_targets[entry.jump][entry.workspace] = appName
                end
            end

            if entry.focusFollows == false then
                focus_follows_off[appName] = true
            end
        end
    end
end

---initialize workspaces
---@param opts table { workspaces=string[], apps=table } or legacy { appRules=table, ... }
function Workspaces.setup(opts)
    local names_raw = opts.workspaces or {}
    toggle_back = opts.toggleBack or false

    -- Parse workspace list: string → scrolling, table → use .layout
    local names = {}
    for _, entry in ipairs(names_raw) do
        if type(entry) == "string" then
            names[#names + 1] = entry
            ws_layout[entry] = "scrolling"
        else
            names[#names + 1] = entry.name
            ws_layout[entry.name] = entry.layout or "scrolling"
        end
    end

    -- App-centric config vs legacy
    if opts.apps then
        _expandApps(opts.apps)
    else
        -- Legacy format
        local rules = opts.appRules or {}
        title_rules = opts.titleRules or {}
        jump_targets = opts.jumpTargets or {}
        for appName, wsName in pairs(rules) do
            app_rules[appName] = wsName
        end
        for _, appName in ipairs(opts.focusFollowsOff or {}) do
            focus_follows_off[appName] = true
        end
    end

    for _, name in ipairs(names) do
        ws_windows[name] = {}
    end
    ws_order = names
    current = names[1]

    -- Block focus-triggered workspace switches during setup
    switching = true

    -- Assign existing windows to workspaces based on title/app rules
    local all_windows = codex.window_filter:getWindows()
    for _, win in ipairs(all_windows) do
        local id = win:id()
        if id then
            local wsName = resolveWorkspace(win) or current
            ws_windows[wsName] = ws_windows[wsName] or {}
            ws_windows[wsName][id] = true
            win_ws[id] = wsName
            local app = win:application()
            if app then win_pid[id] = app:pid() end
            -- Cache jump target window refs
            local title = win:title()
            if title then
                for category, targets in pairs(jump_targets) do
                    local t = targets[wsName]
                    if type(t) == "table" and t.title and title:match(t.title) then
                        jump_window[category .. ":" .. wsName] = win
                    end
                end
            end
        end
    end

    -- Watch for screen geometry changes (resolution, display added/removed)
    screen_watcher = hs.screen.watcher.new(function()
        screen_changed = true
        codex.logger.d("screen geometry changed, re-parking hidden windows")
        -- Re-park all hidden windows at updated coordinates
        local park_x, park_y = parkCoords()
        local ops = {}
        for id, ws in pairs(win_ws) do
            if codex.state.isHidden(id) and ws ~= current then
                local pid = win_pid[id]
                if pid then
                    ops[#ops + 1] = { id = id, pid = pid, x = park_x, y = park_y }
                end
            end
        end
        if #ops > 0 then
            codex.transport.moveWindowsAsync(ops)
        end
    end)
    screen_watcher:start()

    -- Window lifecycle hooks (separate filter to avoid double-firing with Codex's)
    ws_filter = WindowFilter.new():setDefaultFilter()
    ws_filter:subscribe(WindowFilter.windowVisible, function(win) Workspaces.onWindowCreated(win) end)
    ws_filter:subscribe(WindowFilter.windowDestroyed, function(win) Workspaces.onWindowDestroyed(win) end)
    ws_filter:subscribe(WindowFilter.windowFocused, function(win) Workspaces.onWindowFocused(win) end)

    -- Park non-current workspace windows synchronously (was Timer.doAfter(1.0))
    _initialPark()
end

---build restore and park move operations for a workspace switch
---@param old string source workspace name
---@param name string target workspace name
---@param park_x number park X coordinate
---@param park_y number park Y coordinate
---@return table restore_ops, table park_ops
local function _buildMoveOps(old, name, park_x, park_y)
    local restore_ops = {}
    for id in pairs(ws_windows[name] or {}) do
        local f = ws_frames[id]
        if f then
            restore_ops[#restore_ops + 1] = {
                id = id, pid = win_pid[id],
                x = f.x, y = f.y, w = f.w, h = f.h,
            }
            ws_frames[id] = nil
        end
    end
    local park_ops = {}
    for id in pairs(ws_windows[old] or {}) do
        park_ops[#park_ops + 1] = {
            id = id, pid = win_pid[id],
            x = park_x, y = park_y, w = 0, h = 0,
        }
    end
    return restore_ops, park_ops
end

---restore workspace state: validate snapshot, restore tiling, process pending windows
---@param name string workspace name
---@param space number macOS space id
---@return table|nil snap, table|nil pending, boolean did_tile
local function _restoreWorkspace(name, space)
    local snap = validateSnapshot(ws_snapshots[name], name)

    if snap and snap.window_list and #snap.window_list > 0 then
        codex.state.restoreSpace(space, snap)
    else
        codex.state.restoreSpace(space, nil)
    end

    codex.state.ensureWatchers(space)

    -- Add pending windows (moved here while inactive) to tiling state
    local pending = ws_pending[name]
    ws_pending[name] = nil

    if pending then
        for _, entry in ipairs(pending) do
            -- pcall guards against stale userdata if window was destroyed
            -- without triggering the windowDestroyed event
            local ok, id = pcall(function() return entry.win:id() end)
            if ok and id == entry.id
                and ws_windows[name][entry.id]
                and not codex.state.is_floating[entry.id]
                and not codex.state.windowIndex(entry.win) then
                codex.windows.addWindow(entry.win)
            end
        end
    end

    -- Retile if needed
    local did_tile = false
    if not snap or not snap.window_list or #snap.window_list == 0
        or screen_changed or pending then
        codex.events.paused = false
        codex:tileSpace(space)
        -- Only do expensive refreshWindows for screen changes (legacy path)
        if screen_changed then
            codex.windows.refreshWindows()
        end
        screen_changed = false
        did_tile = true
    end

    return snap, pending, did_tile
end

---find the window to focus after switching workspaces
---@param name string workspace name
---@param snap table|nil validated snapshot
---@param pending table|nil pending window entries
---@param focus_id number|nil last-focused window id for this workspace
---@return userdata|nil window ref to focus
local function _findFocusTarget(name, snap, pending, focus_id)
    if ws_layout[name] == "unmanaged" then
        -- Unmanaged windows aren't in the snapshot (they're floating), so look them up directly.
        -- Try the last-focused window first, then fall back to any window on this workspace.
        local focus_win = nil
        if focus_id and ws_windows[name][focus_id] then
            focus_win = Window.get(focus_id)
        end
        if not focus_win then
            for id in pairs(ws_windows[name] or {}) do
                focus_win = Window.get(id)
                if focus_win then break end
            end
        end
        return focus_win
    end

    -- Build pending lookup for direct ref access (no Window.get needed)
    local pending_wins = {}
    if pending then
        for _, entry in ipairs(pending) do
            pending_wins[entry.id] = entry.win
        end
    end

    if pending_wins[focus_id] then
        -- Moved window: use stored ref directly (no AX call)
        return pending_wins[focus_id]
    end

    if snap and snap.window_list then
        local fallback = nil
        for _, col in ipairs(snap.window_list) do
            for _, win in ipairs(col) do
                if win and win.id then
                    local id = win:id()
                    if id == focus_id then return win end
                    if not fallback then fallback = win end
                end
            end
        end
        return fallback
    end

    return nil
end

---internal workspace switch (no jump tracking)
---@param name string workspace to switch to
local function _doSwitch(name)
    if not ws_windows[name] or name == current or switching then return end
    switching = true

    local t0 = hs.timer.absoluteTime()

    local screen = Screen.mainScreen()
    if not screen then switching = false; return end
    local space = Spaces.activeSpaces()[screen:getUUID()]
    if not space then switching = false; return end

    local park_x, park_y = parkCoords()

    -- Pause events for atomic switch
    codex.events.paused = true

    local old = current
    current = name

    -- 1. Save last focused window for old workspace
    local focused = Window.focusedWindow()
    if focused and focused:id() then
        ws_focused[old] = focused:id()
    end

    -- 2. Stop UI watchers for old workspace windows
    for id in pairs(ws_windows[old] or {}) do
        codex.state.uiWatcherStop(id)
    end

    -- 3. Save current window frames (parallel via winmove read_only)
    local read_ops = {}
    for id in pairs(ws_windows[old] or {}) do
        if win_pid[id] then
            read_ops[#read_ops + 1] = { id = id, pid = win_pid[id] }
        end
    end
    local read_frames = codex.transport.readFrames(read_ops)
    for wid, frame in pairs(read_frames) do
        ws_frames[wid] = frame
    end

    -- 4. Snapshot state for old workspace
    ws_snapshots[old] = codex.state.snapshotSpace(space)

    -- 5. Update hidden state
    for id in pairs(ws_windows[name] or {}) do
        codex.state.setHidden(id, nil)
    end
    for id in pairs(ws_windows[old] or {}) do
        codex.state.setHidden(id, true)
    end

    local t_prep = hs.timer.absoluteTime()

    -- 6. Build and execute move operations
    local restore_ops, park_ops = _buildMoveOps(old, name, park_x, park_y)
    codex.transport.moveWindows(restore_ops)

    local t_move = hs.timer.absoluteTime()

    codex.transport.moveWindowsAsync(park_ops)

    local t_async = hs.timer.absoluteTime()

    -- 7. Ensure all unmanaged workspace windows are floating
    if ws_layout[name] == "unmanaged" then
        for id in pairs(ws_windows[name] or {}) do
            codex.state.is_floating[id] = true
        end
    end

    -- 8. Restore state, watchers, tileSpace — skip for unmanaged
    local snap, pending, did_tile
    local t_validate = hs.timer.absoluteTime()
    local t_watchers = t_validate
    local t_tile = t_validate

    if ws_layout[name] ~= "unmanaged" then
        snap, pending, did_tile = _restoreWorkspace(name, space)
        t_tile = hs.timer.absoluteTime()
    end

    -- 9. Focus last-focused window (while events still paused to prevent tileSpace cascade)
    local focus_win = _findFocusTarget(name, snap, pending, ws_focused[name])

    local t_lookup = hs.timer.absoluteTime()

    if focus_win then
        focus_win:focus()
    end

    -- 10. Unpause events (keep paused on unmanaged) and clear switching guard
    if ws_layout[name] ~= "unmanaged" then
        codex.events.paused = false
    end
    switching = false

    -- 11. Notify via callback
    if Workspaces.onSwitch then Workspaces.onSwitch(name) end

    local t_end = hs.timer.absoluteTime()
    local function ms(a, b) return math.floor((b - a) / 1e6) end
    local tile_str = did_tile and "tile" or "skip"
    codex.logger.df("switchTo %s: prep=%dms restore=%dms validate=%dms %s=%dms lookup=%dms focus=%dms total=%dms ops=%d/%d",
        name, ms(t0, t_prep), ms(t_prep, t_move),
        ms(t_async, t_validate),
        tile_str, ms(t_validate, t_tile),
        ms(t_tile, t_lookup), ms(t_lookup, t_end),
        ms(t0, t_end), #restore_ops, #park_ops)
end

---switch to a workspace (saves jump point first)
---when toggle_back is enabled and already on target, switch to previous workspace
---@param name string workspace to switch to
function Workspaces.switchTo(name)
    if not ws_windows[name] or switching then return end
    if name == current then
        if not toggle_back or not prev_jump
            or prev_jump.workspace == current then return end
        _doSwitch(prev_jump.workspace)
        return
    end
    saveJumpPoint()
    _doSwitch(name)
end

---move the focused window to a different workspace
---@param name string target workspace
function Workspaces.moveWindowTo(name)
    codex.logger.df("moveWindowTo: %s", name)
    local win = Window.focusedWindow()
    if not win then codex.logger.d("moveWindowTo: no focused window"); return end
    if not ws_windows[name] then codex.logger.df("moveWindowTo: unknown workspace %s", name); return end
    local id = win:id()
    if not id then codex.logger.d("moveWindowTo: no window id"); return end

    local src = win_ws[id]
    codex.logger.df("moveWindowTo: window %d src=%s dst=%s", id, src or "untracked", name)
    if src == name then codex.logger.d("moveWindowTo: already on target"); return end

    -- Remove from source workspace
    if src and ws_windows[src] then
        ws_windows[src][id] = nil
    end
    -- Clean up stale pending entry on source workspace
    if src then _removePendingEntry(src, id) end

    -- Add to target workspace
    ws_windows[name][id] = true
    win_ws[id] = name

    -- Float/unfloat based on unmanaged workspace
    if ws_layout[name] == "unmanaged" then
        codex.state.is_floating[id] = true
    elseif src and ws_layout[src] == "unmanaged" then
        codex.state.is_floating[id] = nil
    end

    -- Track moved window for direct insertion on next switch (deduplicate)
    ws_pending[name] = ws_pending[name] or {}
    local p = ws_pending[name]
    for i = #p, 1, -1 do
        if p[i].id == id then table.remove(p, i) end
    end
    p[#p + 1] = { id = id, win = win }
    ws_focused[name] = id  -- focus the moved window when we switch to target

    -- If target is not current workspace, park the window
    if name ~= current then
        local screen = Screen.mainScreen()
        if screen then
            local space = Spaces.activeSpaces()[screen:getUUID()]

            -- Find adjacent window in tiling order BEFORE removing
            local idx = codex.state.windowIndex(win)
            local neighbor = idx and space and _findNeighbor(space, idx) or nil

            -- Remove from tiling (skip focus) and park off-screen
            codex.windows.removeWindow(win, true)
            _parkWindow(id, win)
            -- Focus the neighbor BEFORE tileSpace so the anchor window is valid
            if neighbor then
                neighbor:focus()
            end

            -- Update snapshot and retile current workspace
            if space then
                ws_snapshots[current] = codex.state.snapshotSpace(space)
                -- Only retile if there are remaining tiled windows
                local remaining = codex.state.windowList(space)
                if remaining and #remaining > 0 then
                    codex:tileSpace(space)
                end
            end
        end
    end
end

---assign a window to the correct workspace (called on window creation)
---@param win userdata hs.window
function Workspaces.onWindowCreated(win)
    if not win or not win.id then return end
    local id = win:id()
    if not id or win_ws[id] then return end  -- already tracked

    local app = win:application()
    if app then win_pid[id] = app:pid() end
    local wsName = resolveWorkspace(win) or current

    ws_windows[wsName] = ws_windows[wsName] or {}
    ws_windows[wsName][id] = true
    win_ws[id] = wsName

    -- Cache window ref if it matches a jump target's title pattern
    local title = win:title()
    if title then
        for category, targets in pairs(jump_targets) do
            local target = targets[wsName]
            if type(target) == "table" and target.title and title:match(target.title) then
                jump_window[category .. ":" .. wsName] = win
            end
        end
    end

    -- Auto-float windows on unmanaged workspaces
    if ws_layout[wsName] == "unmanaged" then
        codex.state.is_floating[id] = true
    end

    -- If window belongs to a non-current workspace, park it immediately.
    -- _parkWindow sets isHidden first, so Codex's async windowVisible handler
    -- will skip this window when it fires (addWindow checks isHidden).
    if wsName ~= current then
        codex.windows.removeWindow(win, true)
        _parkWindow(id, win)
        local screen = Screen.mainScreen()
        if screen then
            local space = Spaces.activeSpaces()[screen:getUUID()]
            if space then codex:tileSpace(space) end
        end
    end
end

---clean up when a window is destroyed
---@param win userdata hs.window
function Workspaces.onWindowDestroyed(win)
    if not win or not win.id then return end
    local id = win:id()
    if not id then return end

    local wsName = win_ws[id]
    if wsName and ws_windows[wsName] then
        ws_windows[wsName][id] = nil
    end
    -- Clean up the snapshot for this workspace
    if wsName then removeFromSnapshot(wsName, id) end
    -- Clean up pending entries for destroyed window
    if wsName then _removePendingEntry(wsName, id) end
    win_ws[id] = nil
    win_pid[id] = nil
    ws_frames[id] = nil
    codex.state.setHidden(id, nil)
    -- Clear last-focused reference if it was this window
    if wsName and ws_focused[wsName] == id then
        ws_focused[wsName] = nil
    end
    -- Clear jump target if it pointed to this window
    if prev_jump and prev_jump.window_id == id then
        prev_jump = nil
    end
    -- Clear app_jump_from if it pointed to this window
    if wsName and app_jump_from[wsName] == id then
        app_jump_from[wsName] = nil
    end
end

---handle window focus — switch workspace if focused window is on a different one
---@param win userdata hs.window
function Workspaces.onWindowFocused(win)
    if switching then return end
    if not win or not win.id then return end
    local id = win:id()
    if not id then return end
    if codex.state.isHidden(id) then
        local app = win:application()
        local appName = app and app:title()
        if not appName or focus_follows_off[appName] then return end
    end

    -- Track last-focused on current workspace
    local wsName = win_ws[id]
    if wsName == current then
        ws_focused[current] = id
        return
    end

    -- Debounce: only switch if focus settles on a window from another workspace.
    if focus_timer then focus_timer:stop() end
    focus_timer = Timer.doAfter(0.3, function()
        focus_timer = nil
        local now_focused = Window.focusedWindow()
        if now_focused and now_focused:id() == id and win_ws[id] and win_ws[id] ~= current then
            _doSwitch(win_ws[id])
        end
    end)
end

---get current workspace name
---@return string
function Workspaces.currentSpace()
    return current
end

---get the ordered list of configured workspace names
---@return string[]
function Workspaces.names()
    return ws_order
end

---check if a workspace uses unmanaged (floating) layout
---@param name string|nil workspace name, defaults to current
---@return boolean
function Workspaces.isUnmanaged(name)
    return ws_layout[name or current] == "unmanaged"
end

---get window ids for a workspace
---@param name string|nil workspace name, defaults to current
---@return table<number, true>
function Workspaces.windowIds(name)
    return ws_windows[name or current] or {}
end

---list windows on a workspace
---@param name string|nil workspace name, defaults to current
---@return string[]
function Workspaces.listWindows(name)
    name = name or current
    local result = {}
    for id in pairs(ws_windows[name] or {}) do
        local win = Window.get(id)
        if win then
            local app = win:application()
            local appName = app and app:title() or "?"
            result[#result + 1] = appName .. ": " .. win:title() .. " [" .. id .. "]"
        end
    end
    return result
end

---structured window info for a workspace, for UI consumers (e.g. the switcher HUD)
---@param name string|nil workspace name, defaults to current
---@return { id: number, appName: string, bundleID: string|nil, title: string, focused: boolean }[]
function Workspaces.windowsInfo(name)
    name = name or current
    local focused_id = ws_focused[name]
    if name == current then
        local live = Window.focusedWindow()
        if live and live:id() then focused_id = live:id() end
    end

    local result = {}
    for id in pairs(ws_windows[name] or {}) do
        local win = Window.get(id)
        if win then
            local app = win:application()
            result[#result + 1] = {
                id = id,
                appName = app and app:title() or "?",
                bundleID = app and app:bundleID() or nil,
                title = win:title() or "",
                focused = id == focused_id,
            }
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

---debug dump of all workspace state
function Workspaces.dump()
    local output = { "=== Workspaces ===" }
    table.insert(output, "current: " .. (current or "nil"))
    for name, ids in pairs(ws_windows) do
        local marker = name == current and " *" or ""
        local wins = {}
        for id in pairs(ids) do
            local win = Window.get(id)
            local title = win and win:title() or "gone"
            local hidden = codex.state.isHidden(id) and " [hidden]" or ""
            local focused = ws_focused[name] == id and " [focused]" or ""
            wins[#wins + 1] = string.format("%s(%d)%s%s", title, id, hidden, focused)
        end
        table.insert(output, string.format("  %s%s: %s", name, marker, table.concat(wins, ", ")))
    end
    codex.logger.i(table.concat(output, "\n"))
end

---jump to a specific app category on the current workspace
---@param category string e.g. "browser", "terminal", "llm", "comms"
function Workspaces.jumpToApp(category)
    local targets = jump_targets[category]
    if not targets then return end
    local target = targets[current]
    if not target then return end

    -- Normalize: plain string → { app = name }
    local appName, titlePattern, launchCmd
    if type(target) == "string" then
        appName = target
    else
        appName = target.app
        titlePattern = target.title
        launchCmd = target.launch
    end
    if not appName then return end

    -- Toggle-back: if focused window IS the target, toggle back to app_jump_from
    if toggle_back then
        local focused = Window.focusedWindow()
        if focused then
            local fid = focused:id()
            if fid and (ws_windows[current] or {})[fid] then
                local is_target = false
                if titlePattern then
                    local cache_key = category .. ":" .. current
                    local cached = jump_window[cache_key]
                    is_target = cached and cached:id() == fid
                else
                    local app = focused:application()
                    is_target = app and app:title() == appName
                end
                if is_target then
                    local from_id = app_jump_from[current]
                    if from_id and ws_windows[current] and ws_windows[current][from_id] then
                        -- Swap: next toggle returns here
                        app_jump_from[current] = fid
                        local win = Window.get(from_id)
                        if win then win:focus() end
                        return
                    end
                    -- No saved jump-from point: fall through to normal focus
                end
            end
        end
    end

    -- Save workspace-local jump point for app-jump toggle
    local focused = Window.focusedWindow()
    if focused and focused:id() then
        app_jump_from[current] = focused:id()
    end

    -- Title-pattern targets: use cached window ref (set by onWindowCreated)
    if titlePattern then
        local cache_key = category .. ":" .. current
        local cached = jump_window[cache_key]
        if cached then
            local id = cached:id()
            if id and (ws_windows[current] or {})[id] then
                cached:focus()
                return
            end
            jump_window[cache_key] = nil  -- stale
        end
    else
        -- Simple targets (single-process apps): find by app name
        local app = hs.application.find(appName)
        if app then
            local ws_ids = ws_windows[current] or {}
            for _, win in ipairs(app:allWindows()) do
                local id = win:id()
                if id and ws_ids[id] then
                    win:focus()
                    return
                end
            end
        end
    end

    -- No matching window — launch
    if launchCmd then
        hs.task.new(launchCmd[1], nil, table.move(launchCmd, 2, #launchCmd, 1, {})):start()
    else
        hs.application.launchOrFocus(appName)
    end
end

---toggle between current position and previous jump target
function Workspaces.toggleJump()
    if not prev_jump then return end

    -- Capture current position before jumping
    local focused = Window.focusedWindow()
    local cur = nil
    if focused and focused:id() then
        cur = { workspace = current, window_id = focused:id() }
    end

    local target_ws = prev_jump.workspace
    local target_wid = prev_jump.window_id

    -- Swap: current becomes prev_jump
    prev_jump = cur

    if target_ws ~= current then
        -- Cross-workspace jump: set target as the focus hint, then switch
        if target_wid then
            ws_focused[target_ws] = target_wid
        end
        _doSwitch(target_ws)
    else
        -- Same workspace: just focus the target window
        -- Validate target still exists on this workspace
        if target_wid and ws_windows[current] and ws_windows[current][target_wid] then
            local win = Window.get(target_wid)
            if win then win:focus() end
        end
    end
end

return Workspaces
