# Project Guidelines

## Code Style

### Swift

- **Never use `// MARK:` comments** - Do not add `// MARK: -`, `// MARK:`, or similar section markers to Swift code
- Organize code logically without relying on IDE-specific markers

## Claude Code Instructions

When automating UI tasks with kbdcmd:
- **Use Haiku model** for all kbdcmd automation tasks (fast, low latency)
- **Never use grep** to filter tree output - read the full output and parse it directly
- **Timing**: Use `sleep 0.1` max between clicks/moves, `sleep 1` when waiting for UI results to load

## kbdcmd CLI Usage

kbdcmd is a macOS accessibility automation tool. Use it to interact with any application's UI.

### Core Commands

#### Tree - Inspect UI Elements
```bash
# Walk the focused window of an app (defaults are already readable:
# role tags, bounds, actions on; scrollbars, tiny and empty elements off)
.build/debug/kbdcmd tree --app Music

# Walk the entire app instead of just the focused window
.build/debug/kbdcmd tree --app Music --all-windows

# Other targeting: --title "My Doc", --pid 12345, --cgid <id>
# Other useful flags: --max-depth 5, --format xml, -v (show everything)
```

Output format: `<element-type bounds="x,y,width,height" description="..." action:AXPress>`
- bounds format: `x,y,width,height` (screen coordinates)
- Read full output and find elements directly - do not use grep

#### Window List - Get Window Positions
```bash
# List all windows (JSON)
.build/debug/kbdcmd window-list

# Filter by app
.build/debug/kbdcmd window-list --app Music
```

#### Perform - Execute Actions

Coordinates require the `@` prefix: `@x,y` for a point, or `@x,y,w,h` to pass
bounds directly from tree output (clicks the center automatically - no manual
center calculation needed).

**Mouse Move (Hover)**
```bash
# Move cursor to coordinates (auto-raises window at that point)
.build/debug/kbdcmd perform move @500,400
```

**Mouse Click**
```bash
# Click at coordinates (auto-raises window at that point)
.build/debug/kbdcmd perform click @500,400

# Click center of bounds copied from tree output
.build/debug/kbdcmd perform click @500,400,100,50

# Double-click
.build/debug/kbdcmd perform click @500,400 --double

# 'kbdcmd click' is a shorthand alias
.build/debug/kbdcmd click @500,400
```

**Type Text**
```bash
# Type text at current focus
.build/debug/kbdcmd perform type "hello world"

# Chords and text (modifiers: ctrl/c, alt/opt/m, shift/s, cmd/super/win)
.build/debug/kbdcmd perform type "<cmd-a>" "<cmd-c>"
.build/debug/kbdcmd perform type "<ctrl-a>" "<ctrl-k>" "hello"

# Clear the field first (select all + delete)
.build/debug/kbdcmd perform type "new text" --clear
```

**Press Special Keys**
```bash
# Press Enter/Return
.build/debug/kbdcmd perform key return

# Other keys: tab, escape, space, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12
.build/debug/kbdcmd perform key escape
.build/debug/kbdcmd perform key tab
```

**Accessibility Actions**
```bash
# Perform AX action on element at coordinates
.build/debug/kbdcmd perform AXPress @500,400 --app Music
.build/debug/kbdcmd perform AXShowMenu @500,400

# Debug mode to see what elements/actions exist at coordinates
.build/debug/kbdcmd perform AXPress @500,400 --debug
```

**Menu Actions**
```bash
# Trigger a menu item by name or path
.build/debug/kbdcmd perform --menu "New Window"
.build/debug/kbdcmd perform --menu "Shell > New Window"
.build/debug/kbdcmd perform --menu "Quit" --app Finder
```

### Common Workflows

#### Click on UI Element
```bash
# 1. Find element - read full output, look for the element you need
.build/debug/kbdcmd tree --app Music

# Example output line: <button bounds="500,400,100,50" description="Play" action:AXPress />

# 2. Click it by passing the bounds directly (clicks the center)
.build/debug/kbdcmd perform click @500,400,100,50
```

#### Hover to Reveal Hidden Buttons (e.g., Music app)
Some apps show buttons only on hover. Use move, wait, then click:

```bash
# 1. Find the element (read full tree output)
.build/debug/kbdcmd tree --app Music
# Find in output: <group bounds="590,592,248,345" description="Discovery Station" action:AXPress>

# 2. Hover over its center
.build/debug/kbdcmd perform move @590,592,248,345

# 3. Wait for hover effect and find the revealed button
sleep 0.1
.build/debug/kbdcmd tree --app Music
# Now shows: <button bounds="797,828,32,32" description="Play" action:AXPress />

# 4. Click the button
.build/debug/kbdcmd perform click @797,828,32,32
```

#### Search in an App
```bash
# 1. Click on search field
.build/debug/kbdcmd perform click @848,317

# 2. Type search query
sleep 0.1
.build/debug/kbdcmd perform type "search term"

# 3. Press Enter to submit
sleep 0.1
.build/debug/kbdcmd perform key return

# 4. Wait for results and inspect
sleep 1
.build/debug/kbdcmd tree --app AppName
```

#### Scroll Through Lists
```bash
# Find scroll buttons in tree output (look for "Next Page" / "Previous Page")
.build/debug/kbdcmd tree --app Music

# Click Next Page to scroll right
.build/debug/kbdcmd perform click @1262,599

# Or use arrow keys after clicking in the scrollable area
.build/debug/kbdcmd perform click @700,500
sleep 0.1
.build/debug/kbdcmd perform key down
```

#### Navigate Sidebar Items
Sidebar rows often use `AXShowDefaultUI` instead of `AXPress`. Use click:

```bash
# Find sidebar item in tree output
.build/debug/kbdcmd tree --app Music
# Example: <outline-row bounds="327,343,183,32" action:AXShowDefaultUI>

# Click on it
.build/debug/kbdcmd perform click @327,343,183,32
```

### Tips

1. **Auto window detection**: `click` and `move` automatically detect and raise the window at the given coordinates. No need for `--app` unless you want to be explicit.

2. **Coordinates**: pass bounds from tree output as `@x,y,w,h` and the center is clicked automatically. `@x,y` clicks the exact point.

3. **Action discovery**: Use the `--debug` flag to see what actions are available at coordinates:
   ```bash
   .build/debug/kbdcmd perform AXPress @400,359 --debug
   ```

4. **Common AX actions**:
   - `AXPress` - Click/activate (buttons, groups)
   - `AXShowDefaultUI` - Select (sidebar rows, list items)
   - `AXShowMenu` - Context menu
   - `AXScrollToVisible` - Scroll element into view
   - `AXConfirm` - Submit (text fields)
   - `AXRaise` - Bring window to front

5. **Timing**:
   - `sleep 0.1` - Between clicks/moves/typing
   - `sleep 1` - When waiting for UI to load new content/results

6. **Never use grep** - Read the full tree output and find elements directly in the response.
