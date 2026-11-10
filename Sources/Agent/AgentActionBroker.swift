import Foundation

protocol TypedActionRunning: Sendable {
    func run(_ action: Action, language: String) async -> CommandOutcome
}
/// A wrapper avoids claiming that the mutable AppKit adapter itself is Sendable.
actor LocalTypedActionRunner: TypedActionRunning {
    let executor: ActionExecutor
    init(_ executor: ActionExecutor) { self.executor = executor }
    func run(_ action: Action, language: String) async -> CommandOutcome {
        await executor.handle(action: action, language: language)
    }
}

struct AgentActionPlan: Equatable, Sendable {
    let id: UUID
    let turn: UUID
    let action: Action
    let expiresAt: Date
}
enum ApprovalError: Error { case inactiveTurn, invalidToken, expired, unsupportedAction, tooManyPlans }

/// Only propose() is exposed to MCP. approve()/commit() are exclusively native UI calls.
actor AgentActionBroker {
    private struct Entry { let plan: AgentActionPlan; let deadline: TimeInterval; var token: UUID? }
    private let executor: TypedActionRunning
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var current: (id: UUID, language: String)?
    private var plans: [UUID: Entry] = [:]
    private var running: [UUID: Task<CommandOutcome, Never>] = [:]
    init(executor: TypedActionRunning, now: @escaping @Sendable () -> Date = { Date() }, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.executor = executor; self.now = now; self.uptime = uptime }
    func begin(turn: UUID, language: String) {
        for task in running.values { task.cancel() }
        plans.removeAll()
        current = ["uk", "en"].contains(language) ? (turn, language) : nil
    }
    func propose(_ action: Action, turn: UUID) throws -> AgentActionPlan {
        guard current?.id == turn else { throw ApprovalError.inactiveTurn }
        guard case .dictate = action else { return try add(action, turn: turn) }
        throw ApprovalError.unsupportedAction // No model-triggered insertion into an implicit field.
    }
    private func add(_ action: Action, turn: UUID) throws -> AgentActionPlan {
        try ActionRegistry().validate(action)
        plans = plans.filter { $0.value.deadline > uptime() }
        guard plans.count < 32 else { throw ApprovalError.tooManyPlans }
        let plan = AgentActionPlan(id: UUID(), turn: turn, action: action, expiresAt: now().addingTimeInterval(120))
        plans[plan.id] = Entry(plan: plan, deadline: uptime() + 120, token: nil)
        return plan
    }
    func pendingPlans() -> [AgentActionPlan] {
        plans.values.filter { $0.deadline > uptime() }.map(\.plan).sorted { $0.expiresAt < $1.expiresAt }
    }
    func approve(plan id: UUID) throws -> UUID {
        guard var entry = plans[id], current?.id == entry.plan.turn, entry.token == nil else { throw ApprovalError.invalidToken }
        guard entry.deadline > uptime() else { plans.removeValue(forKey: id); throw ApprovalError.expired }
        let token = UUID(); entry.token = token; plans[id] = entry
        return token
    }
    func reject(plan id: UUID) { plans.removeValue(forKey: id) }
    func commit(plan id: UUID, token: UUID) async throws -> CommandOutcome {
        try Task.checkCancellation()
        guard let entry = plans[id], let current, current.id == entry.plan.turn, entry.token == token else { throw ApprovalError.invalidToken }
        guard entry.deadline > uptime() else { plans.removeValue(forKey: id); throw ApprovalError.expired }
        // Atomically consume BEFORE awaiting execution. No second caller can reuse this plan/token.
        plans.removeValue(forKey: id)
        let task = Task { [executor] in
            guard !Task.isCancelled else { return CommandOutcome.failed(reason: actionText(current.language, "Запит скасовано.", "Request cancelled.")) }
            return await executor.run(entry.plan.action, language: current.language)
        }
        running[id] = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        running.removeValue(forKey: id)
        return result
    }
    func cancel(turn: UUID) {
        guard current?.id == turn else { return }
        current = nil; plans.removeAll()
        for task in running.values { task.cancel() }
    }
}
