# AGENTS.md - Development Guide for kbdcmd

## Build/Test Commands
- `make build` - Build release binary and install to ~/bin/kbdcmd
- `make debug` - Build debug binary and install to ~/bin/kbdcmd-debug  
- `make dev` - Auto-rebuild on file changes using entr
- `swift build` - Standard Swift build
- `swift build -c release` - Release build
- No test suite currently exists

## Architecture
- macOS keyboard shortcut automation tool using Swift Package Manager
- Single executable target `kbdcmd` with main entry point in Sources/AppBundle/main.swift
- Core modules: KeyListener, Keybindings, WindowManager, SnippetManager
- Requires accessibility permissions to function (AXIsProcessTrusted)
- Uses Carbon/Cocoa frameworks for system integration and CGEvent for key simulation

## Code Style (from .cursorrules)
- Swift/SwiftUI focused with latest language features
- Prioritize readability over performance
- No TODOs or placeholders in committed code
- Fully implement all functionality
- Use clear, descriptive naming
- Import statements: Foundation frameworks first (ApplicationServices, Cocoa, Carbon)
- Error handling: Check permissions early, graceful failure with user guidance
