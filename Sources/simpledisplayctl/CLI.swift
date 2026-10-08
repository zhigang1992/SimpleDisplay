import Foundation
import SimpleDisplayCore

// simpledisplayctl — drives the running SimpleDisplay menu-bar app. Display
// queries and changes (list, enable, disable, main, mode, ...) go over the
// app's local control socket and get a reply; virtual-display commands still
// build `simpledisplay://` URLs and hand them to `open(1)`. All real work
// lives in the app; this binary exists so shell scripts, SSH, Shortcuts,
// launchd agents, and AI tools can drive it.

@main
struct CLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let head = args.first else {
            printUsage()
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch head {
        case "list", "ls":  runList(rest)
        case "modes":       runModes(rest)
        case "enable":      runSetEnabled(rest, enabled: true)
        case "disable":     runSetEnabled(rest, enabled: false)
        case "toggle":      runToggle(rest)
        case "main":        runMain(rest)
        case "mode":        runMode(rest)
        case "forget":      runForget(rest)
        case "create":      runCreate(rest)
        case "remove":      runRemove(rest)
        case "reconfigure": runReconfigure(rest)
        case "open":        runOpen()
        case "status":      runStatus()
        case "-h", "--help", "help":
            printUsage()
        case "--version":
            print("simpledisplayctl \(CLIVersion.string)")
        default:
            fail("unknown subcommand '\(head)' (try `simpledisplayctl --help`)")
        }
    }
}

// MARK: - Display control (socket)

private func runList(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json"])
    let response = request(.list, json: opts.flag("--json"))
    guard case .displays(let displays) = response else { unexpected(response) }
    if opts.flag("--json") {
        printJSON(displays)
    } else {
        printTable(displays)
    }
}

private func runModes(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json"])
    let display = requireDisplay(opts, usage: "modes <display>")
    let response = request(.modes(display: display), json: opts.flag("--json"))
    guard case .modes(let modes) = response else { unexpected(response) }
    if opts.flag("--json") {
        printJSON(modes)
    } else {
        for mode in modes { print(describe(mode)) }
    }
}

private func runSetEnabled(_ args: [String], enabled: Bool) {
    let opts = Options(args, booleanFlags: ["--json"])
    let verb = enabled ? "enable" : "disable"
    let display = requireDisplay(opts, usage: "\(verb) <display>")
    report(request(.setEnabled(display: display, enabled: enabled), json: opts.flag("--json")), json: opts.flag("--json"))
}

private func runToggle(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json"])
    let display = requireDisplay(opts, usage: "toggle <display>")
    report(request(.toggle(display: display), json: opts.flag("--json")), json: opts.flag("--json"))
}

private func runMain(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json"])
    let display = requireDisplay(opts, usage: "main <display>")
    report(request(.setMain(display: display), json: opts.flag("--json")), json: opts.flag("--json"))
}

private func runMode(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json", "--hidpi", "--no-hidpi"])
    guard opts.positionals.count == 2 else {
        fail("usage: simpledisplayctl mode <display> <width>x<height> [--hidpi | --no-hidpi] [--refresh N]")
    }
    guard let size = ModeQuery.parseSize(opts.positionals[1]) else {
        fail("invalid size '\(opts.positionals[1])' (expected e.g. 1920x1080)")
    }
    var query = ModeQuery(width: size.width, height: size.height)
    switch (opts.flag("--hidpi"), opts.flag("--no-hidpi")) {
    case (true, true):  fail("pass only one of --hidpi / --no-hidpi")
    case (true, false): query.hiDPI = true
    case (false, true): query.hiDPI = false
    case (false, false): break
    }
    if let raw = opts.string("--refresh") {
        guard let refresh = Double(raw), refresh > 0 else { fail("invalid --refresh '\(raw)'") }
        query.refreshRate = refresh
    }
    let json = opts.flag("--json")
    report(request(.setMode(display: opts.positionals[0], mode: query), json: json), json: json)
}

private func runForget(_ args: [String]) {
    let opts = Options(args, booleanFlags: ["--json"])
    let display = requireDisplay(opts, usage: "forget <display>")
    let json = opts.flag("--json")
    let response = request(.forget(display: display), json: json)
    guard case .displays(let displays) = response else { unexpected(response) }
    if json { printJSON(displays) } else { print("forgot \(display)") }
}

/// Sends `req` and exits on any failure: 3 if the app can't be reached,
/// 1 for errors the app reports.
private func request(_ req: ControlRequest, json: Bool) -> ControlResponse {
    switch ControlClient.send(req) {
    case .success(.failure(let message)):
        fail(message, json: json)
    case .success(let response):
        return response
    case .failure(.appUnreachable(let message)):
        fail(message, json: json, code: 3)
    case .failure(.protocolError(let message)):
        fail(message, json: json)
    }
}

private func report(_ response: ControlResponse, json: Bool) {
    guard case .display(let display) = response else { unexpected(response) }
    if json {
        printJSON(display)
    } else {
        printTable([display])
    }
}

private func requireDisplay(_ opts: Options, usage: String) -> String {
    guard opts.positionals.count == 1 else {
        fail("usage: simpledisplayctl \(usage)  (display = id, UUID, name, 'main', or 'builtin')")
    }
    return opts.positionals[0]
}

private func unexpected(_ response: ControlResponse) -> Never {
    fail("unexpected reply from SimpleDisplay: \(response)")
}

// MARK: - Output

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fail("could not encode output")
    }
    print(text)
}

private func printTable(_ displays: [DisplaySnapshot]) {
    let rows: [[String]] = displays.map { d in
        var flags: [String] = []
        if d.main { flags.append("main") }
        if d.builtIn { flags.append("built-in") }
        if d.virtual { flags.append("virtual") }
        if d.remembered { flags.append("remembered") }
        return [
            String(d.id),
            d.name,
            d.enabled ? "on" : "off",
            d.mode.map(describe) ?? "-",
            flags.joined(separator: ","),
        ]
    }
    let header = ["ID", "NAME", "STATE", "MODE", "FLAGS"]
    let all = [header] + rows
    let widths = header.indices.map { col in all.map { $0[col].count }.max() ?? 0 }
    for row in all {
        let line = row.enumerated().map { col, cell in
            col == row.count - 1 ? cell : cell.padding(toLength: widths[col], withPad: " ", startingAt: 0)
        }
        print(line.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

private func describe(_ mode: ModeSnapshot) -> String {
    let refresh = mode.refreshRate == 0
        ? "default"
        : (mode.refreshRate.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(mode.refreshRate))Hz"
            : String(format: "%.2fHz", mode.refreshRate))
    return "\(mode.width)x\(mode.height)\(mode.hiDPI ? " HiDPI" : "") @ \(refresh)"
}

// MARK: - Virtual displays (URL scheme)

private func runCreate(_ args: [String]) {
    let opts = Options(args)
    guard let width = opts.int("--width") else { fail("missing --width") }
    guard let height = opts.int("--height") else { fail("missing --height") }
    var req = VirtualDisplayRequest(width: width, height: height)
    if let name = opts.string("--name") { req.name = name }
    if let refresh = opts.double("--refresh") { req.refreshRate = refresh }
    if opts.flag("--hidpi") { req.hiDPI = true }

    dispatch(.create(req))
}

private func runRemove(_ args: [String]) {
    let opts = Options(args)
    let id = opts.uint32("--id")
    let name = opts.string("--name")
    switch (id, name) {
    case (nil, nil):   fail("remove requires --id <N> or --name <S>")
    case (_?, _?):     fail("remove accepts only one of --id / --name")
    case (let id?, _): dispatch(.remove(.id(id)))
    case (_, let n?):  dispatch(.remove(.name(n)))
    }
}

private func runReconfigure(_ args: [String]) {
    let opts = Options(args)
    guard let id = opts.uint32("--id") else { fail("missing --id") }
    guard let width = opts.int("--width") else { fail("missing --width") }
    guard let height = opts.int("--height") else { fail("missing --height") }
    var req = VirtualDisplayRequest(width: width, height: height)
    if let refresh = opts.double("--refresh") { req.refreshRate = refresh }
    if opts.flag("--hidpi") { req.hiDPI = true }
    if let name = opts.string("--name") { req.name = name }

    dispatch(.reconfigure(id: id, request: req))
}

private func runOpen() {
    dispatch(.open)
}

private func runStatus() {
    let installed = InstallStatus.detect()
    print("installed: \(installed.installed ? "yes" : "no")")
    if let path = installed.path {
        print("path:      \(path)")
    }
    print("running:   \(installed.running ? "yes" : "no")")
    if let pid = installed.pid {
        print("pid:       \(pid)")
    }
    exit(installed.installed ? 0 : 2)
}

// MARK: - Dispatch

private func dispatch(_ command: URLCommand) {
    let url = command.url
    // `open` is the safest bridge — the system-provided one, not on $PATH manipulation,
    // and it launches the app if it's not running yet (URL scheme activation).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
        try process.run()
    } catch {
        fail("failed to invoke /usr/bin/open: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fail("open(1) exited \(process.terminationStatus) — is SimpleDisplay installed?")
    }
}

// MARK: - Usage

private func printUsage() {
    let usage = """
    simpledisplayctl — drive SimpleDisplay from the command line.

    USAGE:
      simpledisplayctl <command> [options]

    DISPLAY COMMANDS (reply with the result; add --json for machine output):
      list                       List displays, including disabled ones.
      modes   <display>          List available modes for a display.
      enable  <display>          Turn a display on.
      disable <display>          Turn a display off (refuses the last active one).
      toggle  <display>          Flip a display on/off.
      main    <display>          Make a display the main display.
      mode    <display> <W>x<H> [--hidpi | --no-hidpi] [--refresh N]
                                 Change resolution.
      forget  <display>          Drop a disabled display from the list.

      <display> is an id, UUID, name (case-insensitive, unique substring ok),
      'main', or 'builtin'.

    VIRTUAL DISPLAY COMMANDS (sent via the simpledisplay:// URL scheme):
      create       --width N --height N [--name S] [--refresh N] [--hidpi]
      remove       --id N | --name S
      reconfigure  --id N --width N --height N [--refresh N] [--hidpi] [--name S]
      open         Focus the SimpleDisplay menu bar app.
      status       Print whether SimpleDisplay is installed / running.
      --version    Print CLI version.
      --help       Show this help.

    EXAMPLES:
      simpledisplayctl list
      simpledisplayctl disable "LG HDR 4K"
      simpledisplayctl enable 3 --json
      simpledisplayctl mode main 1920x1080 --hidpi
      simpledisplayctl create --width 2732 --height 2048 --name "iPad Pro" --hidpi
      simpledisplayctl remove --name "iPad Pro"
      simpledisplayctl reconfigure --id 3 --width 1600 --height 1200

    EXIT CODES:
      0 success, 1 error (message on stderr; with --json also {"error": ...}
      on stdout), 3 SimpleDisplay not reachable.

    NOTES:
      All actions are delegated to the running app. Display commands talk to
      its control socket (~/Library/Application Support/SimpleDisplay/
      control.sock, override with SIMPLEDISPLAY_SOCKET) and launch the app in
      the background if needed. Virtual display commands go through open(1).
    """
    print(usage)
}

private func fail(_ message: String, json: Bool = false, code: Int32 = 1) -> Never {
    if json {
        printJSON(["error": message])
    }
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}
