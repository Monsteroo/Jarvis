import Foundation

/// State of one pipeline stage in the stages row.
enum StageState: Equatable { case pending, active, waiting, done, failed }

/// Decides the "actions" stage of one request from real executor results only
/// (audit R6). An AI reply is not an action, and a plan that never ran is never
/// "done". Rules:
/// - AI still thinking, or plans running at once: active.
/// - Plans shown to the owner and not all answered: waiting.
/// - Reply without any action: pending ("no actions").
/// - Every step ran and succeeded: done.
/// - Any step failed or was partial: failed.
/// - No step ran (rejected, expired, cancelled): pending with a note, never done.
/// - Some steps succeeded but others never ran: failed ("partly k of n").
struct ActionStageTracker: Equatable {
    /// One step result, mapped from the executor's CommandOutcome by the app.
    enum Step: Equatable { case done, failed, notRun }

    let english: Bool
    private(set) var running = false
    private(set) var ai = false
    private(set) var cancelled = false
    private(set) var awaitingOwner = false
    private(set) var open = false
    /// Steps that ran immediately (brain tool calls).
    private(set) var steps: [Step] = []
    /// Plans run later (at once or after approval), in order, with results.
    private(set) var planned: [UUID] = []
    private(set) var results: [UUID: Step] = [:]
    /// AI time and cost, shown next to the action status.
    private(set) var aiNote: String?

    init(language: String) { english = language == "en" }

    /// The request started: AI thinking (`ai`) or a local command running.
    mutating func begin(ai: Bool) {
        running = true
        self.ai = ai
    }

    /// The AI answer arrived. This alone never marks the stage done.
    mutating func replyReady(aiNote: String?) {
        running = false
        self.aiNote = aiNote
    }

    /// A step that already ran (real executor outcome).
    mutating func record(_ step: Step) { steps.append(step) }

    /// Plans that will run at once or wait for the owner's approval.
    mutating func expect(_ ids: [UUID], approval: Bool) {
        planned += ids.filter { !planned.contains($0) }
        open = true
        awaitingOwner = approval
    }

    /// One expected plan finished. A late real outcome still counts.
    mutating func resolve(_ id: UUID, _ step: Step) {
        guard planned.contains(id) else { return }
        results[id] = step
    }

    /// No more results will come: unanswered plans did not run.
    mutating func settle() {
        open = false
        awaitingOwner = false
    }

    /// Esc, mic-off, quit. Only an unfinished request is affected.
    mutating func cancel() {
        guard inProgress else { return }
        running = false
        cancelled = true
        settle()
    }

    var inProgress: Bool { running || (open && planned.contains { results[$0] == nil }) }

    var allSteps: [Step] { steps + planned.map { results[$0] ?? .notRun } }

    var state: StageState {
        if running { return .active }
        if inProgress { return awaitingOwner ? .waiting : .active }
        let all = allSteps
        let succeeded = all.filter { $0 == .done }.count
        if all.isEmpty { return .pending }
        if all.contains(.failed) { return .failed }
        if all.contains(.notRun) { return succeeded > 0 ? .failed : .pending }
        return .done
    }

    var note: String? {
        if running { return ai ? "AI" : nil }
        let status: String?
        switch state {
        case .active:
            status = nil
        case .waiting:
            status = text("підтвердження", "confirm")
        case .pending:
            if allSteps.isEmpty {
                status = cancelled ? text("скасовано", "cancelled") : text("без дій", "no actions")
            } else {
                status = cancelled ? text("скасовано", "cancelled") : text("не підтверджено", "not approved")
            }
        case .failed:
            let all = allSteps
            let succeeded = all.filter { $0 == .done }.count
            status = succeeded == 0 ? text("не виконано", "failed")
                : text("частково · \(succeeded) з \(all.count)", "partly · \(succeeded) of \(all.count)")
        case .done:
            status = nil
        }
        let parts = [status, aiNote].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func text(_ uk: String, _ en: String) -> String { english ? en : uk }
}
