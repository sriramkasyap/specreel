import SwiftUI
import AppKit

/// Visual tokens for the Local Loom UI. Tuned to the layout reference:
/// light macOS chrome, compact inspector, red record accent, dark capture canvas.
enum LoomTheme {
    static let record = Color(red: 0.89, green: 0.16, blue: 0.18)
    static let recordHighlight = Color(red: 0.95, green: 0.28, blue: 0.28)

    static let canvas = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let pillFill = Color.black.opacity(0.82)

    static let sidebarWidth: CGFloat = 188
    static let inspectorWidth: CGFloat = 320
    static let cardRadius: CGFloat = 10
    static let previewRadius: CGFloat = 12

    static var sidebarBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var inspectorBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func duration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct RecordActionButton: View {
    var title: String = "Start recording"
    var isBusy: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "record.circle.fill")
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(LoomTheme.record)
        .disabled(isBusy)
    }
}
