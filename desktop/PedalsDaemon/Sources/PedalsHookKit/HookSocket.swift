import Darwin
import Foundation

/// Fire-and-forget client for the daemon's unix control socket. Everything is
/// best-effort and silent: a hook reporter must never disturb the agent that
/// invoked it, so all failures are swallowed.
public enum HookSocket {
    /// `$PEDALS_HOME/pedals.sock`, else `~/.pedals/pedals.sock`.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let home = environment["PEDALS_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("pedals.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pedals", isDirectory: true)
            .appendingPathComponent("pedals.sock").path
    }

    /// Connects (1 s timeout), writes the line (1 s timeout), best-effort
    /// reads one reply line, closes. Returns whether the write completed.
    @discardableResult
    public static func send(_ line: Data, socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        // Non-blocking connect with a 1 s poll: a wedged daemon (full listen
        // backlog) must not hang the hook past its budget.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return false }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, 1000) == 1 else { return false }
            var socketError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0,
                  socketError == 0
            else { return false }
        }
        _ = fcntl(fd, F_SETFL, flags)

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let written = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard written else { return false }

        // Best-effort read of the one-line reply so the daemon's write does
        // not hit a closed pipe; the content is ignored.
        var chunk = [UInt8](repeating: 0, count: 4096)
        var received = 0
        while received < 1 << 16 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            received += n
            if chunk[0..<n].contains(0x0A) { break }
        }
        return true
    }
}
