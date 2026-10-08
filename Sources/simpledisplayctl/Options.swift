import Foundation

/// Tiny argument reader — just enough for `--flag`, `--key value`,
/// `--key=value`, and bare positional arguments. Deliberately no third-party
/// crate: the CLI needs to be a single-file drop-in for shell pipelines.
struct Options {
    private let flags: Set<String>
    private let values: [String: String]
    /// Arguments that are neither options nor option values, in order.
    let positionals: [String]

    /// `booleanFlags` never consume the following argument, so
    /// `mode 3 --hidpi 1920x1080` keeps `1920x1080` positional.
    init(_ args: [String], booleanFlags: Set<String> = []) {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else {
                positionals.append(arg)
                i += 1
                continue
            }
            if booleanFlags.contains(arg) {
                flags.insert(arg)
            } else if let eq = arg.firstIndex(of: "=") {
                let key = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                values[key] = value
            } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                values[arg] = args[i + 1]
                i += 1
            } else {
                flags.insert(arg)
            }
            i += 1
        }
        self.flags = flags
        self.values = values
        self.positionals = positionals
    }

    func flag(_ name: String) -> Bool {
        flags.contains(name) || values[name]?.lowercased() == "true"
    }

    func string(_ name: String) -> String? {
        values[name]
    }

    func int(_ name: String) -> Int? {
        values[name].flatMap(Int.init)
    }

    func uint32(_ name: String) -> UInt32? {
        values[name].flatMap(UInt32.init)
    }

    func double(_ name: String) -> Double? {
        values[name].flatMap(Double.init)
    }
}
