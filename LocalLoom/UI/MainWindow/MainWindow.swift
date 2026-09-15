import SwiftUI

/// Hosts the library gallery and the expanded recording setup side by side.
struct MainWindow: View {
    var body: some View {
        NavigationSplitView {
            RecordingConfigView(mode: .expanded)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            GalleryView()
        }
        .navigationTitle("Local Loom")
    }
}
