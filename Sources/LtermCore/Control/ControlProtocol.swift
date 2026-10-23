import Foundation

/// One request sent over the control socket, as a single JSON line.
public struct ControlRequest: Equatable, Sendable, Codable {
    public var cmd: String
    public var args: [String: JSONValue]
    /// The pane the CLI runs in ($LTERM_PANE_ID), if any.
    public var caller: Int?

    public init(cmd: String, args: [String: JSONValue] = [:], caller: Int? = nil) {
        self.cmd = cmd
        self.args = args
        self.caller = caller
    }
}

/// The reply: `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`.
public struct ControlResponse: Equatable, Sendable, Codable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?

    public init(ok: Bool, result: JSONValue? = nil, error: String? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: JSONValue = .null) -> ControlResponse {
        ControlResponse(ok: true, result: result)
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// Newline-delimited JSON encoding used on the socket.
public enum ControlCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var line = data
        while let last = line.last, last == 0x0A || last == 0x0D { line.removeLast() }
        return try JSONDecoder().decode(type, from: line)
    }
}
