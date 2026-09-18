import SwiftUI
import AppKit

/// Shared start/stop orchestration for the menu-bar popover and the main window.
/// Owns countdown, floating pill, and the post-recording panel so both surfaces
/// drive the same recording session.
@MainActor
@Observable
final class RecordingSessionController {
    var isBusy = false
    var errorMessage: String?

    private var countdownController: CountdownOverlayController?
    private var controlPillController: FloatingControlPillController?
    private var postPanelController: PostRecordingPanelController?

    func start(engine: RecordingEngine, config: RecordingConfig, store: RecordingStore) async {
        guard engine.phase == .idle else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        config.save()

        let countdown = CountdownOverlayController()
        countdownController = countdown
        let proceeded = await countdown.run(seconds: 3)
        countdownController = nil
        guard proceeded else { return }

        do {
            try await engine.start(config: config.snapshot())
            let pill = FloatingControlPillController(
                onStop: { [weak self] in
                    Task { [weak self] in
                        await self?.stop(engine: engine, store: store)
                    }
                },
                onPauseResume: {
                    Task {
                        if engine.phase == .paused {
                            await engine.resume()
                        } else {
                            await engine.pause()
                        }
                    }
                }
            )
            pill.show(engine: engine)
            controlPillController = pill
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(engine: RecordingEngine, store: RecordingStore) async {
        guard engine.phase == .recording || engine.phase == .paused else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        controlPillController?.close()
        controlPillController = nil

        do {
            let result = try await engine.stop()
            isBusy = false
            let panel = PostRecordingPanelController(store: store)
            postPanelController = panel
            panel.present(result: result) { [weak self] in
                self?.postPanelController = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
