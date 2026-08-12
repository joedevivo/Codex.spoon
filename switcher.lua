-- switcher.lua — hold-to-peek visual overview of all workspaces
--
-- Renders one panel per workspace (app icon + title per window, current
-- workspace highlighted) as an hs.canvas overlay. Bound as a hold-to-peek
-- hotkey: shown on press. While held, arrow keys (or hjkl) move a selection
-- cursor (left/right between workspaces, up/down between windows); releasing
-- the hotkey focuses whatever is selected. Escape cancels without acting.

local Canvas <const> = hs.canvas
local Screen <const> = hs.screen
local Mouse <const> = hs.mouse
local Image <const> = hs.image
local Window <const> = hs.window
local Eventtap <const> = hs.eventtap
local Keycodes <const> = hs.keycodes

local Switcher = {}

-- Spoon reference (set by init)
local codex = nil

local canvas = nil
local arrow_tap = nil
local icon_cache = {}  -- bundleID -> hs.image | false (miss)

-- snapshot of workspace/window state, frozen for the duration of one show()
local panels = {}   -- { { name=, unmanaged=, wins={ {id,appName,bundleID,title,focused}, ... } }, ... }
local sel_col = 1    -- selected panel index
local sel_row = 0    -- selected window index within panel (0 = none, e.g. empty panel)

local PANEL_W <const> = 240
local GAP <const> = 16
local MARGIN <const> = 24
local HEADER_H <const> = 28
local ROW_H <const> = 22
local PAD <const> = 10
local ICON_SIZE <const> = 16
local MIN_ROWS <const> = 1
local FOOTER_H <const> = 22

---initialize switcher module with reference to the Codex spoon
---@param spoon table Codex spoon instance
function Switcher.init(spoon)
    codex = spoon
end

---look up (and cache) an app's icon by bundle ID
---@param bundleID string|nil
---@return userdata|nil hs.image
local function getIcon(bundleID)
    if not bundleID then return nil end
    local cached = icon_cache[bundleID]
    if cached == nil then
        cached = Image.imageFromAppBundle(bundleID) or false
        icon_cache[bundleID] = cached
    end
    if cached == false then return nil end
    return cached
end

---snapshot workspace/window state into `panels`, and set the default
---selection to the current workspace's currently-focused window
local function snapshotPanels()
    panels = {}
    local current = codex.workspaces.currentSpace()
    for col, name in ipairs(codex.workspaces.names()) do
        panels[#panels + 1] = {
            name = name,
            unmanaged = codex.workspaces.isUnmanaged(name),
            wins = codex.workspaces.windowsInfo(name),
        }
        if name == current then
            sel_col = col
            sel_row = 0
            for row, w in ipairs(panels[col].wins) do
                if w.focused then sel_row = row end
            end
            if sel_row == 0 and #panels[col].wins > 0 then sel_row = 1 end
        end
    end
end

---move the selection cursor; dcol wraps across panels, drow clamps within one
---@param dcol number -1, 0, or 1
---@param drow number -1, 0, or 1
local function moveSelection(dcol, drow)
    if #panels == 0 then return end

    if dcol ~= 0 then
        local n = #panels
        sel_col = ((sel_col - 1 + dcol) % n) + 1
        local rows = #panels[sel_col].wins
        sel_row = rows == 0 and 0 or math.min(math.max(sel_row, 1), rows)
    end

    if drow ~= 0 then
        local rows = #panels[sel_col].wins
        if rows > 0 then
            sel_row = math.max(1, math.min(rows, sel_row + drow))
        end
    end
end

---the workspace + window id currently under the selection cursor
---@return { ws: string, id: number|nil }|nil
local function currentSelection()
    local panel = panels[sel_col]
    if not panel then return nil end
    local win = panel.wins[sel_row]
    return { ws = panel.name, id = win and win.id or nil }
end

---build canvas elements from the frozen `panels` snapshot + selection state
---@return table elements, number width, number height
local function buildElements()
    local current = codex.workspaces.currentSpace()
    local elements = {}

    local panel_h = {}
    local max_h = 0
    for i, panel in ipairs(panels) do
        local rows = math.max(#panel.wins, MIN_ROWS)
        local h = HEADER_H + PAD * 2 + rows * ROW_H
        panel_h[i] = h
        if h > max_h then max_h = h end
    end

    local total_w = MARGIN * 2 + (#panels * PANEL_W) + math.max(#panels - 1, 0) * GAP
    local total_h = MARGIN * 2 + max_h + FOOTER_H

    local x = MARGIN
    for col, panel in ipairs(panels) do
        local is_current = panel.name == current
        local is_sel_col = col == sel_col

        elements[#elements + 1] = {
            type = "rectangle",
            action = "fill",
            fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.88 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            frame = { x = x, y = MARGIN, w = PANEL_W, h = max_h },
        }
        elements[#elements + 1] = {
            type = "rectangle",
            action = "stroke",
            strokeColor = is_current
                and { red = 0.35, green = 0.65, blue = 1.0, alpha = 1 }
                or { white = 1, alpha = 0.12 },
            strokeWidth = is_current and 2 or 1,
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            frame = { x = x, y = MARGIN, w = PANEL_W, h = max_h },
        }

        local header = panel.name .. (panel.unmanaged and "  ·  float" or "")
        elements[#elements + 1] = {
            type = "text",
            text = header,
            textSize = 15,
            textColor = is_current
                and { red = 0.55, green = 0.8, blue = 1.0, alpha = 1 }
                or { white = 0.9, alpha = 1 },
            frame = { x = x + PAD, y = MARGIN + PAD - 4, w = PANEL_W - PAD * 2, h = HEADER_H },
        }

        local ry = MARGIN + HEADER_H + PAD
        if #panel.wins == 0 then
            if is_sel_col then
                elements[#elements + 1] = {
                    type = "rectangle",
                    action = "stroke",
                    strokeColor = { red = 1, green = 0.8, blue = 0.3, alpha = 1 },
                    strokeWidth = 2,
                    roundedRectRadii = { xRadius = 5, yRadius = 5 },
                    frame = { x = x + 4, y = ry - 2, w = PANEL_W - 8, h = ROW_H },
                }
            end
            elements[#elements + 1] = {
                type = "text",
                text = "empty",
                textSize = 12,
                textColor = { white = 0.55, alpha = 1 },
                frame = { x = x + PAD, y = ry, w = PANEL_W - PAD * 2, h = ROW_H },
            }
        else
            for row, w in ipairs(panel.wins) do
                local is_selected = is_sel_col and row == sel_row
                if is_selected then
                    elements[#elements + 1] = {
                        type = "rectangle",
                        action = "fill",
                        fillColor = { red = 1, green = 0.8, blue = 0.3, alpha = 0.18 },
                        roundedRectRadii = { xRadius = 5, yRadius = 5 },
                        frame = { x = x + 4, y = ry - 2, w = PANEL_W - 8, h = ROW_H },
                    }
                    elements[#elements + 1] = {
                        type = "rectangle",
                        action = "stroke",
                        strokeColor = { red = 1, green = 0.8, blue = 0.3, alpha = 1 },
                        strokeWidth = 2,
                        roundedRectRadii = { xRadius = 5, yRadius = 5 },
                        frame = { x = x + 4, y = ry - 2, w = PANEL_W - 8, h = ROW_H },
                    }
                elseif w.focused then
                    elements[#elements + 1] = {
                        type = "rectangle",
                        action = "fill",
                        fillColor = { white = 1, alpha = 0.08 },
                        roundedRectRadii = { xRadius = 5, yRadius = 5 },
                        frame = { x = x + 4, y = ry - 2, w = PANEL_W - 8, h = ROW_H },
                    }
                end

                local icon = getIcon(w.bundleID)
                local text_x = x + PAD
                if icon then
                    elements[#elements + 1] = {
                        type = "image",
                        image = icon,
                        frame = { x = x + PAD, y = ry + 2, w = ICON_SIZE, h = ICON_SIZE },
                    }
                    text_x = x + PAD + ICON_SIZE + 6
                end

                elements[#elements + 1] = {
                    type = "text",
                    text = w.appName .. ": " .. w.title,
                    textSize = 12,
                    textLineBreak = "truncateTail",
                    textColor = { white = 0.92, alpha = 1 },
                    frame = { x = text_x, y = ry + 1, w = x + PANEL_W - PAD - text_x, h = ROW_H },
                }
                ry = ry + ROW_H
            end
        end

        x = x + PANEL_W + GAP
    end

    elements[#elements + 1] = {
        type = "text",
        text = "\u{2190}\u{2192}/hl workspace   \u{2191}\u{2193}/jk window   release to focus   esc to cancel",
        textSize = 11,
        textAlignment = "center",
        textColor = { white = 0.6, alpha = 1 },
        frame = { x = MARGIN, y = MARGIN + max_h + 4, w = total_w - MARGIN * 2, h = FOOTER_H },
    }

    return elements, total_w, total_h
end

---redraw the canvas in place from current `panels` + selection state
local function redraw()
    if not canvas then return end
    canvas:replaceElements((buildElements()))
end

---start intercepting arrow/escape keys while the HUD is shown
local function startArrowTap()
    if arrow_tap then return end
    local deltas = {
        [Keycodes.map.left] = { -1, 0 },
        [Keycodes.map.right] = { 1, 0 },
        [Keycodes.map.up] = { 0, -1 },
        [Keycodes.map.down] = { 0, 1 },
        [Keycodes.map.h] = { -1, 0 },
        [Keycodes.map.l] = { 1, 0 },
        [Keycodes.map.k] = { 0, -1 },
        [Keycodes.map.j] = { 0, 1 },
    }
    arrow_tap = Eventtap.new({ Eventtap.event.types.keyDown }, function(e)
        local code = e:getKeyCode()
        local delta = deltas[code]
        if delta then
            moveSelection(delta[1], delta[2])
            redraw()
            return true
        end
        if code == Keycodes.map.escape then
            Switcher.hide()
            return true
        end
        return false
    end)
    arrow_tap:start()
end

---stop intercepting arrow/escape keys
local function stopArrowTap()
    if arrow_tap then
        arrow_tap:stop()
        arrow_tap = nil
    end
end

---show the switcher HUD, centered on the screen under the mouse
function Switcher.show()
    if not codex or not codex.workspaces then return end
    local names = codex.workspaces.names()
    if not names or #names == 0 then return end

    snapshotPanels()
    local elements, w, h = buildElements()

    local screen = Mouse.getCurrentScreen() or Screen.mainScreen()
    local sf = screen and screen:frame() or { x = 0, y = 0, w = 1440, h = 900 }
    local rect = {
        x = sf.x + (sf.w - w) / 2,
        y = sf.y + (sf.h - h) / 2,
        w = w,
        h = h,
    }

    if canvas then canvas:delete() end
    canvas = Canvas.new(rect)
    canvas:appendElements(elements)
    canvas:level(hs.drawing.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:show()

    startArrowTap()
end

---hide the switcher HUD without acting on the selection
function Switcher.hide()
    stopArrowTap()
    if canvas then
        canvas:delete()
        canvas = nil
    end
end

---focus the currently-selected window (switching workspace if needed), then hide
function Switcher.confirm()
    if canvas and #panels > 0 then
        local sel = currentSelection()
        if sel then
            if sel.ws ~= codex.workspaces.currentSpace() then
                codex.workspaces.switchTo(sel.ws)
            end
            if sel.id then
                local win = Window.get(sel.id)
                if win then win:focus() end
            end
        end
    end
    Switcher.hide()
end

---bind a hold-to-peek hotkey: HUD shown while held, arrow keys move the
---selection cursor, releasing focuses the selected window
---@param mods string[] modifier keys
---@param key string key name
function Switcher.bind(mods, key)
    hs.hotkey.bind(mods, key, Switcher.show, Switcher.confirm)
end

return Switcher
