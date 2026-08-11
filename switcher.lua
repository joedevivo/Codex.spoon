-- switcher.lua — hold-to-peek visual overview of all workspaces
--
-- Renders one panel per workspace (app icon + title per window, current
-- workspace highlighted) as an hs.canvas overlay. Meant to be bound as a
-- hold-to-peek hotkey: shown on press, dismissed on release.

local Canvas <const> = hs.canvas
local Screen <const> = hs.screen
local Mouse <const> = hs.mouse
local Image <const> = hs.image

local Switcher = {}

-- Spoon reference (set by init)
local codex = nil

local canvas = nil
local icon_cache = {}  -- bundleID -> hs.image | false (miss)

local PANEL_W <const> = 240
local GAP <const> = 16
local MARGIN <const> = 24
local HEADER_H <const> = 28
local ROW_H <const> = 22
local PAD <const> = 10
local ICON_SIZE <const> = 16
local MIN_ROWS <const> = 1

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

---build canvas elements for the current workspace state
---@return table elements, number width, number height
local function buildElements()
    local names = codex.workspaces.names()
    local current = codex.workspaces.currentSpace()
    local elements = {}

    local panels = {}
    local max_h = 0
    for _, name in ipairs(names) do
        local wins = codex.workspaces.windowsInfo(name)
        local rows = math.max(#wins, MIN_ROWS)
        local h = HEADER_H + PAD * 2 + rows * ROW_H
        panels[#panels + 1] = { name = name, wins = wins, h = h }
        if h > max_h then max_h = h end
    end

    local total_w = MARGIN * 2 + (#panels * PANEL_W) + math.max(#panels - 1, 0) * GAP
    local total_h = MARGIN * 2 + max_h

    local x = MARGIN
    for _, panel in ipairs(panels) do
        local is_current = panel.name == current
        local unmanaged = codex.workspaces.isUnmanaged(panel.name)

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

        local header = panel.name .. (unmanaged and "  ·  float" or "")
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
            elements[#elements + 1] = {
                type = "text",
                text = "empty",
                textSize = 12,
                textColor = { white = 0.55, alpha = 1 },
                frame = { x = x + PAD, y = ry, w = PANEL_W - PAD * 2, h = ROW_H },
            }
        else
            for _, w in ipairs(panel.wins) do
                if w.focused then
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

    return elements, total_w, total_h
end

---show the switcher HUD, centered on the screen under the mouse
function Switcher.show()
    if not codex or not codex.workspaces then return end
    local names = codex.workspaces.names()
    if not names or #names == 0 then return end

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
end

---hide the switcher HUD
function Switcher.hide()
    if canvas then
        canvas:delete()
        canvas = nil
    end
end

---bind a hold-to-peek hotkey: HUD shown while held, dismissed on release
---@param mods string[] modifier keys
---@param key string key name
function Switcher.bind(mods, key)
    hs.hotkey.bind(mods, key, Switcher.show, Switcher.hide)
end

return Switcher
