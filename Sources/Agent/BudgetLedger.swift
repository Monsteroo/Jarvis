import Foundation

/// USD with six decimal places, rounded upward at the external-data boundary.
struct Money: Codable, Equatable, Comparable, Sendable {
    let micros: Int64
    static let zero = Money(micros: 0)
    static func usd(_ value: String) throws -> Money {
        guard value.range(of: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { throw BudgetError.invalidAmount }
        return try usd(decimal)
    }
    static func usd(_ value: Decimal) throws -> Money {
        guard !value.isNaN, value >= 0, value <= 1000 else { throw BudgetError.invalidAmount }
        var scaled = value * 1_000_000, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .up)
        return Money(micros: NSDecimalNumber(decimal: rounded).int64Value)
    }
    static func < (a: Money, b: Money) -> Bool { a.micros < b.micros }
}
enum BudgetError: Error { case invalidAmount, exhausted, unknownReservation, corruptLedger }
struct BudgetSnapshot { let committed: Money; let limit: Money }

actor BudgetLedger {
    private struct Reservation: Codable { let month: String; let micros: Int64 }
    private struct State: Codable {
        var version = 1
        var spent: [String: Int64] = [:]
        var reservations: [String: Reservation] = [:]
    }
    private let file: URL
    private let limit: Money
    private let perRequest: Money
    private let now: @Sendable () -> Date
    init(file: URL, monthlyLimit: Money = Money(micros: 10_000_000), requestLimit: Money = Money(micros: 250_000), now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard monthlyLimit.micros > 0, monthlyLimit.micros <= 10_000_000,
              requestLimit.micros > 0, requestLimit <= monthlyLimit else { throw BudgetError.invalidAmount }
        self.file = file; limit = monthlyLimit; perRequest = requestLimit; self.now = now
        try PrivateAgentFiles.directory(file.deletingLastPathComponent())
    }
    private func month() -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: now())
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
    private func load() throws -> State {
        guard let data = try PrivateAgentFiles.read(file) else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              state.spent.values.allSatisfy({ (0...1_000_000_000).contains($0) }),
              state.reservations.values.allSatisfy({ (1...10_000_000).contains($0.micros) }),
              state.reservations.count <= 10_000 else { throw BudgetError.corruptLedger }
        return state
    }
    private func committed(_ state: State, month: String) -> Int64 {
        (state.spent[month] ?? 0) + state.reservations.values.filter { $0.month == month }.reduce(0) { $0 + $1.micros }
    }
    func reserve(_ maximum: Money) throws -> UUID {
        guard maximum.micros > 0, maximum <= perRequest else { throw BudgetError.invalidAmount }
        return try PrivateAgentFiles.lock(file) {
            var state = try load(); let key = month()
            guard committed(state, month: key) + maximum.micros <= limit.micros else { throw BudgetError.exhausted }
            let id = UUID(); state.reservations[id.uuidString] = Reservation(month: key, micros: maximum.micros)
            try PrivateAgentFiles.write(JSONEncoder().encode(state), to: file)
            return id
        }
    }
    /// Missing/incomplete usage conservatively spends the full reservation, even after restart.
    func settle(_ id: UUID, actual: Money?, complete: Bool) throws {
        try PrivateAgentFiles.lock(file) {
            var state = try load()
            guard let reservation = state.reservations.removeValue(forKey: id.uuidString) else { throw BudgetError.unknownReservation }
            if let actual, !(0...1_000_000_000).contains(actual.micros) { throw BudgetError.invalidAmount }
            let charge = complete && actual != nil ? actual!.micros : max(reservation.micros, actual?.micros ?? 0)
            state.spent[reservation.month, default: 0] += charge
            try PrivateAgentFiles.write(JSONEncoder().encode(state), to: file)
        }
    }
    func snapshot() throws -> BudgetSnapshot {
        try PrivateAgentFiles.lock(file) { BudgetSnapshot(committed: Money(micros: committed(try load(), month: month())), limit: limit) }
    }
}
