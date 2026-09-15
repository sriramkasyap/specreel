import SwiftUI

/// App entry. Dock icon + main window require `LSUIElement = false` (or omitted)
/// in Info.plist — not set in code. Menu bar status item via `MenuBarExtra`.
@main
struct LocalLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var config = RecordingConfig.load()
    @State private var store = RecordingStore()
    private let engine = RecordingEngine()

    var body: some Scene {
        WindowGroup("Local Loom", id: "main") {
            MainWindow()
                .environment(config)
                .environment(store)
                .environment(engine)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(config)
                .environment(store)
                .environment(engine)
        } label: {
            MenuBarStatusLabel()
                .environment(engine)
        }
        .menuBarExtraStyle(.window)
    }
}
