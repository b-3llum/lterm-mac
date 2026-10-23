import Foundation
import Darwin
import LtermCore

/// Listens on a Unix domain socket. Each connection sends one JSON line and gets one JSON line back.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "lterm.control", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// Biggest request accepted, to stop a bad client from eating memory.
    private let maxRequestBytes = 8 * 1024 * 1024

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptClients() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        queue.async { [self] in serve(client) }
    }

    private func serve(_ fd: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < maxRequestBytes {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(buffer, count: count)
            if buffer[count - 1] == 0x0A { break }
        }
        let request: ControlRequest
        do {
            request = try ControlCodec.decode(ControlRequest.self, from: data)
        } catch {
            reply(fd, .failure("bad request: \(error.localizedDescription)"))
            return
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.queue.async { self.reply(fd, response) }
        }
    }

    private func reply(_ fd: Int32, _ response: ControlResponse) {
        defer { close(fd) }
        guard let data = try? ControlCodec.encode(response) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}
