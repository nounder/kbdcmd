import ArgumentParser
import Foundation

struct HelpWorkflowsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "help-workflows",
    abstract: "Display common kbdcmd workflows and command patterns"
  )

  @Flag(help: "Show detailed examples with output")
  var verbose = false

  @Option(help: "Filter workflows by topic (walker, perform, inspect, click, navigate, search, scroll)")
  var topic: String?

  func run() throws {
    let workflows = getWorkflows()
    let filtered = topic.map { t in workflows.filter { $0.topic == t } } ?? workflows

    if filtered.isEmpty {
      print("No workflows found for topic: \(topic ?? "unknown")")
      return
    }

    for workflow in filtered {
      printWorkflow(workflow, verbose: verbose)
    }
  }

  private func getWorkflows() -> [Workflow] {
    [
      Workflow(
        title: "Inspect UI Elements",
        topic: "walker",
        description: "Get the accessibility tree of an application window",
        commands: [
          "# Get full UI tree of an app",
          ".build/debug/kbdcmd walker --app Music",
          "",
          "# Recommended flags for readable output",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
        ],
        notes: [
          "Output format: <element-type bounds=\"x,y,width,height\" description=\"...\" action:AXPress>",
          "Bounds format: x,y,width,height (screen coordinates)",
          "To get element center: center_x = x + width/2, center_y = y + height/2",
          "Read full output and find elements directly - do not use grep",
        ]
      ),

      Workflow(
        title: "List Windows",
        topic: "inspect",
        description: "Get list of all open windows and their positions",
        commands: [
          "# List all windows",
          ".build/debug/kbdcmd window-list",
          "",
          "# Filter by app",
          ".build/debug/kbdcmd window-list --app Music",
        ],
        notes: []
      ),

      Workflow(
        title: "Move Cursor (Hover)",
        topic: "perform",
        description: "Move cursor to coordinates and auto-raise window",
        commands: [
          ".build/debug/kbdcmd perform move 500,400",
          "",
          "# With explicit app (optional)",
          ".build/debug/kbdcmd perform move --app Music -- 500,400",
        ],
        notes: [
          "Auto-raises window at that point",
          "Use sleep 0.1 between moves and clicks for timing",
        ]
      ),

      Workflow(
        title: "Click at Coordinates",
        topic: "click",
        description: "Perform a mouse click at specified coordinates",
        commands: [
          ".build/debug/kbdcmd perform click 500,400",
          "",
          "# Click with app filter",
          ".build/debug/kbdcmd perform click --app Music -- 500,400",
        ],
        notes: [
          "Auto-raises window at that point",
          "No need for --app flag unless you want to be explicit",
        ]
      ),

      Workflow(
        title: "Type Text",
        topic: "perform",
        description: "Type text at current focus location",
        commands: [
          ".build/debug/kbdcmd perform type \"hello world\"",
          "",
          ".build/debug/kbdcmd perform type \"search term\"",
        ],
        notes: [
          "Respects current focus in active window",
          "Use after clicking into a text field",
        ]
      ),

      Workflow(
        title: "Press Special Keys",
        topic: "perform",
        description: "Press keyboard keys like Enter, Tab, Escape, etc.",
        commands: [
          ".build/debug/kbdcmd perform key return",
          ".build/debug/kbdcmd perform key escape",
          ".build/debug/kbdcmd perform key tab",
          ".build/debug/kbdcmd perform key up",
          ".build/debug/kbdcmd perform key down",
        ],
        notes: [
          "Available keys: return, escape, tab, space, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12",
        ]
      ),

      Workflow(
        title: "Perform Accessibility Actions",
        topic: "perform",
        description: "Execute AX accessibility actions on elements",
        commands: [
          ".build/debug/kbdcmd perform AXPress 500,400",
          ".build/debug/kbdcmd perform AXShowMenu 500,400",
          ".build/debug/kbdcmd perform AXScroll 500,400",
          ".build/debug/kbdcmd perform AXShowDefaultUI 500,400",
          "",
          "# With debug mode to see available actions",
          ".build/debug/kbdcmd perform AXPress --debug -- 500,400",
        ],
        notes: [
          "Common AX actions: AXPress (click/activate), AXShowDefaultUI (select), AXShowMenu (context menu), AXScrollToVisible, AXConfirm, AXRaise",
          "Use --debug flag to see what elements/actions exist at coordinates",
        ]
      ),

      Workflow(
        title: "Find and Click Element",
        topic: "click",
        description: "Complete workflow to find an element and click it",
        commands: [
          "# 1. Find element - read full output, look for the element you need",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
          "",
          "# Example output: <button bounds=\"500,400,100,50\" description=\"Play\" action:AXPress />",
          "# Calculate center: x=500+50=550, y=400+25=425",
          "",
          "# 3. Click",
          ".build/debug/kbdcmd perform click 550,425",
        ],
        notes: [
          "Always calculate element center from bounds before clicking",
          "Read full walker output - do not use grep to filter",
        ]
      ),

      Workflow(
        title: "Hover to Reveal Hidden Buttons",
        topic: "navigate",
        description: "Some apps show buttons only on hover - reveal them first",
        commands: [
          "# 1. Find the element",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
          "",
          "# 2. Calculate center and hover",
          ".build/debug/kbdcmd perform move 714,764",
          "",
          "# 3. Wait for hover effect",
          "sleep 0.1",
          "",
          "# 4. Get updated tree to find revealed button",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
          "",
          "# 5. Click the revealed button",
          ".build/debug/kbdcmd perform click 813,844",
        ],
        notes: [
          "Use sleep 0.1 between hover and inspector call",
          "Some elements only appear after hovering",
        ]
      ),

      Workflow(
        title: "Search in App",
        topic: "search",
        description: "Type in search field, submit, and inspect results",
        commands: [
          "# 1. Click on search field",
          ".build/debug/kbdcmd perform click 848,317",
          "",
          "# 2. Type search query",
          "sleep 0.1",
          ".build/debug/kbdcmd perform type \"search term\"",
          "",
          "# 3. Press Enter to submit",
          "sleep 0.1",
          ".build/debug/kbdcmd perform key return",
          "",
          "# 4. Wait for results and inspect",
          "sleep 1",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app AppName",
        ],
        notes: [
          "Use sleep 1 when waiting for UI to load new content",
          "Use sleep 0.1 between individual actions",
        ]
      ),

      Workflow(
        title: "Scroll Through Lists",
        topic: "scroll",
        description: "Navigate through scrollable content",
        commands: [
          "# Find scroll buttons in walker output",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
          "",
          "# Click Next Page to scroll right",
          ".build/debug/kbdcmd perform click 1262,599",
          "",
          "# Or use arrow keys after clicking in the scrollable area",
          ".build/debug/kbdcmd perform click 700,500",
          "sleep 0.1",
          ".build/debug/kbdcmd perform key down",
        ],
        notes: [
          "Look for 'Next Page' or 'Previous Page' buttons in walker output",
          "Arrow keys work after clicking in a scrollable area",
        ]
      ),

      Workflow(
        title: "Navigate Sidebar Items",
        topic: "navigate",
        description: "Click on sidebar items which often use AXShowDefaultUI",
        commands: [
          "# Find sidebar item in walker output",
          ".build/debug/kbdcmd walker --no-empty-groups --collapse-title --role-tag --inline-text --no-scrollbar --action --bounds --app Music",
          "",
          "# Example: <outline-row bounds=\"327,343,183,32\" action:AXShowDefaultUI>",
          "",
          "# Click on it",
          ".build/debug/kbdcmd perform click 418,359",
        ],
        notes: [
          "Sidebar rows often use AXShowDefaultUI instead of AXPress",
          "Regular click still works - do not need to explicitly call AXShowDefaultUI",
        ]
      ),

      Workflow(
        title: "Real-World Example: Find Tab and Click Article",
        topic: "click",
        description: "Complete example: find 'The Verge' tab in Safari and click first headline",
        commands: [
          "# 1. Walk Safari to find tabs",
          ".build/debug/kbdcmd walker --app Safari --max-depth 3 --bounds --role-tag --inline-text",
          "",
          "# Output shows: <tab bounds=\"1416,94,415,32\" title=\"The Verge\">",
          "# Center: 1416 + 415/2 = 1623, 94 + 32/2 = 110",
          "",
          "# 2. Click the tab",
          ".build/debug/kbdcmd perform click 1623,110",
          "",
          "# 3. Wait for page load",
          "sleep 1",
          "",
          "# 4. Walk to find article headlines",
          ".build/debug/kbdcmd walker --app Safari --no-empty-groups --role-tag --inline-text --bounds --max-depth 12 | grep -E 'title=' | head -5",
          "",
          "# 5. Click first headline",
          ".build/debug/kbdcmd perform click 2619,400",
        ],
        notes: [
          "Always wait after tab switches or navigation",
          "Read walker output to find exact bounds of elements",
          "Calculate center point before clicking",
        ]
      ),
    ]
  }

  private func printWorkflow(_ workflow: Workflow, verbose: Bool) {
    print("\n\u{001B}[1m\(workflow.title)\u{001B}[0m")
    print("  Topic: \(workflow.topic)")
    print("  \(workflow.description)")
    print()

    print("  Commands:")
    for command in workflow.commands {
      if command.isEmpty {
        print()
      } else {
        print("    \(command)")
      }
    }

    if !workflow.notes.isEmpty {
      print()
      print("  Notes:")
      for note in workflow.notes {
        print("    • \(note)")
      }
    }

    if verbose {
      print()
      print("  Details:")
      print("    Use these commands in sequence in your shell scripts or terminal.")
      print("    The walker command is always the first step to understand structure.")
      print("    Calculate coordinates using: center_x = x + width/2, center_y = y + height/2")
    }
  }
}

private struct Workflow {
  let title: String
  let topic: String
  let description: String
  let commands: [String]
  let notes: [String]
}
