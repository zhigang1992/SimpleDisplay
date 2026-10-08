import Foundation

// Request/response protocol for the app's local control socket. Unlike the
// fire-and-forget `simpledisplay://` URL scheme, every request gets a reply,
// so the CLI can list displays and report whether an action actually worked.
//
// Wire format: one JSON-encoded `ControlRequest` terminated by "\n", answered
// by one JSON-encoded `ControlResponse` terminated by "\n", then the server
// closes the connection.

public enum ControlRequest: Codable, Equatable, Sendable {
    case list
    case modes(display: String)
    case setEnabled(display: String, enabled: Bool)
    case toggle(display: String)
    case setMain(display: String)
    case setMode(display: String, mode: ModeQuery)
    case forget(display: String)
}

public enum ControlResponse: Codable, Equatable, Sendable {
    case displays([DisplaySnapshot])
    case display(DisplaySnapshot)
    case modes([ModeSnapshot])
    case failure(String)
}

/// A display as seen over the control socket. `mode` is nil for remembered
/// disabled displays restored from a previous session, which have no live
/// mode information.
public struct DisplaySnapshot: Codable, Equatable, Sendable {
    public var id: UInt32
    public var uuid: String?
    public var name: String
    public var enabled: Bool
    public var main: Bool
    public var builtIn: Bool
    public var virtual: Bool
    /// True when the display has left the online list (disabled) and the row
    /// is kept from the app's memory so it can be re-enabled or forgotten.
    public var remembered: Bool
    public var mode: ModeSnapshot?

    public init(
        id: UInt32, uuid: String?, name: String, enabled: Bool, main: Bool,
        builtIn: Bool, virtual: Bool, remembered: Bool, mode: ModeSnapshot?
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.enabled = enabled
        self.main = main
        self.builtIn = builtIn
        self.virtual = virtual
        self.remembered = remembered
        self.mode = mode
    }
}

public struct ModeSnapshot: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var hiDPI: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, hiDPI: Bool) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }
}

/// What the caller asked for when changing resolution. Unset fields are
/// filled from the display's current mode where possible.
public struct ModeQuery: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hiDPI: Bool?
    public var refreshRate: Double?

    public init(width: Int, height: Int, hiDPI: Bool? = nil, refreshRate: Double? = nil) {
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
    }

    /// Parses "1920x1080" (also accepts "1920X1080" and "1920*1080").
    public static func parseSize(_ raw: String) -> (width: Int, height: Int)? {
        let parts = raw.lowercased().split(whereSeparator: { $0 == "x" || $0 == "*" })
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
            return nil
        }
        return (w, h)
    }
}

// MARK: - Display selection

public enum DisplaySelectorError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, candidates: [String])

    public var description: String {
        switch self {
        case .notFound(let query):
            return "no display matches '\(query)' (run `simpledisplayctl list`)"
        case .ambiguous(let query, let candidates):
            return "'\(query)' matches several displays: \(candidates.joined(separator: ", ")); use the id or UUID"
        }
    }
}

public enum DisplaySelector {
    /// Resolves a user-supplied display reference. Tried in order:
    /// `main`, `builtin`, numeric display id, UUID, exact name
    /// (case-insensitive), then a unique case-insensitive name substring.
    public static func resolve(
        _ query: String,
        in displays: [DisplaySnapshot]
    ) -> Result<DisplaySnapshot, DisplaySelectorError> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        switch lowered {
        case "main":
            return unique(trimmed, displays.filter(\.main))
        case "builtin", "built-in":
            return unique(trimmed, displays.filter(\.builtIn))
        default:
            break
        }

        if let id = UInt32(trimmed), let hit = displays.first(where: { $0.id == id }) {
            return .success(hit)
        }
        if let hit = displays.first(where: { $0.uuid?.lowercased() == lowered }) {
            return .success(hit)
        }
        let exact = displays.filter { $0.name.lowercased() == lowered }
        if !exact.isEmpty {
            return unique(trimmed, exact)
        }
        return unique(trimmed, displays.filter { $0.name.lowercased().contains(lowered) })
    }

    private static func unique(
        _ query: String,
        _ matches: [DisplaySnapshot]
    ) -> Result<DisplaySnapshot, DisplaySelectorError> {
        switch matches.count {
        case 0: return .failure(.notFound(query))
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous(query, candidates: matches.map { "\($0.name) (id \($0.id))" }))
        }
    }
}

// MARK: - Mode selection

public enum ModeMatcher {
    /// Picks the best available mode for `query`. Width and height must match
    /// exactly; explicit `hiDPI` / `refreshRate` filter further. Ties go to the
    /// current mode's HiDPI setting and refresh rate, then the highest refresh.
    public static func pick(
        _ query: ModeQuery,
        from modes: [ModeSnapshot],
        current: ModeSnapshot?
    ) -> ModeSnapshot? {
        var candidates = modes.filter { $0.width == query.width && $0.height == query.height }
        if let hiDPI = query.hiDPI {
            candidates = candidates.filter { $0.hiDPI == hiDPI }
        }
        if let refresh = query.refreshRate {
            candidates = candidates.filter { abs($0.refreshRate - refresh) < 0.5 }
        }
        return candidates.max { a, b in score(a, query, current) < score(b, query, current) }
    }

    private static func score(_ m: ModeSnapshot, _ q: ModeQuery, _ current: ModeSnapshot?) -> Double {
        var s = m.refreshRate / 1000   // highest refresh wins otherwise-equal ties
        if let current {
            if q.hiDPI == nil, m.hiDPI == current.hiDPI { s += 2 }
            if q.refreshRate == nil, abs(m.refreshRate - current.refreshRate) < 0.5 { s += 1 }
        }
        return s
    }
}

// MARK: - Socket location and framing

public enum ControlSocket {
    /// Override with `SIMPLEDISPLAY_SOCKET` (useful for tests or a debug build
    /// running next to a release build).
    public static var path: String {
        if let override = ProcessInfo.processInfo.environment["SIMPLEDISPLAY_SOCKET"], !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/SimpleDisplay/control.sock")
    }

    /// Largest request or response either side will buffer.
    public static let maxMessageBytes = 1 << 20

    /// Builds a `sockaddr_un` for `path`, or nil if the path doesn't fit.
    public static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
