import Foundation

let usage = """
agent-audio-jail: keep audio from coding agents off your speakers.

Every process started by a coding agent (any descendant of a `claude` or `codex`
process) is muted with a Core Audio process tap, and whatever it plays is saved
as WAV clips that the agent can inspect.

USAGE
  agent-audio-jail run [--agent NAME]... [--bundle PREFIX]...
      Run the daemon (normally started by the LaunchAgent).
      --agent NAME     Treat processes named NAME as agent roots (default: claude, codex,
                       and agent-browser's daemon).
                       Passing --agent replaces the defaults.
      --bundle PREFIX  Also jail audio clients whose bundle ID starts with PREFIX.

  agent-audio-jail status [--json]   Show every jailed session.
  agent-audio-jail mine [--json]     Show the session of the agent running this command,
                                     including the paths of the clips it played.
  agent-audio-jail hear SESSION      Let one session through to the speakers ("pid-1234").
  agent-audio-jail mute SESSION|all  Jail a session again (or every session).
  agent-audio-jail pause             Stop jailing; everything is audible.
  agent-audio-jail resume            Start jailing again.

State lives in ~/.agent-audio-jail (override with AGENT_AUDIO_JAIL_HOME).
"""

let staleStatusSeconds: TimeInterval = 5

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-audio-jail: \(message)\n".utf8))
    exit(1)
}

func parseDaemonOptions(_ arguments: [String]) -> DaemonOptions {
    var options = DaemonOptions()
    var agentNames: Set<String> = []
    var remaining = arguments[...]
    while let flag = remaining.popFirst() {
        guard let value = remaining.popFirst() else { fail("\(flag) needs a value") }
        switch flag {
        case "--agent": agentNames.insert(value)
        case "--bundle": options.bundlePrefixes.append(value)
        default: fail("unknown option \(flag)")
        }
    }
    if !agentNames.isEmpty { options.agentNames = agentNames }
    return options
}

func loadStatus(_ paths: StatePaths) -> StatusFile {
    guard let status = readJSON(StatusFile.self, from: paths.status) else {
        fail("no status at \(paths.status.path); is the daemon running?")
    }
    if Date().timeIntervalSince(status.updatedAt) > staleStatusSeconds {
        FileHandle.standardError.write(Data("agent-audio-jail: warning: status is stale; the daemon may not be running\n".utf8))
    }
    return status
}

func describe(_ session: StatusFile.Session) -> String {
    let state = !session.isTapActive ? "idle" : (session.isMuted ? "muted" : "AUDIBLE")
    let playing = session.isPlayingNow ? ", playing now" : ""
    var lines = ["\(session.session)  [\(state)\(playing)]  \(session.rootCommand) in \(session.label)"]
    for process in session.processes {
        let playing = process.isRunningOutput ? "  (playing)" : ""
        lines.append("    pid \(process.pid)  \(process.name)\(playing)")
    }
    if let lastSoundAt = session.lastSoundAt {
        lines.append("    last sound \(Int(Date().timeIntervalSince(lastSoundAt)))s ago, peak \(session.lastPeakDBFS) dBFS")
    }
    if !session.clips.isEmpty {
        lines.append("    clips: \(session.clips.count) in \(session.clipDirectory)")
    }
    return lines.joined(separator: "\n")
}

func printJSON<Value: Encodable>(_ value: Value) {
    guard let data = try? makeJSONEncoder().encode(value) else { fail("could not encode JSON") }
    print(String(decoding: data, as: UTF8.self))
}

func updateControl(_ paths: StatePaths, _ change: (inout ControlFile) -> Void) {
    do {
        try updateControlFile(paths, change)
    } catch {
        fail("could not write \(paths.control.path): \(error)")
    }
}

func findOwnSessionKey(options: DaemonOptions) -> String? {
    findAgentRoot(of: getpid(), agentNames: options.agentNames).map { "pid-\($0)" }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = StatePaths.resolve()
let wantsJSON = arguments.contains("--json")

/// Opening AgentAudioJail.app from Finder or Spotlight passes no arguments and the parent is launchd;
/// treat that as `run`. A bare `agent-audio-jail` typed in a shell still prints the usage.
let isLaunchedAsApp = arguments.isEmpty && getppid() == 1

switch isLaunchedAsApp ? "run" : arguments.first {
case "run":
    let daemon = Daemon(options: parseDaemonOptions(Array(arguments.dropFirst())), paths: paths)
    MainActor.assumeIsolated { runMenuBarApp(daemon: daemon) }

case "status":
    let status = loadStatus(paths)
    if wantsJSON {
        printJSON(status)
    } else if status.sessions.isEmpty {
        print(status.isPaused ? "paused; nothing is jailed" : "no agent audio clients right now")
    } else {
        if status.isPaused { print("PAUSED: taps are released, everything is audible\n") }
        print(status.sessions.map(describe).joined(separator: "\n\n"))
    }

case "mine":
    guard let key = findOwnSessionKey(options: DaemonOptions()) else {
        fail("this command is not running under a claude or codex process")
    }
    let status = loadStatus(paths)
    guard let session = status.sessions.first(where: { $0.session == key }) else {
        if wantsJSON { print("{\"session\": \"\(key)\", \"clips\": []}") } else { print("\(key): no audio played yet") }
        exit(0)
    }
    if wantsJSON { printJSON(session) } else { print(describe(session)); session.clips.forEach { print("    \($0)") } }

case "hear":
    guard arguments.count == 2 else { fail("usage: agent-audio-jail hear SESSION") }
    let key = arguments[1]
    updateControl(paths) { control in
        if !control.audibleSessions.contains(key) { control.audibleSessions.append(key) }
    }
    print("\(key) is now audible")

case "mute":
    guard arguments.count == 2 else { fail("usage: agent-audio-jail mute SESSION|all") }
    let key = arguments[1]
    updateControl(paths) { control in
        control.audibleSessions = key == "all" ? [] : control.audibleSessions.filter { $0 != key }
    }
    print(key == "all" ? "every session is muted" : "\(key) is muted")

case "pause":
    updateControl(paths) { $0.isPaused = true }
    print("paused; agent audio is audible until `agent-audio-jail resume`")

case "resume":
    updateControl(paths) { $0.isPaused = false }
    print("resumed")

case nil, "help", "-h", "--help":
    print(usage)

case let command?:
    fail("unknown command \(command)\n\n\(usage)")
}
