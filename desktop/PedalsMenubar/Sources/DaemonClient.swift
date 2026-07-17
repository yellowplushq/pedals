import Foundation

/// One remote PTY session, as reported by `ls` (PROTOCOL.md §5, same shape as
/// the ctl `sessions` list in §4).
struct SessionInfo: Identifiable, Equatable, Sendable {
    var id: Int
    var title: String
    var cwd: String?
    var rows: Int?
    var cols: Int?
    var alive: Bool

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        self.id = id
        self.title = json["title"]?.stringValue ?? "Session \(id)"
        self.cwd = json["cwd"]?.stringValue
        self.rows = json["rows"]?.intValue
        self.cols = json["cols"]?.intValue
        self.alive = json["alive"]?.boolValue ?? true
    }
}

enum DaemonClientError: LocalizedError {
    case socketUnavailable
    case ioFailure(String)
    case badResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: "Daemon socket is not available"
        case .ioFailure(let detail): "Socket I/O failed: \(detail)"
        case .badResponse: "Malformed response from daemon"
        case .remote(let message): message
        }
    }
}

/// Thin ndjson client for the daemon's unix control socket
/// (`~/.pedals/pedals.sock`, PROTOCOL.md §5). One connection per request:
/// connect, write a single JSON line, read a single JSON line, close.
struct DaemonClient: Sendable {
    static let socketPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".pedals/pedals.sock")

    private struct Request: Encodable {
        var cmd: String
        var id: Int?
    }

    var isSocketPresent: Bool {
        FileManager.default.fileExists(atPath: Self.socketPath)
    }

    func ls() async throws -> JSONValue { try await send(Request(cmd: "ls")) }
    func status() async throws -> JSONValue { try await send(Request(cmd: "status")) }
    func pair() async throws -> JSONValue { try await send(Request(cmd: "pair")) }
    func new() async throws -> JSONValue { try await send(Request(cmd: "new")) }

    func kill(id: Int) async throws {
        _ = try await send(Request(cmd: "kill", id: id))
    }

    private func send(_ request: Request) async throws -> JSONValue {
        var encoded = try JSONEncoder().encode(request)
        encoded.append(0x0A)
        let line = encoded
        let responseLine: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.roundTrip(line) })
            }
        }
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: responseLine) else {
            throw DaemonClientError.badResponse
        }
        guard response["ok"]?.boolValue == true else {
            throw DaemonClientError.remote(response["err"]?.stringValue ?? "Daemon reported an error")
        }
        return response
    }

    /// Blocking connect / write line / read line. Runs off the main actor.
    private static func roundTrip(_ line: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonClientError.ioFailure(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        let timeoutLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLen)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            throw DaemonClientError.socketUnavailable
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyMemory(from: src)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw DaemonClientError.socketUnavailable
        }

        var remaining = [UInt8](line)
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else {
                throw DaemonClientError.ioFailure(String(cString: strerror(errno)))
            }
            remaining.removeFirst(written)
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                response.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                break // EOF; accept if we already have a complete object
            } else {
                throw DaemonClientError.ioFailure(String(cString: strerror(errno)))
            }
            if response.count > 1 << 20 {
                throw DaemonClientError.badResponse
            }
        }
        guard !response.isEmpty else { throw DaemonClientError.badResponse }
        if let newline = response.firstIndex(of: 0x0A) {
            response = response.prefix(upTo: newline)
        }
        return response
    }
}
