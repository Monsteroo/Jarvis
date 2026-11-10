import Foundation

struct WebActions {
    static func validatedURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.count <= 8192,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { throw ActionError.invalidParameters }
        let candidate = raw.contains(":") ? raw : "https://" + raw
        guard let parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { throw ActionError.invalidParameters }
        return url
    }

    static func searchURL(_ query: String) throws -> URL {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 2048 else { throw ActionError.invalidParameters }
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = parts.url else { throw ActionError.invalidParameters }
        return url
    }
}
