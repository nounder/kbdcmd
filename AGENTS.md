# AGENTS.md - Development Guide for kbdcmd

## Build/Test Commands

### CLI Tool
- `make build` or `make build-cli` - Build release binary and install to ~/bin/kbdcmd
- `make debug` - Build debug binary and install to ~/bin/kbdcmd-debug  
- `swift build --product kbdcmd` - Build CLI tool

### Menu Bar App (macOS .app bundle)
- `make install-app` - Build and install Kbdcmd.app to /Applications (recommended)
- `make build-app-bundle` - Build .app bundle to .build/Kbdcmd.app
- `./build-app-bundle.sh` - Build script for creating app bundle
- `swift build --product kbdcmd-app` - Build executable only (not full .app)

### All Targets
- `make build-all` - Build both CLI and app
- `make dev` - Auto-rebuild on file changes using entr
- `swift build` - Build all targets
- `swift build -c release` - Release build all targets
- No test suite currently exists

## Architecture

### Project Structure
The project is organized into three main targets:

1. **Core** (library) - Shared functionality
   - `Sources/Core/` - All shared code
   - KeyListener, Keybindings, WindowManager, ApplicationManager
   - HintOverlay, WindowSwitcherOverlay, Snippets
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

## Code Style (from .cursorrules)
- Swift/SwiftUI focused with latest language features
- Prioritize readability over performance
- No TODOs or placeholders in committed code
- Fully implement all functionality
- Use clear, descriptive naming
- Import statements: Foundation frameworks first (ApplicationServices, Cocoa, Carbon)
- Error handling: Check permissions early, graceful failure with user guidance
- Public API: All Core types/methods used by Terminal or Desktop must be marked `public`
