import Foundation

/// One inference slot plus the newest waiting segment. Invalidation drops stale
/// work without pretending that an already-running model call has finished.
struct WakeScreeningQueue<Element> {
    struct Ticket: Equatable { fileprivate let generation: UInt64 }
    private var generation: UInt64 = 0
    private var inFlight: Ticket?
    private var pending: Element?

    mutating func submit(_ element: Element) -> (ticket: Ticket, element: Element)? {
        if inFlight != nil { pending = element; return nil }
        generation &+= 1
        let ticket = Ticket(generation: generation)
        inFlight = ticket
        return (ticket, element)
    }
    func isCurrent(_ ticket: Ticket) -> Bool { inFlight == ticket && ticket.generation == generation }
    mutating func invalidate() {
        generation &+= 1
        pending = nil
    }
    mutating func finish(_ ticket: Ticket) -> Element? {
        guard inFlight == ticket else { return nil }
        inFlight = nil
        let next = pending; pending = nil
        return next
    }
}

/// Execution activity outlives audio recording and may outlive an acknowledgment.
/// A completion from an older voice turn cannot clear the newer turn's controls.
struct RequestActivity {
    enum Phase { case command, agent, approval }
    private(set) var turn: Int?
    private(set) var phase: Phase?
    var active: Bool { turn != nil }
    mutating func begin(turn: Int, phase: Phase) { self.turn = turn; self.phase = phase }
    mutating func finish(turn: Int) { if self.turn == turn { cancel() } }
    mutating func cancel() { turn = nil; phase = nil }
    func canCancel(audioBusy: Bool, speaking: Bool) -> Bool { active || audioBusy || speaking }
}
