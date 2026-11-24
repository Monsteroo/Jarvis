import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case assistant, diagnostics
    var id: String { rawValue }
}

enum StageState: Equatable { case pending, active, done, failed }

/// Real per-turn pipeline stages. Nothing here is simulated.
struct TurnStages: Equatable {
    var record: StageState = .pending
    var recognize: StageState = .pending
    var text: StageState = .pending
    var audioSeconds: Double?
    var asrSeconds: Double?
    var responseSeconds: Double?
    /// Real executor result for the recognised command; nothing simulated.
    var action: StageState = .pending
    var actionNote: String?
}

/// Main-thread UI state shared by the main window, HUD and status menu.
final class VoiceStore: ObservableObject {
    @Published var machine = VoiceMachine()
    @Published var section: AppSection = .assistant
    @Published var languageIndex = 0
    @Published var modelIndex = 0
    @Published var hotKeyAvailable = true
    @Published var permissionDenied = false
    @Published var permissionPending = false
    /// Voice activation: model loading, last error, and a request waiting for mic permission.
    @Published var wakeLoading = false
    @Published var wakeError = ""
    @Published var pendingWake = false
    @Published var escapeUnavailable = false
    @Published var recordElapsed = 0.0
    /// True when the current recording was started by the PTT key.
    @Published var keyRecording = true
    @Published var recordLimit = 15
    @Published var stages = TurnStages()
    @Published var diagnosticArmed = false
    @Published var diagnosticLabel = "Збереження аудіо вимкнено."
    @Published var diagnosticURL: URL?
    @Published var measuring = false
    @Published var measurementPrompt = ""
    @Published var canSkipPrompt = false
    @Published var mainVisible = true
    @Published var hudVisible = false
    /// Result of the last executed command (real executor outcome).
    @Published var actionMessage = ""
    @Published var reduceMotion = false
    /// Spoken replies (off = text only) and the chosen voice per language.
    @Published var spokenReplies = UserDefaults.standard.object(forKey: "spokenReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(spokenReplies, forKey: "spokenReplies") }
    }
    @Published var voiceUK = UserDefaults.standard.string(forKey: "voiceUK") ?? "" {
        didSet { UserDefaults.standard.set(voiceUK, forKey: "voiceUK") }
    }
    @Published var voiceEN = UserDefaults.standard.string(forKey: "voiceEN") ?? "" {
        didSet { UserDefaults.standard.set(voiceEN, forKey: "voiceEN") }
    }
    /// ElevenLabs voice (cloud, opt-in). Only reply text is sent.
    /// On by default: without a saved key the macOS voice answers anyway.
    @Published var cloudVoiceEnabled = UserDefaults.standard.object(forKey: "cloudVoiceEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cloudVoiceEnabled, forKey: "cloudVoiceEnabled") }
    }
    @Published var elevenVoiceID = UserDefaults.standard.string(forKey: "elevenVoiceID") ?? "K74pMNmxBnAW8cPpeyph" {
        didSet { UserDefaults.standard.set(elevenVoiceID, forKey: "elevenVoiceID") }
    }
    /// 0 = no limit of our own (default): ElevenLabs errors switch to the macOS voice.
    @Published var cloudCharacterLimit = UserDefaults.standard.object(forKey: "cloudCharacterLimit") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(cloudCharacterLimit, forKey: "cloudCharacterLimit") }
    }
    /// Local text log of conversations (the owner asked for it, to review
    /// mistakes and latency). Text only, never audio; can be switched off.
    @Published var conversationLog = UserDefaults.standard.object(forKey: "conversationLog") as? Bool ?? true {
        didSet { UserDefaults.standard.set(conversationLog, forKey: "conversationLog") }
    }
    @Published var conversationLogStatus = ""
    /// Owner decision 24.11.2026 (D1): direct OpenAI "brain" instead of a Goose process per request.
    @Published var brainEnabled = UserDefaults.standard.object(forKey: "brainEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(brainEnabled, forKey: "brainEnabled") }
    }
    /// Owner decision 24.11.2026: AI-proposed actions run at once; this brings the review panel back.
    @Published var confirmAgentActions = UserDefaults.standard.object(forKey: "confirmAgentActions") as? Bool ?? false {
        didSet { UserDefaults.standard.set(confirmAgentActions, forKey: "confirmAgentActions") }
    }
    /// AI agent for requests the simple rules do not understand (opt-out).
    @Published var agentEnabled = UserDefaults.standard.object(forKey: "agentEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(agentEnabled, forKey: "agentEnabled") }
    }
    @Published var agentModel = UserDefaults.standard.string(forKey: "agentModel") ?? "gpt-5.4-mini" {
        didSet { UserDefaults.standard.set(agentModel, forKey: "agentModel") }
    }
    @Published var hasOpenAIKey = false
    @Published var agentRuntimeReady = false
    @Published var agentStatus = ""
    @Published var agentBudget = ""
    @Published var hasCloudKey = false
    @Published var cloudStatus = ""
    @Published var cloudUsed = 0

    func refreshCloudUsage() { cloudUsed = VoiceUsageLedger.load().used(at: Date()) }

    @Published var voicesUK: [SpeechOutput.Voice] = []
    @Published var voicesEN: [SpeechOutput.Voice] = []

    /// Installed voices; a saved choice that is no longer installed falls back
    /// to the first male voice (or the first voice when there is none).
    func loadVoices() {
        voicesUK = SpeechOutput.voices(for: "uk")
        voicesEN = SpeechOutput.voices(for: "en")
        if !voicesUK.contains(where: { $0.id == voiceUK }) { voiceUK = voicesUK.first?.id ?? "" }
        if !voicesEN.contains(where: { $0.id == voiceEN }) {
            voiceEN = (voicesEN.first { $0.male && $0.language == "en-GB" } ?? voicesEN.first)?.id ?? ""
        }
    }

    /// Quiet cue when "Jarvis" is recognised; the user can turn it off.
    @Published var acknowledgmentSound = UserDefaults.standard.object(forKey: "acknowledgmentSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(acknowledgmentSound, forKey: "acknowledgmentSound") }
    }
    let modelTitles = ["Parakeet UK", "Whisper small", "Whisper base"]
    let languageTitles = ["Українська", "English"]

    @Published var requestActivity = RequestActivity()
    var canCancel: Bool { requestActivity.canCancel(audioBusy: machine.busy, speaking: machine.speaking) }

    var phase: VoicePhase { machine.phase }
    var mode: FilamentMode { FilamentMode(machine.phase, microphoneEnabled: machine.microphoneEnabled) }
    var emptyResult: Bool { phase == .result && machine.transcript.isEmpty }

    var headline: String {
        switch phase {
        case .loadingModel: return "Завантаження моделі"
        case .modelUnavailable: return "Модель недоступна"
        case .microphoneOff: return "Мікрофон вимкнено"
        case .ready: return "Готово"
        case .wakeListening: return "Чекаю «Jarvis»"
        case .recording: return "Слухаю"
        case .transcribing: return "Розпізнаю"
        case .result: return emptyResult ? "Мовлення не знайдено" : "Розпізнано"
        case .error: return "Помилка"
        case .speaking: return "Говорю"
        case .executing: return "Недоступно"
        }
    }

    var symbol: String {
        switch phase {
        case .microphoneOff: return "mic.slash"
        case .wakeListening: return "ear"
        case .recording: return "waveform"
        case .transcribing: return "text.magnifyingglass"
        case .result: return emptyResult ? "waveform.slash" : "checkmark"
        case .error, .modelUnavailable: return "exclamationmark.triangle"
        case .loadingModel: return "hourglass"
        default: return "waveform"
        }
    }

    var detail: String {
        if !machine.message.isEmpty && !machine.busy { return machine.message }
        if !actionMessage.isEmpty && !machine.busy { return actionMessage }
        if !wakeError.isEmpty && !machine.busy { return wakeError }
        switch phase {
        case .loadingModel: return "Parakeet завантажується в пам’ять цього Mac. Запис поки недоступний."
        case .modelUnavailable: return "Локальна модель не завантажилась. Перевірте встановлення або виберіть іншу в «Діагностиці»."
        case .microphoneOff:
            if permissionDenied { return "Доступ до мікрофона заборонено. Надайте його: Системні параметри → Конфіденційність і безпека → Мікрофон." }
            return "Звук не захоплюється. Натисніть «Увімкнути мікрофон», щоб дозволити голосове введення."
        case .ready:
            if !hotKeyAvailable { return "Не вдалося зареєструвати ⌃⌥Пробіл. Закрийте інший Jarvis або програму з цим скороченням." }
            return "Утримуйте ⌃⌥Пробіл, говоріть і відпустіть. Мікрофон працює лише під час утримання."
        case .wakeListening:
            return "Скажіть «Jarvis» і команду — або утримуйте ⌃⌥Пробіл. Фрази розпізнаються локально; без «Jarvis» відкидаються одразу."
        case .recording:
            let esc = escapeUnavailable ? "кнопка «Скасувати»" : "Esc — скасувати"
            if !keyRecording {
                return String(format: "Говоріть команду — пауза завершить запис · %.1f с / %d с · %@", recordElapsed, recordLimit, esc)
            }
            return String(format: "Відпустіть ⌃⌥Пробіл для розпізнавання · %.1f с / %d с · %@", recordElapsed, recordLimit, esc)
        case .transcribing:
            return machine.timedOut ? "Досягнуто ліміту запису. Розпізнаю на цьому Mac…"
                : (machine.wakeEnabled ? "Запис команди завершено. Розпізнаю на цьому Mac…" : "Мікрофон вимкнено. Розпізнаю на цьому Mac…")
        case .result: return machine.wakeEnabled ? "Скажіть «Jarvis» або утримуйте ⌃⌥Пробіл для наступної фрази." : "Утримуйте ⌃⌥Пробіл для наступної фрази."
        case .error: return "Спробуйте ще раз."
        case .speaking: return "Esc — зупинити. Поки я говорю, «Jarvis» не слухається."
        case .executing: return ""
        }
    }

    var localBadge: (String, Color) {
        switch machine.model {
        case .loading: return ("Модель завантажується", ArcPalette.amber)
        case .failed: return ("Модель недоступна", Color.red)
        case .ready: return ("Локально · \(modelTitles[modelIndex])", Color.green)
        }
    }
}

struct VoiceActions {
    var toggleMicrophone: () -> Void = {}
    var toggleWake: () -> Void = {}
    var cancel: () -> Void = {}
    var copy: () -> Void = {}
    var setLanguage: (Int) -> Void = { _ in }
    var setModel: (Int) -> Void = { _ in }
    var toggleDiagnostic: () -> Void = {}
    var revealDiagnostic: () -> Void = {}
    var setMeasuring: (Bool) -> Void = { _ in }
    var skipPrompt: () -> Void = {}
    var previewVoice: (String) -> Void = { _ in }
    var saveCloudKey: (String) -> Void = { _ in }
    var deleteCloudKey: () -> Void = {}
    var saveOpenAIKey: (String) -> Void = { _ in }
    var deleteOpenAIKey: () -> Void = {}
    var openMicrophoneSettings: () -> Void = {}
    var revealConversations: () -> Void = {}
    var clearConversations: () -> Void = {}
}

// MARK: - Shared pieces

private struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color = ArcPalette.stroke
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(
                LinearGradient(colors: [Color.white.opacity(0.06), ArcPalette.cyan.opacity(0.025)],
                               startPoint: .top, endPoint: .bottom)))
            .background(RoundedRectangle(cornerRadius: radius).fill(ArcPalette.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [tint.opacity(1.6), tint.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
    }
}

extension View {
    fileprivate func glass(radius: CGFloat = 16, tint: Color = ArcPalette.stroke) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint))
    }
}

struct MicButton: View {
    @ObservedObject var store: VoiceStore
    let action: () -> Void
    var compact = false
    var body: some View {
        let on = store.machine.microphoneEnabled
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: on ? "mic.slash" : "mic")
                    .font(.system(size: compact ? 14 : 16, weight: .medium))
                if !compact { Text(on ? "Вимкнути мікрофон" : "Увімкнути мікрофон").font(.system(size: 14, weight: .medium)) }
            }
            .foregroundStyle(ArcPalette.text)
            .padding(.horizontal, compact ? 0 : 18)
            .frame(width: compact ? 40 : nil, height: compact ? 40 : 46)
            .background(compact ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(Color.clear))
            .clipShape(compact ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ConditionalGlass(enabled: !compact, tint: on ? ArcPalette.stroke : ArcPalette.amber.opacity(0.45)))
        .disabled(store.permissionPending)
        .help(on ? "Повністю вимкнути мікрофон і скасувати поточний запис" : "Дозволити голосове введення через ⌃⌥Пробіл")
        .accessibilityLabel(on ? "Вимкнути мікрофон" : "Увімкнути мікрофон")
    }
}

/// Explicit opt-in for activation by the word "Jarvis". Shows its own state in
/// text and icon, not only colour.
struct WakeButton: View {
    @ObservedObject var store: VoiceStore
    let action: () -> Void
    var body: some View {
        let on = store.machine.wakeEnabled
        Button(action: action) {
            HStack(spacing: 8) {
                if store.wakeLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: on ? "ear" : "ear.badge.waveform").font(.system(size: 15, weight: .medium))
                }
                Text(on ? "«Jarvis»: увімк." : "«Jarvis»: вимк.").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(on ? ArcPalette.cyan : ArcPalette.secondary)
            .padding(.horizontal, 16).frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(radius: 14, tint: on ? ArcPalette.cyan.opacity(0.45) : ArcPalette.stroke)
        .disabled(store.wakeLoading || store.permissionPending)
        .help(on ? "Вимкнути активацію словом «Jarvis». PTT залишиться."
                 : "Увімкнути активацію словом «Jarvis». Мікрофон слухатиме слово локально; аудіо не зберігається.")
        .accessibilityLabel(on ? "Активація словом Jarvis увімкнена" : "Активація словом Jarvis вимкнена")
    }
}

private struct ConditionalGlass: ViewModifier {
    let enabled: Bool
    let tint: Color
    func body(content: Content) -> some View {
        if enabled { content.glass(radius: 14, tint: tint) } else { content }
    }
}

struct StateLabel: View {
    @ObservedObject var store: VoiceStore
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.symbol).font(.system(size: size + 2, weight: .medium))
            Text(store.headline.uppercased())
                .font(.system(size: size, weight: .semibold))
                .tracking(size * 0.22)
        }
        .foregroundStyle(store.phase == .microphoneOff ? ArcPalette.secondary : ArcPalette.cyan)
        .shadow(color: store.phase == .microphoneOff ? .clear : ArcPalette.cyan.opacity(0.6), radius: 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Стан: \(store.headline)")
    }
}

// MARK: - Main window

/// Static ARC Current atmosphere: deep navy, a cyan bloom behind the
/// filaments and a faint amber horizon. Decoration only: nothing here moves
/// or reacts, so it never pretends to show audio or progress.
struct ArcBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [ArcPalette.backgroundTop, ArcPalette.background], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [ArcPalette.cyan.opacity(0.16), ArcPalette.cyan.opacity(0.04), .clear],
                           center: UnitPoint(x: 0.58, y: 0.30), startRadius: 10, endRadius: 520)
            RadialGradient(colors: [ArcPalette.amber.opacity(0.09), .clear],
                           center: UnitPoint(x: 1.0, y: 0.95), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [.clear, Color.black.opacity(0.45)],
                           center: .center, startRadius: 300, endRadius: 900)
        }
    }
}

struct MainView: View {
    @ObservedObject var store: VoiceStore
    let level: LevelStore
    let actions: VoiceActions

    var body: some View {
        ZStack(alignment: .top) {
            ArcBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    Sidebar(store: store)
                    Rectangle().fill(ArcPalette.stroke.opacity(0.6)).frame(width: 1)
                    Group {
                        switch store.section {
                        case .assistant: AssistantView(store: store, level: level, actions: actions)
                        case .diagnostics: DiagnosticsView(store: store, actions: actions)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Text("JARVIS")
                .font(.system(size: 15, weight: .semibold))
                .tracking(6)
                .foregroundStyle(ArcPalette.text)
                .shadow(color: ArcPalette.cyan.opacity(0.55), radius: 8)
                .padding(.leading, 92)
            Spacer()
            let badge = store.localBadge
            HStack(spacing: 8) {
                Circle().fill(badge.1).frame(width: 8, height: 8)
                Text(badge.0).font(.system(size: 12, weight: .medium)).foregroundStyle(ArcPalette.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glass(radius: 13)
            .accessibilityElement(children: .combine)
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, ArcPalette.cyan.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var store: VoiceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            item(.assistant, "Асистент", "waveform")
            item(.diagnostics, "Діагностика", "stethoscope")
            Text("НЕЗАБАРОМ")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(ArcPalette.secondary.opacity(0.7))
                .padding(.top, 18).padding(.leading, 14)
            unavailable("Завдання", "checkmark.square")
            unavailable("Сценарії", "square.3.layers.3d")
            unavailable("Пам’ять", "book.closed")
            unavailable("Налаштування", "slider.horizontal.3")
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("«Jarvis» — якщо ввімкнено").font(.system(size: 11)).foregroundStyle(ArcPalette.secondary)
                Text("⌃⌥Пробіл — говорити").font(.system(size: 11)).foregroundStyle(ArcPalette.secondary)
                Text("Esc — скасувати").font(.system(size: 11)).foregroundStyle(ArcPalette.secondary)
                Text("Аудіо лишається на цьому Mac").font(.system(size: 11)).foregroundStyle(ArcPalette.secondary.opacity(0.8))
            }
            .padding(.leading, 14).padding(.bottom, 18)
        }
        .padding(.top, 18).padding(.horizontal, 12)
        .frame(width: 214)
        .background(Color.black.opacity(0.20))
    }

    private func item(_ section: AppSection, _ title: String, _ symbol: String) -> some View {
        let selected = store.section == section
        return Button { store.section = section } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20)
                    .foregroundStyle(selected ? ArcPalette.cyan : ArcPalette.secondary)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? ArcPalette.text : ArcPalette.secondary)
            .padding(.horizontal, 14).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? ArcPalette.cyan.opacity(0.13) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ArcPalette.cyan.opacity(0.35) : .clear))
            .shadow(color: selected ? ArcPalette.cyan.opacity(0.25) : .clear, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Plain labels, not buttons: these sections do not exist yet.
    private func unavailable(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20)
            Text(title).font(.system(size: 13))
        }
        .foregroundStyle(ArcPalette.secondary.opacity(0.45))
        .padding(.horizontal, 14).frame(height: 34)
        .help("Ще не реалізовано")
        .accessibilityLabel("\(title), ще не реалізовано")
    }
}

struct AssistantView: View {
    @ObservedObject var store: VoiceStore
    let level: LevelStore
    let actions: VoiceActions

    var body: some View {
        VStack(spacing: 0) {
            StateLabel(store: store).padding(.top, 22)
            FilamentField(level: level, mode: store.mode, animate: store.mainVisible && !store.reduceMotion)
                .frame(minHeight: 160, maxHeight: 320)
                .padding(.horizontal, -12)
            transcript
                .frame(minHeight: 70)
            Text(store.detail)
                .font(.system(size: 13))
                .foregroundStyle(ArcPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .padding(.top, 6)
            if store.permissionDenied && !store.machine.microphoneEnabled {
                Button("Відкрити налаштування мікрофона", action: actions.openMicrophoneSettings)
                    .padding(.top, 8)
            }
            Spacer(minLength: 14)
            StagesRow(store: store)
            HStack(spacing: 14) {
                commandField
                if store.canCancel {
                    Button(action: actions.cancel) {
                        Label("Скасувати", systemImage: "xmark").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ArcPalette.text).padding(.horizontal, 16).frame(height: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).glass(radius: 14)
                    .keyboardShortcut(.cancelAction)
                }
                WakeButton(store: store, action: actions.toggleWake)
                MicButton(store: store, action: actions.toggleMicrophone)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
    }

    @ViewBuilder private var transcript: some View {
        let text = store.machine.transcript
        if text.isEmpty {
            Text("Скажіть команду")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(ArcPalette.text.opacity(0.62))
                .shadow(color: ArcPalette.cyan.opacity(0.25), radius: 14)
        } else {
            Text("«\(text)»")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(store.machine.busy ? ArcPalette.text.opacity(0.45) : ArcPalette.text)
                .shadow(color: ArcPalette.cyan.opacity(store.machine.busy ? 0 : 0.3), radius: 16)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.45)
                .textSelection(.enabled)
                .contextMenu { Button("Копіювати текст", action: actions.copy) }
                .accessibilityLabel("Останній розпізнаний текст: \(text)")
        }
    }

    private var commandField: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(ArcPalette.cyan)
            Text("Текстові команди з’являться згодом; зараз — голосом")
                .font(.system(size: 14)).foregroundStyle(ArcPalette.secondary.opacity(0.7))
                .lineLimit(1)
            Spacer()
            Picker("Мова", selection: Binding(get: { store.languageIndex }, set: actions.setLanguage)) {
                Text("UK").tag(0)
                Text("EN").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 96)
            .disabled(store.machine.busy)
            .help("Мова розпізнавання")
            .accessibilityLabel("Мова розпізнавання")
        }
        .padding(.horizontal, 16).frame(height: 46)
        .glass(radius: 14)
    }
}

struct StagesRow: View {
    @ObservedObject var store: VoiceStore
    var body: some View {
        let s = store.stages
        HStack(spacing: 0) {
            stage("Запис", "mic", s.record,
                  store.phase == .recording ? String(format: "%.1f с", store.recordElapsed) : s.audioSeconds.map { String(format: "%.1f с аудіо", $0) })
            connector(s.record == .done)
            stage("Розпізнавання", "text.magnifyingglass", s.recognize, s.asrSeconds.map { String(format: "ASR %.2f с", $0) })
            connector(s.recognize == .done)
            stage("Текст", "text.quote", s.text, s.responseSeconds.map { String(format: "відповідь %.2f с", $0) })
            connector(s.text == .done)
            stage("Виконання дій", "gearshape.2", s.action, s.actionNote)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .glass(radius: 18)
    }

    private func stage(_ title: String, _ symbol: String, _ state: StageState, _ note: String?) -> some View {
        let tint: Color = state == .failed ? ArcPalette.amber : (state == .pending ? ArcPalette.secondary : ArcPalette.cyan)
        let status: String
        switch state {
        case .pending: status = "очікує"
        case .active: status = "триває"
        case .done: status = "готово"
        case .failed: status = "помилка"
        }
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(state == .pending ? 0.04 : 0.12))
                RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35))
                Image(systemName: state == .done ? "checkmark" : (state == .failed ? "exclamationmark" : symbol))
                    .font(.system(size: 16, weight: .medium))
            }
            .frame(width: 40, height: 40)
            .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(state == .pending ? ArcPalette.secondary : ArcPalette.text)
                Text(note ?? status).font(.system(size: 11).monospacedDigit()).foregroundStyle(ArcPalette.secondary)
            }
            .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status)\(note.map { ", " + $0 } ?? "")")
    }

    private func connector(_ lit: Bool) -> some View {
        Rectangle()
            .fill(lit ? ArcPalette.cyan.opacity(0.55) : ArcPalette.secondary.opacity(0.18))
            .frame(height: 1).frame(minWidth: 14, maxWidth: .infinity)
            .padding(.horizontal, 10)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject var store: VoiceStore
    let actions: VoiceActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Діагностика").font(.system(size: 24, weight: .semibold)).foregroundStyle(ArcPalette.text)
                section("Локальна модель") {
                    HStack {
                        Picker("Модель", selection: Binding(get: { store.modelIndex }, set: actions.setModel)) {
                            ForEach(store.modelTitles.indices, id: \.self) { Text(store.modelTitles[$0]).tag($0) }
                        }
                        .frame(width: 260)
                        .disabled(store.machine.busy || store.machine.model == .loading)
                        Picker("Мова", selection: Binding(get: { store.languageIndex }, set: actions.setLanguage)) {
                            ForEach(store.languageTitles.indices, id: \.self) { Text(store.languageTitles[$0]).tag($0) }
                        }
                        .frame(width: 220)
                        .disabled(store.machine.busy)
                    }
                    note("Ліміт запису: \(store.recordLimit) с. Parakeet UK — модель за замовчуванням; Whisper — резервні варіанти.")
                }
                section("Розумний агент (OpenAI через Goose)") {
                    AgentSettings(store: store, actions: actions)
                    Toggle("Швидкий мозок: прямий OpenAI з пам'яттю розмови (вимкнено — Goose)", isOn: $store.brainEnabled)
                    Toggle("Підтверджувати дії AI у вікні плану", isOn: $store.confirmAgentActions)
                    note("Вимкнено: дії, які пропонує AI (відкрити програму чи сайт, вікна, гучність), виконуються одразу. Диктування від AI заборонене завжди. Esc скасовує.")
                }
                section("Журнал розмов") {
                    Toggle("Записувати розмови локально (текст і час етапів, без аудіо)", isOn: $store.conversationLog)
                    HStack {
                        Button("Показати у Finder", action: actions.revealConversations)
                        Button("Очистити журнал", action: actions.clearConversations)
                    }
                    if !store.conversationLogStatus.isEmpty { note(store.conversationLogStatus) }
                    note("Що ви сказали, що розпізнано, що відповів Jarvis і скільки тривав кожен етап. Лише на цьому Mac, у ~/Library/Application Support/Jarvis/conversations; файли старші за 30 днів видаляються.")
                }
                section("Голос відповідей") {
                    Toggle("Відповідати голосом (вимкнено — лише текст)", isOn: $store.spokenReplies)
                    CloudVoiceSettings(store: store, actions: actions)
                    voiceRow("Українська", selection: $store.voiceUK, voices: store.voicesUK, language: "uk")
                    voiceRow("English", selection: $store.voiceEN, voices: store.voicesEN, language: "en")
                    note("Голоси macOS, локально на цьому Mac. Українського чоловічого голосу в macOS немає — локальний нейроголос буде окремим кроком. Якісніші англійські голоси (Enhanced/Premium): Системні параметри → Універсальний доступ → Усний вміст → Системний голос → Керувати голосами; після завантаження перезапустіть Jarvis.")
                }
                section("Активація «Jarvis»") {
                    Toggle("Тихий звук, коли Jarvis почув слово активації", isOn: $store.acknowledgmentSound)
                    note("Звук синтезується на цьому Mac і не записується.")
                }
                section("Останній результат") {
                    HStack {
                        Button("Копіювати текст", action: actions.copy)
                            .disabled(store.machine.transcript.isEmpty)
                        if let a = store.stages.audioSeconds, let r = store.stages.responseSeconds, let asr = store.stages.asrSeconds {
                            Text(String(format: "Аудіо %.1f с · ASR %.2f с · відповідь %.2f с", a, asr, r))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ArcPalette.secondary)
                        }
                    }
                    note("Відповідь — час від відпускання клавіші (або ліміту запису) до появи тексту.")
                }
                section("Режим вимірювань") {
                    Toggle("Показувати фрази з docs/benchmarks/prompts.txt", isOn: Binding(get: { store.measuring }, set: actions.setMeasuring))
                        .disabled(store.machine.busy)
                    if store.measuring {
                        Text(store.measurementPrompt).font(.system(size: 18, weight: .semibold)).foregroundStyle(ArcPalette.text)
                            .textSelection(.enabled)
                        if store.canSkipPrompt {
                            Button("Пропустити фразу", action: actions.skipPrompt).disabled(store.machine.busy)
                        }
                    }
                    note("Записує текст і час у .runtime/measurements/uk-en-v1.jsonl. Аудіо не зберігається.")
                }
                section("Одноразовий WAV") {
                    HStack {
                        Button(store.diagnosticArmed ? "Скасувати збереження WAV" : "Зберегти наступну фразу у WAV",
                               action: actions.toggleDiagnostic)
                            .disabled(store.machine.busy)
                        Button("Показати WAV", action: actions.revealDiagnostic)
                            .disabled(store.diagnosticURL == nil)
                    }
                    note(store.diagnosticLabel)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func voiceRow(_ title: String, selection: Binding<String>, voices: [SpeechOutput.Voice], language: String) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(voices) { Text($0.label).tag($0.id) }
            }
            .frame(width: 420)
            .disabled(voices.isEmpty)
            Button("Прослухати") { actions.previewVoice(language) }
                .disabled(voices.isEmpty || store.machine.busy)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(ArcPalette.cyan)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(ArcPalette.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - HUD

struct HUDView: View {
    @ObservedObject var store: VoiceStore
    let level: LevelStore
    let actions: VoiceActions

    var body: some View {
        HStack(spacing: 14) {
            StateLabel(store: store, size: 12)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            FilamentField(level: level, mode: store.mode, animate: store.hudVisible && !store.reduceMotion, compact: true)
                .frame(height: 44)
            if store.canCancel {
                Button(action: actions.cancel) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ArcPalette.text)
                        .frame(width: 40, height: 40).background(Circle().fill(Color.white.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Скасувати")
                .accessibilityLabel("Скасувати")
            }
            MicButton(store: store, action: actions.toggleMicrophone, compact: true)
        }
        .padding(.leading, 22).padding(.trailing, 12)
        .frame(width: 520, height: 64)
        .background(Capsule().fill(ArcPalette.background.opacity(0.92)))
        .overlay(Capsule().strokeBorder(ArcPalette.cyan.opacity(0.28), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}


/// ElevenLabs settings: opt-in toggle, voice ID, key into Keychain, monthly limit.
struct CloudVoiceSettings: View {
    @ObservedObject var store: VoiceStore
    let actions: VoiceActions
    @State private var key = ""

    private let limits = [0, 20_000, 50_000, 100_000, 200_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Голос ElevenLabs (хмара; без інтернету чи ключа — голос macOS)", isOn: $store.cloudVoiceEnabled)
            HStack {
                Text("ID голосу")
                TextField("ID", text: $store.elevenVoiceID).frame(width: 260).font(.system(size: 12).monospaced())
            }
            HStack {
                if store.hasCloudKey {
                    Text("Ключ API збережено").foregroundStyle(ArcPalette.secondary)
                    Button("Видалити ключ", action: actions.deleteCloudKey)
                } else {
                    SecureField("Ключ API ElevenLabs", text: $key).frame(width: 260)
                    Button("Зберегти в Keychain") { actions.saveCloudKey(key); key = "" }.disabled(key.isEmpty)
                }
            }
            HStack {
                Picker("Ліміт на місяць", selection: $store.cloudCharacterLimit) {
                    ForEach(limits, id: \.self) { limit in
                        Text(limit == 0 ? "Без власного ліміту" : String(format: "%d тис. знаків (≈ $%.0f)", limit / 1000, Double(limit) / 1000 * ElevenLabsRequest.pricePerThousand)).tag(limit)
                    }
                }
                .frame(width: 340)
            }
            Text(String(format: "Цього місяця: %d знаків (≈ $%.2f за прайсом Flash v2.5).", store.cloudUsed,
                        Double(store.cloudUsed) / 1000 * ElevenLabsRequest.pricePerThousand))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ArcPalette.secondary)
            if !store.cloudStatus.isEmpty {
                Text(store.cloudStatus).font(.system(size: 12)).foregroundStyle(ArcPalette.secondary)
            }
            Text("ElevenLabs отримує лише текст відповіді; звук мікрофона не надсилається. Мова задається явно (uk або en). Будь-яка помилка ElevenLabs (кредити, ключ, мережа, понад 5 с очікування) — і відповідає голос macOS.")
                .font(.system(size: 12)).foregroundStyle(ArcPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// OpenAI key into Keychain, model name, monthly budget. Plans from the model
/// run only after the user presses «Підтвердити один раз» in the plan panel.
struct AgentSettings: View {
    @ObservedObject var store: VoiceStore
    let actions: VoiceActions
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Передавати агенту команди, яких не розуміють прості правила", isOn: $store.agentEnabled)
            HStack {
                Text("Модель")
                TextField("gpt-5.4-mini", text: $store.agentModel).frame(width: 220).font(.system(size: 12).monospaced())
            }
            HStack {
                if store.hasOpenAIKey {
                    Text("Ключ OpenAI збережено").foregroundStyle(ArcPalette.secondary)
                    Button("Видалити ключ", action: actions.deleteOpenAIKey)
                } else {
                    SecureField("Ключ API OpenAI", text: $key).frame(width: 260)
                    Button("Зберегти в Keychain") { actions.saveOpenAIKey(key); key = "" }.disabled(key.isEmpty)
                }
            }
            if !store.agentRuntimeReady {
                Text("Goose не вбудовано в цю збірку — агент недоступний.").font(.system(size: 12)).foregroundStyle(ArcPalette.amber)
            }
            if !store.agentBudget.isEmpty {
                Text(store.agentBudget).font(.system(size: 12).monospacedDigit()).foregroundStyle(ArcPalette.secondary)
            }
            if !store.agentStatus.isEmpty {
                Text(store.agentStatus).font(.system(size: 12)).foregroundStyle(ArcPalette.secondary)
            }
            Text("В OpenAI іде лише текст такої команди, аудіо — ні. Агент може лише запропонувати дію: вона виконається тільки після «Підтвердити один раз» у панелі плану. Ліміт — $10 на місяць.")
                .font(.system(size: 12)).foregroundStyle(ArcPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
