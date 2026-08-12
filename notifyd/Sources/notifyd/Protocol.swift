import Foundation

/// Wire format shared with the Rust CLI (`src/proto.rs`).
/// Newline-delimited JSON, one request per connection.
enum Proto {
    static let version = 1
}

struct Request: Decodable {
    var v: Int = 1
    var op: String = "speak"
    var id: String = ""
    var text: String = ""
    var engine: String = "holler"
    var voice: String = "oliver"
    var rate: Float = 1.5
    var priority: String = "normal"
    var interrupt: Bool = false
    var stale_after_ms: Int = 30_000
    var ack: String = "queued"
}

struct Response: Encodable {
    var v: Int = Proto.version
    var id: String
    var status: String
    var reason: String?
    var queue_depth: Int?
    var engine: String?
    var ready: Bool?

    static func queued(_ id: String, depth: Int, engine: String) -> Response {
        Response(id: id, status: "queued", queue_depth: depth, engine: engine, ready: true)
    }
    static func notReady(_ id: String, _ reason: String) -> Response {
        Response(id: id, status: "not_ready", reason: reason, ready: false)
    }
    static func dropped(_ id: String, _ reason: String) -> Response {
        Response(id: id, status: "dropped", reason: reason)
    }
    static func error(_ id: String, _ reason: String) -> Response {
        Response(id: id, status: "error", reason: reason)
    }

    func line() -> Data {
        let enc = JSONEncoder()
        var d = (try? enc.encode(self)) ?? Data("{\"status\":\"error\"}".utf8)
        d.append(0x0A)
        return d
    }
}

enum Priority: String {
    case low, normal, high
    init(_ s: String) { self = Priority(rawValue: s) ?? .normal }
}

enum EngineKind: String, CaseIterable {
    case holler, dots
    init?(_ s: String) { self.init(rawValue: s) }
}
