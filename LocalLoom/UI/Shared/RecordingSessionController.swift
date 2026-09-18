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
        // `engine.phase` only flips to `.idle` at the end of teardown (up to ~12s),
        // so a second Stop click during that window would still pass a phase-only
        // guard and open a duplicate Save panel for the same result.
        guard !isBusy, engine.phase == .recording || engine.phase == .paused else { return }
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
