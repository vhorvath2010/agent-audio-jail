import Foundation

/// Written by the CLI, read by the daemon on every reconcile.
struct ControlFile: Codable {
    var isPaused = false
    var audibleSessions: [String] = []
}

/// Written by the daemon every second, read by the CLI and by agents.
struct StatusFile: Codable {
    struct Session: Codable {
        let session: String
        let rootPID: Int32?
        let rootCommand: String
        let isMuted: Bool
        let isTapActive: Bool
        let processes: [Process]
        let lastSoundAt: Date?
        let lastPeakDBFS: Double
        let clipDirectory: String
        let clips: [String]
    }

    struct Process: Codable {
        let pid: Int32
        let name: String
        let bundleID: String
        let isRunningOutput: Bool
    }

    let daemonPID: Int32
    let updatedAt: Date
    let isPaused: Bool
    let sessions: [Session]
}

struct StatePaths {
    let root: URL

    var control: URL { root.appendingPathComponent("control.json") }
    var status: URL { root.appendingPathComponent("status.json") }
    var sessions: URL { root.appendingPathComponent("sessions") }

    func sessionDirectory(_ session: String) -> URL {
        sessions.appendingPathComponent(session)
    }

    static func resolve() -> StatePaths {
        if let override = ProcessInfo.processInfo.environment["AGENT_AUDIO_JAIL_HOME"], !override.isEmpty {
            return StatePaths(root: URL(fileURLWithPath: override))
        }
        return StatePaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-audio-jail"))
    }
}

func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func makeJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? makeJSONDecoder().decode(type, from: data)
}

func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeJSONEncoder().encode(value).write(to: url, options: .atomic)
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
