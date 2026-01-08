# Project Guidelines

## Code Style

### Swift

- **Never use `// MARK:` comments** - Do not add `// MARK: -`, `// MARK:`, or similar section markers to Swift code
- Organize code logically without relying on IDE-specific markers

## Claude Code Instructions

When automating UI tasks with kbdcmd:
- **Use Haiku model** for all kbdcmd automation tasks (fast, low latency)
- **Never use grep** to filter walker output - read the full output and parse it directly
- **Timing**: Use `sleep 0.1` max between clicks/moves, `sleep 1` when waiting for UI results to load

## kbdcmd CLI Usage

kbdcmd is a macOS accessibility automation tool. Use it to interact with any application's UI.

### Core Commands

#### Walker - Inspect UI Elements
```bash
# Get full UI tree of an app
.build/debug/kbdcmd walker --app Music

# Recommended flags for readable output
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music
```

Output format: `<element-type bounds="x,y,width,height" description="..." action:AXPress>`
- bounds format: `x,y,width,height` (screen coordinates)
- To get center of element: `center_x = x + width/2`, `center_y = y + height/2`
- Read full output and find elements directly - do not use grep

#### Window List - Get Window Positions
```bash
# List all windows
.build/debug/kbdcmd window-list

# Filter by app
.build/debug/kbdcmd window-list --app Music
```

#### Perform - Execute Actions

**Mouse Move (Hover)**
```bash
# Move cursor to coordinates (auto-raises window at that point)
.build/debug/kbdcmd perform --move -- 500,400

# With explicit app (optional)
.build/debug/kbdcmd perform --move --app Music -- 500,400
```

**Mouse Click**
```bash
# Click at coordinates (auto-raises window at that point)
.build/debug/kbdcmd perform --click -- 500,400
```

**Type Text**
```bash
# Type text at current focus
.build/debug/kbdcmd perform --type "hello world"
```

**Press Special Keys**
```bash
# Press Enter/Return
.build/debug/kbdcmd perform --key return

# Other keys: tab, escape, space, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12
.build/debug/kbdcmd perform --key escape
.build/debug/kbdcmd perform --key tab
```

**Accessibility Actions**
```bash
# Perform AX action on element at coordinates
.build/debug/kbdcmd perform --action AXPress --app Music -- 500,400
.build/debug/kbdcmd perform --action AXShowMenu -- 500,400

# Debug mode to see what elements/actions exist at coordinates
.build/debug/kbdcmd perform --action AXPress --debug -- 500,400
```

### Common Workflows

#### Click on UI Element
1. Find element with walker (read full output, find element)
2. Calculate center from bounds: `center_x = x + width/2`, `center_y = y + height/2`
3. Click

```bash
# 1. Find element - read full output, look for the element you need
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music

# Example output line: <button bounds="500,400,100,50" description="Play" action:AXPress />
# 2. Calculate center: x=500+50=550, y=400+25=425

# 3. Click
.build/debug/kbdcmd perform --click -- 550,425
```

#### Hover to Reveal Hidden Buttons (e.g., Music app)
Some apps show buttons only on hover. Use move, wait, then click:

```bash
# 1. Find the element (read full walker output)
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music
# Find in output: <group bounds="590,592,248,345" description="Discovery Station" action:AXPress>

# 2. Calculate center and hover
.build/debug/kbdcmd perform --move -- 714,764

# 3. Wait for hover effect and find the revealed button
sleep 0.1
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music
# Now shows: <button bounds="797,828,32,32" description="Play" action:AXPress />

# 4. Click the button (center: 813,844)
.build/debug/kbdcmd perform --click -- 813,844
```

#### Search in an App
```bash
# 1. Click on search field
.build/debug/kbdcmd perform --click -- 848,317

# 2. Type search query
sleep 0.1
.build/debug/kbdcmd perform --type "search term"

# 3. Press Enter to submit
sleep 0.1
.build/debug/kbdcmd perform --key return

# 4. Wait for results and inspect
sleep 1
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app AppName
```

#### Scroll Through Lists
```bash
# Find scroll buttons in walker output (look for "Next Page" / "Previous Page")
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music

# Click Next Page to scroll right
.build/debug/kbdcmd perform --click -- 1262,599

# Or use arrow keys after clicking in the scrollable area
.build/debug/kbdcmd perform --click -- 700,500
sleep 0.1
.build/debug/kbdcmd perform --key down
```

#### Navigate Sidebar Items
Sidebar rows often use `AXShowDefaultUI` instead of `AXPress`. Use click:

```bash
# Find sidebar item in walker output
.build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music
# Example: <outline-row bounds="327,343,183,32" action:AXShowDefaultUI>

# Click on it
.build/debug/kbdcmd perform --click -- 418,359
```

### Tips

1. **Auto window detection**: `--click` and `--move` automatically detect and raise the window at the given coordinates. No need for `--app` unless you want to be explicit.

2. **Coordinate calculation**: bounds format is `x,y,width,height`. Center is `(x + width/2, y + height/2)`.

3. **Action discovery**: Use `--debug` flag to see what actions are available at coordinates:
   ```bash
   .build/debug/kbdcmd perform --action AXPress --debug -- 400,359
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

6. **Never use grep** - Read the full walker output and find elements directly in the response.
