import Cocoa
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var fileMonitor = FileMonitor()
    var eventMonitor: EventMonitor?

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

        // Set up event monitor to close popover when clicking outside
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let strongSelf = self, strongSelf.popover.isShown {
                strongSelf.closePopover(sender: nil)
            }
        }
        eventMonitor?.start()
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
        eventMonitor?.stop()
    }

    // Enable auto-launch at login
    func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
            Logger.shared.log("[AutoLaunch] Successfully registered for launch at login.")
        } catch {
            Logger.shared.log("[AutoLaunch] Failed to register for launch at login: \(error)")
        }
    }
}

// EventMonitor class to monitor clicks outside the popover
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if monitor != nil {
            NSEvent.removeMonitor(monitor!)
            monitor = nil
        }
    }
}
