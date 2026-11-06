import CoreAudio
import Foundation

struct DaemonOptions {
    /// agent-browser's daemon detaches to launchd, so the browser it starts has no `claude` ancestor.
    var agentNames: Set<String> = ["claude", "codex", "agent-browser-darwin-arm64", "agent-browser-darwin-x64"]
    var bundlePrefixes: [String] = []
}

/// Everything the daemon tracks for one agent session (or one jailed app bundle).
final class AgentSession {
    let key: String
    let rootPID: pid_t?
    let rootCommand: String
    let label: String
    let directory: URL
    let recorder: ClipRecorder
    let queue: DispatchQueue
    private(set) var tap: SessionTap?
    private var lastError: String?

    init(key: String, rootPID: pid_t?, rootCommand: String, label: String, directory: URL) {
        self.key = key
        self.rootPID = rootPID
        self.rootCommand = rootCommand
        self.label = label
        self.directory = directory
        self.recorder = ClipRecorder(directory: directory)
        self.queue = DispatchQueue(label: "agent-audio-jail.\(key)")
    }

    var isRootAlive: Bool {
        guard let rootPID else { return true }
        return isProcessAlive(rootPID)
    }

    /// Builds the replacement tap before tearing down the old one so the session is never audible in between.
    func ensureTap(members: Set<AudioObjectID>, isMuted: Bool, force: Bool = false) {
        if !force, let tap, tap.processObjectIDs == members, tap.isMuted == isMuted { return }
        let replacement = SessionTap(processObjectIDs: members, isMuted: isMuted, label: key, recorder: recorder, queue: queue)
        do {
            try replacement.start()
        } catch {
            let message = "\(error)"
            if message != lastError { log("\(key): \(message)") }
            lastError = message
            return
        }
        if tap == nil || lastError != nil {
            log("\(key): \(isMuted ? "muted" : "audible") \(members.count) audio client(s) of \(rootCommand)")
        }
        lastError = nil
        let previous = tap
        tap = replacement
        previous?.stop()
    }

    func stopTap() {
        guard let tap else { return }
        tap.stop()
        self.tap = nil
        let recorder = recorder
        queue.sync { recorder.finishClip() }
        log("\(key): released")
    }
}

final class Daemon {
    static let playingNowWindow: TimeInterval = 3

    private let options: DaemonOptions
    private let paths: StatePaths
    private let ownPID = getpid()
    private var sessions: [String: AgentSession] = [:]
    private var sessionKeyByObjectID: [AudioObjectID: String?] = [:]
    private var clientsBySession: [String: [AudioClient]] = [:]
    private var isPaused = false
    private var retainedSources: [DispatchSourceProtocol] = []

    init(options: DaemonOptions, paths: StatePaths) {
        self.options = options
        self.paths = paths
    }

    /// Called on the main queue after every reconcile.
    var onStatusChange: ((StatusFile) -> Void)?

    /// Starts listening and reconciling on the main queue; the caller runs the main run loop.
    func start() {
        guard acquireSingleInstanceLock() else {
            log("another agent-audio-jail daemon is already running")
            exit(0)
        }
        try? FileManager.default.removeItem(at: paths.sessions)
        log("agent-audio-jail \(ownPID) jailing descendants of \(options.agentNames.sorted().joined(separator: ", "))"
            + (options.bundlePrefixes.isEmpty ? "" : " and bundles \(options.bundlePrefixes.joined(separator: ", "))"))

        do {
            try addSystemPropertyListener(kAudioHardwarePropertyProcessObjectList, queue: .main) {
                self.reconcile()
            }
            try addSystemPropertyListener(kAudioHardwarePropertyDefaultOutputDevice, queue: .main) {
                self.rebuildAllTaps()
            }
        } catch {
            log("could not register Core Audio listeners: \(error)")
            exit(1)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { self.reconcile() }
        timer.resume()
        retainedSources.append(timer)

        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { self.shutDown() }
            source.resume()
            retainedSources.append(source)
        }
    }

    func setAudible(_ sessionKey: String, _ isAudible: Bool) {
        changeControl { control in
            control.audibleSessions.removeAll { $0 == sessionKey }
            if isAudible { control.audibleSessions.append(sessionKey) }
        }
    }

    func setPaused(_ isPaused: Bool) {
        changeControl { $0.isPaused = isPaused }
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        changeControl { $0.areNotificationsEnabled = isEnabled }
    }

    func readControl() -> ControlFile {
        readJSON(ControlFile.self, from: paths.control) ?? ControlFile()
    }

    func shutDown() -> Never {
        log("shutting down; releasing all taps")
        for session in sessions.values {
            session.stopTap()
        }
        try? FileManager.default.removeItem(at: paths.status)
        exit(0)
    }

    private func changeControl(_ change: (inout ControlFile) -> Void) {
        do {
            try updateControlFile(paths, change)
        } catch {
            log("could not write control file: \(error)")
        }
        reconcile()
    }

    private func acquireSingleInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let descriptor = open(paths.root.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o600)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    private func reconcile() {
        let control = readJSON(ControlFile.self, from: paths.control) ?? ControlFile()
        if control.isPaused != isPaused {
            log(control.isPaused ? "paused: all agent audio is audible" : "resumed")
            isPaused = control.isPaused
        }

        let clients = (try? listAudioClients()) ?? []
        let liveObjectIDs = Set(clients.map(\.objectID))
        sessionKeyByObjectID = sessionKeyByObjectID.filter { liveObjectIDs.contains($0.key) }

        var grouped: [String: [AudioClient]] = [:]
        for client in clients where client.pid != ownPID {
            guard let key = resolveSessionKey(for: client) else { continue }
            grouped[key, default: []].append(client)
        }
        clientsBySession = grouped

        for (key, members) in grouped {
            let session = sessions[key] ?? makeSession(key: key, sample: members[0])
            sessions[key] = session
            if isPaused {
                session.stopTap()
            } else {
                session.ensureTap(members: Set(members.map(\.objectID)), isMuted: !control.audibleSessions.contains(key))
            }
        }

        var endedSessionKeys: [String] = []
        for (key, session) in sessions where grouped[key] == nil {
            session.stopTap()
            if !session.isRootAlive {
                try? FileManager.default.removeItem(at: session.directory)
                sessions[key] = nil
                endedSessionKeys.append(key)
            }
        }
        if control.audibleSessions.contains(where: endedSessionKeys.contains) {
            try? updateControlFile(paths) { $0.audibleSessions.removeAll(where: endedSessionKeys.contains) }
        }

        onStatusChange?(writeStatus())
    }

    private func rebuildAllTaps() {
        log("default output device changed; rebuilding taps")
        for session in sessions.values {
            guard let tap = session.tap else { continue }
            session.ensureTap(members: tap.processObjectIDs, isMuted: tap.isMuted, force: true)
        }
    }

    private func resolveSessionKey(for client: AudioClient) -> String? {
        if let cached = sessionKeyByObjectID[client.objectID] { return cached }
        var key: String?
        if let prefix = options.bundlePrefixes.first(where: { !client.bundleID.isEmpty && client.bundleID.hasPrefix($0) }) {
            key = "bundle-\(prefix)"
        } else if let rootPID = findAgentRoot(of: client.pid, agentNames: options.agentNames) {
            key = "pid-\(rootPID)"
        }
        sessionKeyByObjectID[client.objectID] = .some(key)
        return key
    }

    private func makeSession(key: String, sample: AudioClient) -> AgentSession {
        if key.hasPrefix("pid-"), let rootPID = pid_t(key.dropFirst(4)) {
            let command = (readExecutableName(of: rootPID) ?? "unknown")
                .replacingOccurrences(of: #"-darwin-(arm64|x64)$"#, with: "", options: .regularExpression)
            let folder = readWorkingDirectory(of: rootPID).map { URL(fileURLWithPath: $0).lastPathComponent } ?? key
            return AgentSession(
                key: key, rootPID: rootPID, rootCommand: command, label: folder, directory: paths.sessionDirectory(key)
            )
        }
        return AgentSession(
            key: key, rootPID: nil, rootCommand: sample.bundleID, label: sample.bundleID, directory: paths.sessionDirectory(key)
        )
    }

    @discardableResult
    private func writeStatus() -> StatusFile {
        let now = Date()
        let sessionStatuses = sessions.values.sorted { $0.key < $1.key }.map { session in
            let summary = session.recorder.summarize()
            let processes = (clientsBySession[session.key] ?? []).map { client in
                StatusFile.Process(
                    pid: client.pid,
                    name: readExecutableName(of: client.pid) ?? "?",
                    bundleID: client.bundleID,
                    isRunningOutput: client.isRunningOutput
                )
            }
            let peak = session.tap == nil ? 0 : summary.lastPeak
            let isPlayingNow = session.tap != nil
                && summary.lastSoundAt.map { now.timeIntervalSince($0) < Self.playingNowWindow } == true
            return StatusFile.Session(
                session: session.key,
                label: session.label,
                rootPID: session.rootPID,
                rootCommand: session.rootCommand,
                isMuted: session.tap?.isMuted ?? false,
                isTapActive: session.tap != nil,
                isPlayingNow: isPlayingNow,
                processes: processes,
                lastSoundAt: summary.lastSoundAt,
                lastPeakDBFS: (20 * log10(Double(max(peak, 1e-6))) * 10).rounded() / 10,
                clipDirectory: session.directory.path,
                clips: summary.clipPaths
            )
        }
        let status = StatusFile(daemonPID: ownPID, updatedAt: now, isPaused: isPaused, sessions: sessionStatuses)
        do {
            try writeJSON(status, to: paths.status)
        } catch {
            log("could not write status: \(error)")
        }
        return status
    }
}
