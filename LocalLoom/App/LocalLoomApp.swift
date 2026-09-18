import SwiftUI

/// App entry. Dock icon + main window require `LSUIElement = false` (or omitted)
/// in Info.plist — not set in code. Menu bar status item via `MenuBarExtra`.
@main
struct LocalLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var config = RecordingConfig.load()
    @State private var store = RecordingStore()
    @State private var session = RecordingSessionController()
    private let engine = RecordingEngine()

    var body: some Scene {
        WindowGroup("Local Loom", id: "main") {
            MainWindow()
                .environment(config)
                .environment(store)
                .environment(engine)
                .environment(session)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(config)
                .environment(store)
                .environment(engine)
                .environment(session)
        } label: {
            MenuBarStatusLabel()
                .environment(engine)
        }
        .menuBarExtraStyle(.window)
    }
}
