import AppKit
import SwiftUI

/// Retain for one voice turn. Dismiss on cancel, microphone-off, next turn, or app shutdown.
@MainActor final class AgentApprovalController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var plans: [AgentActionPlan] = []
    @Published private(set) var results: [UUID: String] = [:]
    @Published private(set) var working: Set<UUID> = []
    let language: String
    private let broker: AgentActionBroker
    private let turn: UUID
    private let onEnd: () -> Void
    private var endNotified = false
    private let onOutcome: (AgentActionPlan, CommandOutcome) -> Void
    private var valid = true
    private var panel: AgentReviewPanel?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    init(broker: AgentActionBroker, turn: UUID, language: String,
         onEnd: @escaping () -> Void = {}, onOutcome: @escaping (AgentActionPlan, CommandOutcome) -> Void = { _, _ in }) {
        self.broker = broker; self.turn = turn; self.language = language == "en" ? "en" : "uk"; self.onOutcome = onOutcome; self.onEnd = onEnd
    }
    func refresh() async {
        let pending = await broker.pendingPlans().filter { $0.turn == turn }
        guard valid, !Task.isCancelled else { return }
        plans = pending
    }
    func show() async {
        await refresh()
        guard valid, !Task.isCancelled else { return }
        guard !plans.isEmpty else { notifyEnd(); return }
        if panel == nil {
            let window = AgentReviewPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                                          styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = actionText(language, "План Jarvis", "Jarvis plan")
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.level = .floating; window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.020, green: 0.039, blue: 0.063, alpha: 1)
            window.contentView = NSHostingView(rootView: AgentApprovalView(controller: self))
            window.delegate = self; window.center(); panel = window
        }
        panel?.orderFrontRegardless() // Never activate Jarvis or make this panel key.
    }
    func approve(_ plan: AgentActionPlan) {
        guard valid, plan.turn == turn, !working.contains(plan.id), results[plan.id] == nil else { return }
        working.insert(plan.id)
        jobs[plan.id] = Task { [weak self, broker] in
            guard let self else { return }
            do {
                let token = try await broker.approve(plan: plan.id)
                try Task.checkCancellation()
                guard self.valid else { return }
                let outcome = try await broker.commit(plan: plan.id, token: token)
                guard self.valid, !Task.isCancelled else { return }
                switch outcome {
                case .done(let summary): self.results[plan.id] = summary
                case .partial(let summary, let details): self.results[plan.id] = summary + " " + details
                case .failed(let reason): self.results[plan.id] = reason
                default: self.results[plan.id] = actionText(self.language, "Дію не виконано.", "Action was not executed.")
                }
                self.onOutcome(plan, outcome)
            } catch {
                if self.valid { self.results[plan.id] = actionText(self.language, "План скасовано або термін підтвердження минув.", "The plan was cancelled or its approval expired.") }
            }
            self.working.remove(plan.id); self.jobs.removeValue(forKey: plan.id)
            self.finishIfSettled()
        }
    }
    func reject(_ plan: AgentActionPlan) {
        guard valid, plan.turn == turn, !working.contains(plan.id) else { return }
        results[plan.id] = actionText(language, "Відхилено.", "Rejected.")
        Task { await broker.reject(plan: plan.id) }
        finishIfSettled()
    }
    private func finishIfSettled() {
        guard valid, !plans.isEmpty, working.isEmpty, plans.allSatisfy({ results[$0.id] != nil }) else { return }
        notifyEnd()
    }
    private func notifyEnd() {
        guard !endNotified else { return }
        endNotified = true; onEnd()
    }
    func dismiss() {
        invalidate(); panel?.contentView = nil; panel?.close(); panel = nil
    }
    func windowWillClose(_ notification: Notification) {
        invalidate(); panel?.contentView = nil; panel = nil
    }
    private func invalidate() {
        guard valid else { return }; valid = false
        for job in jobs.values { job.cancel() }; jobs.removeAll()
        Task { [broker, turn] in await broker.cancel(turn: turn) }
        notifyEnd()
    }
    func description(_ action: Action) -> String {
        func literal(_ value: String) -> String {
            // Make control/bidi characters visible in review without changing actual parameters.
            value.unicodeScalars.map { scalar in
                if CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                    return "\\u{" + String(scalar.value, radix: 16) + "}"
                }
                return String(scalar)
            }.joined()
        }
        switch action {
        case .openApp(let name): return actionText(language, "Відкрити: ", "Open: ") + literal(name)
        case .activateApp(let name): return actionText(language, "Активувати: ", "Activate: ") + literal(name)
        case .quitApp(let name): return actionText(language, "Закрити: ", "Quit: ") + literal(name)
        case .openURL(let url): return actionText(language, "Відкрити сайт: ", "Open URL: ") + literal(url)
        case .webSearch(let query): return actionText(language, "Пошук: ", "Search: ") + literal(query)
        case .windowMinimize: return actionText(language, "Згорнути активне вікно", "Minimize active window")
        case .windowMaximize: return actionText(language, "Розгорнути активне вікно", "Maximize active window")
        case .windowLeftHalf: return actionText(language, "Активне вікно — ліворуч", "Active window — left half")
        case .windowRightHalf: return actionText(language, "Активне вікно — праворуч", "Active window — right half")
        case .volumeSet(let percent): return actionText(language, "Гучність: ", "Volume: ") + "\(percent)%"
        case .volumeStep(let step): return actionText(language, "Змінити гучність на ", "Change volume by ") + "\(step)%"
        case .mute(let muted): return muted ? actionText(language, "Вимкнути звук", "Mute") : actionText(language, "Увімкнути звук", "Unmute")
        case .dictate: return actionText(language, "Диктування недоступне для AI-планів", "Dictation is unavailable for AI plans")
        }
    }
}

private final class AgentReviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor struct AgentApprovalView: View {
    @ObservedObject var controller: AgentApprovalController
    private let cyan = Color(red: 0.204, green: 0.902, blue: 0.941)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(actionText(controller.language, "ПЕРЕВІРТЕ ПЛАН", "REVIEW PLAN"))
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(cyan)
            Text(actionText(controller.language, "Кожна дія виконується лише після вашого підтвердження.", "Each action runs only after your approval."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(controller.plans, id: \.id) { plan in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(controller.description(plan.action)).font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                            if let result = controller.results[plan.id] {
                                Text(result).font(.system(size: 13)).foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    if controller.working.contains(plan.id) {
                                        ProgressView().controlSize(.small)
                                        Text(actionText(controller.language, "Виконую…", "Running…")).font(.system(size: 13))
                                    } else {
                                        Button(actionText(controller.language, "Підтвердити один раз", "Approve once")) { controller.approve(plan) }
                                            .buttonStyle(.borderedProminent).tint(cyan)
                                            .foregroundStyle(Color(red: 0.020, green: 0.039, blue: 0.063))
                                        Button(actionText(controller.language, "Відхилити", "Reject")) { controller.reject(plan) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .padding(14).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.16)))
                    }
                }
            }
            HStack {
                Spacer()
                Button(actionText(controller.language, "Закрити й скасувати решту", "Close and cancel remaining")) { controller.dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24).padding(.top, 18)
        .foregroundStyle(Color(red: 0.902, green: 0.945, blue: 0.957))
        .background(Color(red: 0.020, green: 0.039, blue: 0.063))
        .preferredColorScheme(.dark)
    }
}
