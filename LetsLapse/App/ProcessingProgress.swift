import Foundation
import SwiftUI

/// The run-rate half of a blend's state: everything that updates at progress
/// cadence (the 10 Hz gate in `AppModel.progressGateOpens`) while a render is
/// in flight.
///
/// Its own `ObservableObject`, deliberately: these used to be `@Published` on
/// `AppModel` itself, and `ObservableObject` invalidation is object-level —
/// every tick re-evaluated every mounted screen (all five tabs, the project
/// detail under the flow, the Adjust screen mid-dismissal), which is what froze
/// the create-transition in the 2026-08-29 16 Pro recording and starved the
/// Cancel button of touches (perf-audit-2026-08-29.md finding A / P1.2;
/// editor-performance-plan.md). Here, only the surfaces that show progress
/// observe it.
///
/// The slow-cadence half — `processingPhase`, `statusMessage`,
/// `processingStartedAt`, a handful of writes per run — stays on `AppModel`,
/// where the flow chrome already reads it harmlessly.
@MainActor
final class ProcessingProgressModel: ObservableObject {
    /// The one global bar, 0…1 across the whole run (all clips + tail bands).
    @Published var fraction: Double = 0
    /// Absolute finish estimate; nil while there is no honest signal.
    @Published var etaDate: Date?
    /// Whole-run frame counts from the progress plan.
    @Published var framesDone: Int?
    @Published var framesTotal: Int?
    /// The processing screen's hero, resolved ONCE per run in
    /// `startProcessing`. Resolving it in the view body walked every source
    /// frame's existence on the main actor at every tick — ~1,250 `stat`s per
    /// evaluation on the recorded shoot.
    @Published var heroURL: URL?
    @Published var heroKind: AppModel.MediaKind = .video
}
