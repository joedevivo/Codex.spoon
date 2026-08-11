# Codex.spoon

Tiled scrollable window manager with virtual workspaces for macOS.
A [Hammerspoon](https://www.hammerspoon.org) Spoon, forked from
[PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon).

## Why Codex?

PaperWM.spoon nailed horizontal scrolling tiling on macOS. What it lacked:

- **Virtual workspaces** -- macOS Spaces require Mission Control animations
  and can't be switched programmatically without accessibility hacks. Codex
  parks inactive windows off-screen and swaps them in instantly.
- **Performance** -- sequential Accessibility calls made workspace switching
  take seconds. Codex uses a native Swift shim (`winmove`) that parallelizes
  AX calls across apps, bringing switch time down to ~150ms.
- **App jumping** -- jump to a specific app category (browser, terminal, LLM,
  comms) with workspace awareness. Toggle-on-repeat: pressing the same key
  again returns you to where you were.
- **Unmanaged workspaces** -- any workspace can be declared as `unmanaged`
  (floating, non-tiling) for transient windows, with Rectangle-style snap
  cycling.

## What Codex Adds Over PaperWM.spoon

| Feature | PaperWM.spoon | Codex |
|---------|--------------|-------|
| Virtual workspaces | -- | Off-screen parking, instant switch |
| Unmanaged workspaces | -- | Auto-floating, snap cycling |
| Jump-to-app | -- | Workspace-aware, toggle-on-repeat |
| Native `winmove` shim | -- | Parallel AX, animation bypass, 100ms timeout |
| Workspace-aware dispatch | -- | Same key does different things on scratch vs tiling |
| Per-side window gaps | -- | `{top=8, bottom=8, left=8, right=8}` |

Everything from PaperWM.spoon still works: horizontal tiling, scrolling,
slurp/barf, column stacking, swipe gestures, mouse dragging.

## Installation

1. Clone into your Hammerspoon Spoons directory:

```bash
git clone https://github.com/jkp/Codex.spoon ~/.hammerspoon/Spoons/Codex.spoon
```

2. Open **System Settings > Desktop & Dock**, scroll to "Mission Control":
   - Uncheck "Automatically rearrange Spaces based on most recent use"
   - Check "Displays have separate Spaces"

The `winmove` binary is auto-built from `winmove.swift` on first load (requires
Xcode Command Line Tools).

## Quick Start

Minimal `~/.hammerspoon/init.lua`:

```lua
Codex = hs.loadSpoon("Codex")
Codex.window_gap = 10
Codex:start()

Codex:bindHotkeys({
    focus_left  = {{"alt", "cmd"}, "left"},
    focus_right = {{"alt", "cmd"}, "right"},
    focus_up    = {{"alt", "cmd"}, "up"},
    focus_down  = {{"alt", "cmd"}, "down"},
    swap_left   = {{"alt", "cmd", "shift"}, "left"},
    swap_right  = {{"alt", "cmd", "shift"}, "right"},
    swap_up     = {{"alt", "cmd", "shift"}, "up"},
    swap_down   = {{"alt", "cmd", "shift"}, "down"},
    center_window   = {{"alt", "cmd"}, "c"},
    full_width      = {{"alt", "cmd"}, "f"},
    cycle_width     = {{"alt", "cmd"}, "r"},
    toggle_floating = {{"alt", "cmd", "shift"}, "escape"},
    slurp_in        = {{"alt", "cmd"}, "i"},
    barf_out        = {{"alt", "cmd"}, "o"},
})
```

`Codex:start()` begins tiling. `Codex:stop()` releases windows.

Use `Codex:bindHotkeys(Codex.default_hotkeys)` for a full set of defaults.

## Configuration

### Window Gaps

```lua
Codex.window_gap = 10                                          -- uniform
Codex.window_gap = {top = 10, bottom = 8, left = 12, right = 12}  -- per-side
```

### Window Ratios

Ratios used by `cycle_width` / `cycle_height`:

```lua
Codex.window_ratios = { 1/3, 1/2, 2/3 }
```

### External Bar

Reserve space for tools like [Sketchybar](https://github.com/felixkratz/sketchybar):

```lua
Codex.external_bar = {top = 40}
Codex.external_bar = {top = 20, bottom = 40}
```

### Window Filter

Control which apps and screens are managed:

```lua
Codex.window_filter:rejectApp("iStat Menus Status")
Codex.window_filter:setAppFilter("iTunes", { rejectTitles = "MiniPlayer" })
Codex.window_filter:setScreens({ "Built%-in Retina Display" })
Codex:start()  -- restart for filter changes
```

### Smooth Scrolling

Swipe fingers horizontally on the trackpad to scroll windows:

```lua
Codex.swipe_fingers = 3  -- 0 to disable (default)
Codex.swipe_gain = 1.0
```

### Mouse Dragging

```lua
Codex.drag_window = { "alt", "cmd" }         -- drag to reorder
Codex.lift_window = { "alt", "cmd", "shift" } -- lift out, drop to re-tile
```

### Mouse Scrolling

```lua
Codex.scroll_window = { "alt", "cmd" }
Codex.scroll_gain = 10.0
```

### Anchor Behavior

The focused window is always left-anchored at the screen edge. Two options
control how neighboring columns are positioned:

```lua
Codex.sticky_pairs = true       -- (default: true)
Codex.right_anchor_last = true  -- (default: true)
```

**`sticky_pairs`** -- When focusing a non-first column, keep the left neighbor
visible alongside it (split-screen pairing). If both windows fit on screen,
the focused window shifts right to make room. If the left neighbor is too wide,
the focused window left-anchors at the screen edge. Disable for pure
left-anchoring on every column.

**`right_anchor_last`** -- When focusing the last column, snap it to the right
edge of the screen. This eliminates dead space and gives a "filling in a known
set" feel. Disable to have the last column use the same left-anchor (or sticky
pair) logic as middle columns.

| sticky_pairs | right_anchor_last | Behavior |
|:---:|:---:|---|
| on | on | Side-by-side pairing + right-flush last column |
| on | off | Side-by-side pairing everywhere, including last column |
| off | on | Pure left-anchor + right-flush last column |
| off | off | Pure left-anchor on every column |

### Misc

```lua
Codex.center_mouse = false  -- don't center cursor on space switch (default: true)
```

## Workspaces

Workspaces are configured via `Codex.workspaces.setup()` after `Codex:start()`.
The app-centric config puts all per-app settings in one place:

```lua
Codex.workspaces.setup({
    workspaces = {
        "personal",
        "work",
        "utility",
        { name = "scratch", layout = "unmanaged" },
    },
    toggleBack = true,  -- pressing same switch/jump key again toggles back

    apps = {
        Safari   = { workspace = "personal", jump = "browser", focusFollows = true },
        Claude   = { workspace = "personal", jump = "llm" },
        Messages = { workspace = "personal", jump = "comms" },

        Helium            = { workspace = "work", jump = "browser" },
        ChatGPT           = { workspace = "work", jump = "llm" },
        ["Google Chrome"] = { workspace = "work" },

        Spotify  = { workspace = "utility" },
        Obsidian = { workspace = "utility" },

        -- Multi-instance: array of configs, title pattern disambiguates
        WezTerm = {
            { workspace = "personal", jump = "terminal", title = "^%[personal%]",
              launch = { "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                         "connect", "personal" } },
            { workspace = "work", jump = "terminal", title = "^%[work%]",
              launch = { "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                         "connect", "work" } },
        },
    },
})
```

Each app entry can have:

| Key | Description |
|-----|-------------|
| `workspace` | Which workspace the app belongs to |
| `jump` | Jump category (e.g. `"browser"`, `"terminal"`) |
| `focusFollows` | `false` to prevent Cmd+Tab from switching workspace (default: `true`) |
| `title` | Lua pattern for title-based routing (multi-instance apps) |
| `launch` | Command to run when no matching window exists |

**Multi-instance apps** use an array of configs with `title` patterns to
disambiguate. Entries with `title` create title rules (checked before app
rules). Entries without `title` create app rules.

### Unmanaged (Floating) Workspaces

Declare any workspace as unmanaged by using a table entry with
`layout = "unmanaged"`:

```lua
workspaces = {
    "personal",                                    -- tiling (default)
    { name = "scratch", layout = "unmanaged" },    -- floating
}
```

Windows on unmanaged workspaces are auto-floated. Windows moved off an
unmanaged workspace are re-tiled. The scratch module provides Rectangle-style
snap cycling (`snap("left")` etc.) and centered size cycling.

Check whether the current workspace is unmanaged:

```lua
Codex.workspaces.isUnmanaged()          -- current workspace
Codex.workspaces.isUnmanaged("scratch") -- specific workspace
```

### Workspace API

```lua
Codex.workspaces.switchTo("work")           -- switch workspace (toggles back if already there)
Codex.workspaces.moveWindowTo("personal")   -- move focused window
Codex.workspaces.jumpToApp("browser")       -- jump to app category (toggles back if already focused)
Codex.workspaces.toggleJump()               -- flip between last two targets
Codex.workspaces.currentSpace()             -- get current workspace name
Codex.workspaces.isUnmanaged()              -- true if current workspace is floating
Codex.workspaces.names()                    -- ordered list of configured workspace names
Codex.workspaces.windowsInfo("work")        -- structured window info for a workspace (id, appName, bundleID, title, focused)
Codex.workspaces.dump()                     -- debug print all state
```

### Switcher (Workspace HUD)

`switcher.lua` renders a hold-to-peek overview: one panel per workspace, with
each window's app icon and title, current workspace highlighted. Bind it as
a hold key — shown on press, dismissed on release:

```lua
Codex.switcher.bind({ "cmd", "alt", "ctrl" }, "tab")
```

Or call `Codex.switcher.show()` / `Codex.switcher.hide()` directly to wire up
your own trigger (e.g. a toggle instead of hold-to-peek).

### Workspace-Aware Dispatch

Use `Codex:dispatch()` to bind the same key to different actions depending on
whether you're on a tiling or unmanaged workspace:

```lua
local scratch = Codex.scratch
local actions = Codex.actions.actions()

hs.hotkey.bind(meh, "m", Codex:dispatch(
    function() scratch.focus("left") end,  -- unmanaged action
    actions.focus_left                      -- tiling action
))
```

## Keybindings

Codex provides two binding mechanisms:

**1. `Codex:bindHotkeys(mapping)`** for tiling actions (focus, swap, resize,
slurp/barf, space switching). See `Codex.default_hotkeys` or
`Codex.actions.actions()` for the full list.

**2. Direct `hs.hotkey.bind()`** for workspace and scratch actions, since these
live outside the standard Spoon action table.

Example with workspace bindings:

```lua
local meh = {"ctrl", "alt", "shift"}
local hyper = {"ctrl", "alt", "shift", "cmd"}

-- Workspace switch
hs.hotkey.bind(meh, "1", function() Codex.workspaces.switchTo("personal") end)
hs.hotkey.bind(meh, "2", function() Codex.workspaces.switchTo("work") end)

-- Move window to workspace
hs.hotkey.bind(hyper, "1", function() Codex.workspaces.moveWindowTo("personal") end)
hs.hotkey.bind(hyper, "2", function() Codex.workspaces.moveWindowTo("work") end)

-- Jump to app
hs.hotkey.bind(meh, "b", function() Codex.workspaces.jumpToApp("browser") end)
hs.hotkey.bind(meh, "t", function() Codex.workspaces.jumpToApp("terminal") end)
```

### Available Tiling Actions

| Action | Description |
|--------|-------------|
| `focus_{left,right,up,down}` | Move focus directionally |
| `focus_{prev,next}` | Cycle focus forward/backward |
| `swap_{left,right,up,down}` | Swap window position |
| `center_window` | Center focused window on screen |
| `full_width` | Toggle full screen width |
| `cycle_width` / `cycle_height` | Cycle through `window_ratios` |
| `reverse_cycle_width` / `reverse_cycle_height` | Cycle in reverse |
| `increase_width` / `decrease_width` | Resize by 10% |
| `increase_height` / `decrease_height` | Resize by 10% |
| `slurp_in` | Pull focused window into left column |
| `barf_out` | Push focused window to new right column |
| `toggle_floating` | Float/unfloat focused window |
| `focus_floating` | Raise all floating windows |
| `switch_space_{l,r,1-9}` | Switch Mission Control space |
| `move_window_{1-9}` | Move window to Mission Control space |
| `focus_window_{1-9}` | Focus Nth window on screen |

## Architecture

```
init.lua          Entry point, loads modules, wires them together
state.lua         Window list, index table, x positions, snapshot/restore
windows.lua       Add/remove/focus/swap/resize windows
tiling.lua        Column-based tiling algorithm
events.lua        Window filter subscriptions, swipe/mouse/scroll handlers
actions.lua       Hotkey action table
floating.lua      Float/unfloat, persistence via hs.settings
space.lua         Mission Control space switching
mission_control.lua  AX-based space/window manipulation
workspaces.lua    Virtual workspaces, off-screen parking, jump-to-app
scratch.lua       Floating workspace with snap cycling
config.lua        Default configuration values
winmove.swift     Native Swift binary for parallel AX window operations
```

### The `winmove` Shim

`winmove` is a Swift binary that moves/resizes windows via the Accessibility
API. It groups operations by PID and dispatches them on concurrent threads,
which amortizes AX round-trip latency across apps. Key optimizations:

- Disables `AXEnhancedUserInterface` per-app to suppress animations
- Sets size-position-size (workaround for macOS edge clamping bugs)
- 100ms AX timeout per app -- skips hung apps gracefully
- `read_only` mode reads frames in parallel without moving
- `save=true` saves current frame before parking

## Limitations

- macOS does not allow windows fully off-screen. Codex parks at the
  bottom-right corner (top-left on-screen by 1px) to avoid clamping.
- Dragging windows between spaces is unreliable. Use `moveWindowTo()`.
- Arrange screens vertically to prevent windows bleeding across displays.

## Contributing

Style conventions:
- Global variables: `PascalCase` (e.g. `Codex`)
- Local variables: `snake_case` (e.g. `local focused_window`)
- Function names: `camelCase` (e.g. `function windowEventHandler()`)
- Use `<const>` where possible
- Create local aliases for deeply nested members

Linting: `lua-language-server --check .`

Testing: `busted` (requires [Busted](https://lunarmodules.github.io/busted/))
