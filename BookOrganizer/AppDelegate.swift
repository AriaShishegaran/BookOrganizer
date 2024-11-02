import Cocoa
import SwiftUI
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var fileMonitor = FileMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "book.fill", accessibilityDescription: "Book Organizer")
            icon?.isTemplate = true // Ensure the icon adapts to light/dark mode
            button.image = icon
            button.action = #selector(togglePopover(_:))
        }

        // Set up the popover
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ContentView().environmentObject(fileMonitor))
        popover.behavior = .transient // Close when clicking outside

        // Start monitoring
        fileMonitor.startMonitoring()

        // Auto-launch at login
        enableLaunchAtLogin()
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    func showPopover(sender: AnyObject?) {
        if let button = statusItem.button {
            // Adjust the popover size to fit within the screen
            if let screen = NSScreen.main {
                let maxHeight = screen.visibleFrame.height * 0.8
                popover.contentSize = NSSize(width: 400, height: min(500, maxHeight))
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    func closePopover(sender: AnyObject?) {
        popover.performClose(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        fileMonitor.stopMonitoring()
    }

    // Enable auto-launch at login
    func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
            Task {
                await Logger.shared.log("[AutoLaunch] Successfully registered for launch at login.")
            }
        } catch {
            Task {
                await Logger.shared.log("[AutoLaunch] Failed to register for launch at login: \(error)")
            }
        }
    }
}
