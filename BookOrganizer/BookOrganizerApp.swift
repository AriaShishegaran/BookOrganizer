import SwiftUI

@main
struct BookOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var fileMonitor = FileMonitor()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
