import Darwin
import Foundation
import SimpleDisplayCore

/// Sends one `ControlRequest` to the running app over its Unix socket and
/// waits for the reply. Launches the app in the background if nothing is
/// listening yet.
enum ControlClient {
    enum Failure: Error {
        case appUnreachable(String)
        case protocolError(String)
    }

    static func send(_ request: ControlRequest, launchIfNeeded: Bool = true) -> Result<ControlResponse, Failure> {
        let path = ControlSocket.path
        var fd = connect(path)
        if fd < 0, launchIfNeeded {
            launchApp()
            // Give the app a few seconds to finish launching and bind the socket.
            for _ in 0..<50 where fd < 0 {
                usleep(100_000)
                fd = connect(path)
            }
        }
        guard fd >= 0 else {
            return .failure(.appUnreachable(
                "could not reach SimpleDisplay at \(path). Is the app installed and running? " +
                "(versions before the control socket only support create/remove/reconfigure/open)"
            ))
        }
        defer { close(fd) }

        let payload: Data
        do { payload = try ControlSocket.encode(request) } catch {
            return .failure(.protocolError("could not encode request: \(error)"))
        }
        guard writeAll(fd, payload) else {
            return .failure(.protocolError("connection closed while sending request"))
        }
        shutdown(fd, SHUT_WR)

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while buffer.count < ControlSocket.maxMessageBytes {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        if let newline = buffer.firstIndex(of: 0x0A) {
            buffer = buffer[..<newline]
        }
        guard !buffer.isEmpty else {
            return .failure(.protocolError("SimpleDisplay closed the connection without replying"))
        }
        do {
            return .success(try ControlSocket.decode(ControlResponse.self, from: buffer))
        } catch {
            return .failure(.protocolError("unrecognized reply; the CLI and app versions may not match"))
        }
    }

    private static func connect(_ path: String) -> Int32 {
        guard var addr = ControlSocket.address(for: path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Display changes wait for the topology to settle, which can take a
        // few seconds; don't hang forever if the app wedges.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// `open -g -b` launches by bundle id without stealing focus.
    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", "app.simpledisplay"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { return false }
                ptr += n
                remaining -= n
            }
            return true
        }
    }
}
