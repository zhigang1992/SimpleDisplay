import AppKit
import os
import SimpleDisplayCore

private let logger = Logger(subsystem: "app.simpledisplay", category: "URLScheme")

/// Owns the shared `DisplayManagerViewModel` so both the SwiftUI menu-bar
/// scene and the `simpledisplay://` URL handler reach the same instance.
///
/// `NSApplicationDelegateAdaptor` wires this up; without it the scene's own
/// `@State` model is unreachable from `application(_:open:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = DisplayManagerViewModel()
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = self.viewModel
        let server = ControlServer { request in await viewModel.handle(request) }
        do {
            try server.start()
            controlServer = server
        } catch {
            logger.error("Control socket unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch URLCommandParser.parse(url) {
            case .success(let command):
                logger.info("URL command: \(String(describing: command))")
                viewModel.execute(urlCommand: command)
            case .failure(let error):
                logger.warning("Ignoring malformed simpledisplay URL \(url.absoluteString, privacy: .public): \(error.description, privacy: .public)")
                viewModel.errorMessage = "Ignored URL: \(error.description)"
            }
        }
    }
}
