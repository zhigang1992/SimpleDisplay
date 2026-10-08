import Darwin
import Foundation
import os
import SimpleDisplayCore

private let logger = Logger(subsystem: "app.simpledisplay", category: "ControlServer")

/// Listens on a Unix domain socket for `ControlRequest`s from `simpledisplayctl`.
///
/// The socket lives in the user's Application Support folder with mode 0600,
/// so only processes running as the same user can connect. Each connection
/// carries exactly one request and one response.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @MainActor (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "app.simpledisplay.control.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(path: String = ControlSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard var addr = ControlSocket.address(for: path) else {
            throw ControlServerError.pathTooLong(path)
        }
        // A socket file left by a crashed instance would make bind() fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.posix("socket", errno) }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ControlServerError.posix("bind", err)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw ControlServerError.posix("listen", err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        logger.info("Control socket listening at \(self.path, privacy: .public)")
    }

    func stop() {
        guard let source = acceptSource else { return }
        acceptSource = nil
        source.cancel()
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: drained
            // Accepted sockets inherit O_NONBLOCK from the listener on Darwin;
            // the per-client reader wants blocking reads with a timeout.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        let response: ControlResponse
        switch readRequest(client) {
        case .success(let request):
            // Hand off to the main actor and wait; display operations can take
            // a few seconds while the topology settles.
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            let handler = self.handler
            Task { @MainActor in
                box.value = await handler(request)
                semaphore.signal()
            }
            semaphore.wait()
            response = box.value ?? .failure("internal error: no response")
        case .failure(let error):
            response = .failure(error.message)
        }
        if let data = try? ControlSocket.encode(response) {
            writeAll(client, data)
        }
        close(client)
    }

    private struct RequestError: Error { let message: String }

    private func readRequest(_ client: Int32) -> Result<ControlRequest, RequestError> {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < ControlSocket.maxMessageBytes {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                buffer = buffer[..<newline]
                break
            }
        }
        guard !buffer.isEmpty else { return .failure(RequestError(message: "empty request")) }
        do {
            return .success(try ControlSocket.decode(ControlRequest.self, from: buffer))
        } catch {
            return .failure(RequestError(message: "unrecognized request; the CLI and app versions may not match"))
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { return }
                ptr += n
                remaining -= n
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: ControlResponse?
}

enum ControlServerError: LocalizedError {
    case pathTooLong(String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Control socket path is too long: \(path)"
        case .posix(let call, let code):
            return "\(call)() failed: \(String(cString: strerror(code)))"
        }
    }
}
