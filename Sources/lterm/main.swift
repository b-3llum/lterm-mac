import Foundation
import Darwin
import LtermCore

// The `lterm` command line tool. It parses argv (LtermCore.CommandParser), sends one JSON
// request to the app over the control socket and prints the reply.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("lterm: \(message)\n".utf8))
    exit(code)
}

// $PWD can be stale (a parent may chdir without updating it), so use the real working directory.
let environment = ProcessInfo.processInfo.environment.merging(["PWD": FileManager.default.currentDirectoryPath]) { _, cwd in cwd }
let parsed: ParsedCommand
do {
    parsed = try CommandParser.parse(Array(CommandLine.arguments.dropFirst()), environment: environment)
} catch let error as ParseError {
    fail(error.message, code: 2)
} catch {
    fail("\(error)", code: 2)
}

switch parsed {
case .noop:
    exit(0)
case .help(let text):
    print(text)
    exit(0)
case .version:
    print("lterm \(Lterm.version)")
    exit(0)
case .image(let path, let width):
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let name = Data((path as NSString).lastPathComponent.utf8).base64EncodedString()
    let size = width.map { ";width=\($0)" } ?? ""
    // OSC 1337 File=...: the iTerm2 inline image protocol, which SwiftTerm draws.
    let sequence = "\u{1B}]1337;File=name=\(name);size=\(data.count);inline=1\(size):\(data.base64EncodedString())\u{07}\n"
    FileHandle.standardOutput.write(Data(sequence.utf8))
    exit(0)
case .install(let directory, let force):
    Installer.install(into: directory, force: force)
    exit(0)
case .integration(let action, let target):
    do {
        try Integrations.run(action, target: target, lterm: Installer.executablePath)
    } catch {
        fail("\(error)")
    }
    exit(0)
case .request(var request, let style):
    if request.args.removeValue(forKey: "fromHook") != nil {
        // Agent hooks pass a JSON description of what they are asking on stdin.
        if isatty(STDIN_FILENO) == 0, let message = ClaudeHooks.message(fromHookInput: FileHandle.standardInput.readDataToEndOfFile()) {
            request.args["message"] = .string(message)
        }
    }
    let response = Client.send(request)
    guard response.ok else { fail(response.error ?? "unknown error") }
    Output.print(response.result ?? .null, style: style)
    if style == .state, response.result?["timedOut"]?.bool == true { exit(1) }
    exit(0)
}

// MARK: - Socket client

enum Client {
    /// Commands that may start the app when it is not running.
    static let launchesApp: Set<String> = ["app.open", "pane.split", "md.open", "browse.open", "attach"]

    static func send(_ request: ControlRequest) -> ControlResponse {
        let path = Lterm.socketPath(environment: environment)
        if let fd = connect(to: path) {
            return exchange(fd, request)
        }
        if request.cmd == "pane.state" {
            // Agent hooks must never fail just because lterm is closed.
            exit(0)
        }
        guard launchesApp.contains(request.cmd) else { fail("lterm is not running (no socket at \(path))") }
        // A fresh launch opens its own first window; pass a command to it instead of opening a second one.
        let command = request.cmd == "app.open" ? request.args["command"]?.string : nil
        launchApp(command: command)
        guard let fd = waitForSocket(path, seconds: 10) else { fail("started lterm-mac but its socket did not appear") }
        if request.cmd == "app.open" {
            close(fd)
            return .success()
        }
        return exchange(fd, request)
    }

    static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            fail("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// How long to wait for a reply. Waits get their own timeout plus a margin, or no limit.
    static func replyTimeout(for request: ControlRequest) -> Double? {
        if request.cmd == "pane.wait" || request.cmd == "browse.wait" {
            return request.args["timeout"]?.double.map { $0 + 10 }
        }
        return 30
    }

    static func exchange(_ fd: Int32, _ request: ControlRequest) -> ControlResponse {
        defer { close(fd) }
        if let seconds = replyTimeout(for: request) {
            var timeout = timeval(tv_sec: Int(min(seconds, 31_536_000)), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        do {
            let data = try ControlCodec.encode(request)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(.EPIPE)
                    }
                    offset += written
                }
            }
            var reply = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { fail("lterm did not answer in time") }
                if count <= 0 { break }
                reply.append(buffer, count: count)
                if buffer[count - 1] == 0x0A { break }
            }
            guard !reply.isEmpty else { fail("lterm closed the connection without a reply") }
            return try ControlCodec.decode(ControlResponse.self, from: reply)
        } catch {
            fail("could not talk to lterm: \(error)")
        }
    }

    static func waitForSocket(_ path: String, seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let fd = connect(to: path) { return fd }
            usleep(100_000)
        }
        return nil
    }

    /// Starts the app: the bundle this tool lives in if there is one, otherwise by bundle id.
    static func launchApp(command: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments: [String]
        if let bundle = Installer.appBundlePath {
            arguments = [bundle]
        } else {
            arguments = ["-b", Lterm.bundleID]
        }
        if let command { arguments += ["--args", "-e", command] }
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("could not start lterm-mac: \(error)")
        }
        if process.terminationStatus != 0 {
            fail("could not start lterm-mac. Is it installed? (open exited with \(process.terminationStatus))")
        }
    }
}

// MARK: - Output

enum Output {
    static func print(_ result: JSONValue, style: OutputStyle) {
        switch style {
        case .none:
            break
        case .paneID:
            if let id = result["id"]?.int { Swift.print(id) }
        case .text:
            let text = result["text"]?.string ?? result.string ?? ""
            FileHandle.standardOutput.write(Data((text.hasSuffix("\n") || text.isEmpty ? text : text + "\n").utf8))
        case .state:
            Swift.print(result["state"]?.string ?? "")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) { Swift.print(text) }
        case .paneList:
            printTable(result.array ?? [])
        }
    }

    static func printTable(_ panes: [JSONValue]) {
        let headers = ["ID", "WIN", "TAB", "SIZE", "FOCUS", "KIND", "STATE", "AGENT", "TITLE"]
        let rows: [[String]] = panes.map { pane in
            let size = pane["cols"]?.int.map { "\($0)x\(pane["rows"]?.int ?? 0)" } ?? "-"
            return [
                pane["id"]?.int.map(String.init) ?? "?",
                pane["window"]?.int.map(String.init) ?? "-",
                pane["tab"]?.int.map(String.init) ?? "-",
                size,
                pane["focused"]?.bool == true ? "*" : "",
                pane["kind"]?.string ?? "",
                pane["state"]?.string ?? "",
                pane["agent"]?.string ?? "",
                pane["title"]?.string ?? "",
            ]
        }
        let widths = headers.indices.map { column in
            ([headers] + rows).map { $0[column].count }.max() ?? 0
        }
        for row in [headers] + rows {
            let line = row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            Swift.print(line)
        }
    }
}

// MARK: - Install

enum Installer {
    /// This tool's real path, with symlinks resolved.
    static var executablePath: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        _NSGetExecutablePath(&buffer, &size)
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).resolvingSymlinksInPath
    }

    /// The lterm-mac.app that contains this tool, if it lives inside one.
    static var appBundlePath: String? {
        let marker = ".app/Contents/Resources/bin/"
        guard let range = executablePath.range(of: marker) else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    static func install(into directory: String?, force: Bool) {
        let folder = ((directory ?? "~/.local/bin") as NSString).expandingTildeInPath
        let link = (folder as NSString).appendingPathComponent("lterm")
        let fm = FileManager.default
        let existingLink = try? fm.destinationOfSymbolicLink(atPath: link)
        let exists = existingLink != nil || fm.fileExists(atPath: link)
        // Only replace our own link. Anything else (like the original lterm) needs --force.
        if exists && !force && !(existingLink?.contains("lterm-mac.app/") ?? false) {
            fail("\(link) already exists and is not an lterm-mac link (maybe the original lterm). " +
                 "Use 'lterm install --dir DIR' for another folder, or --force to replace it.")
        }
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if exists { try fm.removeItem(atPath: link) }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: executablePath)
        } catch {
            fail("could not link \(link): \(error)")
        }
        print("linked \(link) -> \(executablePath)")
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(folder) {
            print("\(folder) is not on your PATH. Add this to ~/.zshrc:")
            print("  export PATH=\"\(folder):$PATH\"")
        }
    }
}
