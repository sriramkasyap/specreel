import SwiftUI

/// Hosts the library gallery and the expanded recording setup side by side.
/// Uses `HSplitView` (not `NavigationSplitView`) so the setup column keeps a
/// usable width — a narrow sidebar was clipping labels, segmented pickers,
/// and permission errors into unreadable fragments.
struct MainWindow: View {
    var body: some View {
        NavigationStack {
            HSplitView {
                RecordingConfigView(mode: .expanded)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

                GalleryView()
                    .frame(minWidth: 480)
            }
        }
    }
}
