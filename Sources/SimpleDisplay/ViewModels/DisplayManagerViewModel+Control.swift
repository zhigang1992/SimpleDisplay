import Foundation
import SimpleDisplayCore

/// Errors from display actions that callers outside the UI (the control
/// socket) need to hear about. The UI mostly prevents these by disabling
/// controls, so the messages are plain English for the CLI.
enum DisplayActionError: LocalizedError {
    case busy
    case lastActiveDisplay(String)
    case displayDisabled(String)
    case notRemembered(String)
    case noMatchingMode(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "SimpleDisplay is busy with another display change; try again"
        case .lastActiveDisplay(let name):
            return "'\(name)' is the only active display and cannot be disabled"
        case .displayDisabled(let name):
            return "'\(name)' is disabled; enable it first"
        case .notRemembered(let name):
            return "'\(name)' is active; only disabled displays can be forgotten"
        case .noMatchingMode(let detail):
            return detail
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Control socket

extension DisplayManagerViewModel {
    /// Entry point for `ControlServer`. Routes each request to the same
    /// methods the menu bar UI uses, so CLI and clicks behave identically.
    func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return try await perform(request)
        } catch let error as DisplaySelectorError {
            return .failure(error.description)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func perform(_ request: ControlRequest) async throws -> ControlResponse {
        if !isBusy { refresh() }

        switch request {
        case .list:
            return .displays(displays.map(\.snapshot))

        case .modes(let query):
            let display = try resolve(query)
            return .modes(display.availableModes.map(\.snapshot))

        case .setEnabled(let query, let enabled):
            let display = try resolve(query)
            try await setDisplayEnabled(display, enabled: enabled)
            return .display(try current(display))

        case .toggle(let query):
            let display = try resolve(query)
            try await setDisplayEnabled(display, enabled: !display.isActive)
            return .display(try current(display))

        case .setMain(let query):
            let display = try resolve(query)
            try await makeMainDisplay(display)
            return .display(try current(display))

        case .setMode(let query, let modeQuery):
            let display = try resolve(query)
            guard display.isActive else { throw DisplayActionError.displayDisabled(display.name) }
            let snapshots = display.availableModes.map(\.snapshot)
            guard let picked = ModeMatcher.pick(modeQuery, from: snapshots, current: display.currentMode.snapshot),
                  let mode = display.availableModes.first(where: { $0.snapshot == picked })
            else {
                throw DisplayActionError.noMatchingMode(
                    "'\(display.name)' has no mode matching \(describe(modeQuery)) " +
                    "(run `simpledisplayctl modes \(display.id)`)"
                )
            }
            try await applyMode(mode, to: display)
            return .display(try current(display))

        case .forget(let query):
            let display = try resolve(query)
            guard !display.isActive else { throw DisplayActionError.notRemembered(display.name) }
            guard !isBusy else { throw DisplayActionError.busy }
            forgetDisabledDisplay(display)
            return .displays(displays.map(\.snapshot))
        }
    }

    private func resolve(_ query: String) throws -> DisplayInfo {
        let snapshot = try DisplaySelector.resolve(query, in: displays.map(\.snapshot)).get()
        guard let display = displays.first(where: { $0.id == snapshot.id && $0.uuid == snapshot.uuid }) else {
            throw DisplaySelectorError.notFound(query)
        }
        return display
    }

    /// The post-action state of `display`. Looked up by UUID first since that
    /// survives the display leaving and rejoining the online list.
    private func current(_ display: DisplayInfo) throws -> DisplaySnapshot {
        let match = display.uuid.flatMap { uuid in displays.first { $0.uuid == uuid } }
            ?? displays.first { $0.id == display.id }
        guard let match else {
            throw DisplayActionError.failed("'\(display.name)' is no longer listed")
        }
        return match.snapshot
    }

    private func describe(_ q: ModeQuery) -> String {
        var s = "\(q.width)x\(q.height)"
        if let hiDPI = q.hiDPI { s += hiDPI ? " HiDPI" : " non-HiDPI" }
        if let refresh = q.refreshRate { s += " @ \(refresh) Hz" }
        return s
    }
}

// MARK: - Snapshots

extension DisplayInfo {
    var snapshot: DisplaySnapshot {
        DisplaySnapshot(
            id: id, uuid: uuid, name: name, enabled: isEnabled, main: isMain,
            builtIn: isBuiltIn, virtual: isVirtual, remembered: isGhost,
            mode: isPlaceholder ? nil : currentMode.snapshot
        )
    }
}

extension DisplayMode {
    var snapshot: ModeSnapshot {
        ModeSnapshot(
            width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            refreshRate: refreshRate, hiDPI: isHiDPI
        )
    }
}
