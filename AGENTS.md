# AGENTS.md - Development Guide for kbdcmd

## Build/Test Commands

### CLI Tool
- `make build-cli` - Build release binary and install to ~/bin/kbdcmd
- `swift build --product kbdcmd` - Build CLI tool (debug, to .build/debug/kbdcmd)

### Menu Bar App (macOS .app bundle)
- `make build` or `./bundle.sh` - Build .app bundle to .build/Kbdcmd.app (release; override with TARGET=debug)
- `make install` - Build and copy Kbdcmd.app to /Applications
- `make setup` - Install and open the app
- `swift build --product kbdcmd-app` - Build executable only (not full .app)

### Other
- `make reset-permissions` - Reset the app's Accessibility grant (never runs implicitly)
- `swift build` - Build all targets
- `swift build -c release` - Release build all targets
- No test suite currently exists

## Architecture

### Project Structure
The project is organized into three main targets:

1. **Core** (library) - Shared functionality
   - `Sources/Core/` - All shared code
   - KeyListener, Keybindings, WindowManager, ApplicationManager
   - OverlayManager (centralized overlay management), Snippets
   - AXInterface, AXSnapshot (accessibility tree snapshots)
   - Extensions for CGEventFlags, AXUIElement, Array

2. **Terminal** (executable) - CLI tool
   - `Sources/Terminal/` - CLI-specific code
   - `Kbdcmd.swift` - Main entry point using ArgumentParser
   - `Commands/` - CLI commands (daemon, open, cycle, snapshot, etc.)

3. **Desktop** (executable) - SwiftUI menu bar app
   - `Sources/Desktop/` - Desktop app code
   - `App.swift` - Main entry point with NSApplicationDelegate
   - Provides same functionality as daemon command via menu bar

### Key Features
- macOS keyboard shortcut automation tool using Swift Package Manager
- Requires accessibility permissions to function (AXIsProcessTrusted)
- Uses Carbon/Cocoa frameworks for system integration and CGEvent for key simulation
- Core modules: KeyListener, Keybindings, WindowManager, Snippets
- Supports both CLI daemon and SwiftUI menu bar app interfaces

### Entry Points
- Terminal CLI: `Sources/Terminal/Kbdcmd.swift` - ArgumentParser-based CLI
- Desktop App: `Sources/Desktop/App.swift` - SwiftUI App with NSApplicationDelegate

## Code Style
- Swift/SwiftUI focused with latest language features
- Prioritize readability over performance
- No TODOs or placeholders in committed code
- Fully implement all functionality
- Use clear, descriptive naming
- Import statements: Foundation frameworks first (ApplicationServices, Cocoa, Carbon)
- Error handling: Check permissions early, graceful failure with user guidance
- Public API: All Core types/methods used by Terminal or Desktop must be marked `public`
