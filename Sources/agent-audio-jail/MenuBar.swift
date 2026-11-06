import AppKit
import UserNotifications

@MainActor
func runMenuBarApp(daemon: Daemon) -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = MenuBarController(daemon: daemon)
    daemon.onStatusChange = { status in
        MainActor.assumeIsolated { controller.update(with: status) }
    }
    daemon.start()
    withExtendedLifetime(controller) { application.run() }
    exit(0)
}

/// "Google Chrome for Testing Helper (Renderer)" and "Google Chrome for Testing Helper" both read as the browser.
func describeProcesses(of session: StatusFile.Session) -> String {
    var names: [String] = []
    for process in session.processes {
        let name = process.name.replacingOccurrences(of: #" Helper( \(.*\))?$"#, with: "", options: .regularExpression)
        if !names.contains(name) { names.append(name) }
    }
    return names.prefix(3).joined(separator: ", ")
}

func describeAgent(of session: StatusFile.Session) -> String {
    session.rootPID == nil ? session.label : "\(session.rootCommand) in \(session.label)"
}

/// The menu bar icon is the user's view of the jail: it shows when agent audio is being
/// muted right now and lets them unmute one session, pause everything, or quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let daemon: Daemon
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let notifier: BlockedAudioNotifier?
    private let overlays = AgentWindowOverlays()
    private var latestStatus: StatusFile?
    private var renderedIconState = ""

    init(daemon: Daemon) {
        self.daemon = daemon
        self.notifier = Bundle.main.bundleIdentifier == nil ? nil : BlockedAudioNotifier()
        super.init()
        notifier?.onUnmute = { [weak self] sessionKey in self?.daemon.setAudible(sessionKey, true) }
        notifier?.onOpen = { [weak self] in self?.statusItem.button?.performClick(nil) }
        overlays.onSetAudible = { [weak self] sessionKey, isAudible in self?.daemon.setAudible(sessionKey, isAudible) }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        renderIcon()
    }

    func update(with status: StatusFile) {
        latestStatus = status
        overlays.update(with: status)
        renderIcon()
        notifier?.observe(status, isEnabled: daemon.readControl().areNotificationsEnabled)
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        let sessions = latestStatus?.sessions ?? []
        let mutingNow = sessions.filter { $0.isMuted && $0.isPlayingNow }
        let symbol: String
        let toolTip: String
        if latestStatus?.isPaused == true {
            symbol = "speaker.wave.2"
            toolTip = "Agent Audio Jail is paused: agent audio plays normally"
        } else if mutingNow.isEmpty {
            symbol = "speaker.slash"
            toolTip = "Agent Audio Jail: no agent audio is playing"
        } else {
            symbol = "speaker.slash.fill"
            toolTip = "Muting audio from " + mutingNow.map(describeAgent).joined(separator: ", ") + ". Click to unmute."
        }
        let title = mutingNow.isEmpty ? "" : " \(mutingNow.count)"
        let iconState = symbol + title + toolTip
        guard iconState != renderedIconState else { return }
        renderedIconState = iconState

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Audio Jail")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = title
        button.toolTip = toolTip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let control = daemon.readControl()
        let sessions = (latestStatus?.sessions ?? []).sorted {
            ($0.isPlayingNow ? 0 : 1, $0.label) < ($1.isPlayingNow ? 0 : 1, $1.label)
        }

        let headline: String
        if control.isPaused {
            headline = "Paused: agent audio plays normally"
        } else if sessions.isEmpty {
            headline = "No agent has played audio yet"
        } else {
            headline = "Muting audio started by coding agents"
        }
        menu.addItem(makeLabel(headline))

        for session in sessions {
            menu.addItem(.separator())
            addItems(for: session, isAudible: control.audibleSessions.contains(session.session), to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(makeAction(
            control.isPaused ? "Resume Muting Agent Audio" : "Pause: Let All Agent Audio Through",
            #selector(togglePaused)
        ))
        let notifyItem = makeAction("Notify When Agent Audio Is Muted", #selector(toggleNotifications))
        notifyItem.state = control.areNotificationsEnabled ? .on : .off
        menu.addItem(notifyItem)
        menu.addItem(.separator())
        menu.addItem(makeAction("Quit Agent Audio Jail", #selector(quit)))
    }

    private func addItems(for session: StatusFile.Session, isAudible: Bool, to menu: NSMenu) {
        let state: String
        if isAudible {
            state = session.isPlayingNow ? "unmuted, playing now" : "unmuted"
        } else if session.isPlayingNow {
            state = "muted, playing now"
        } else {
            state = session.isTapActive ? "muted, quiet" : "no audio right now"
        }
        let header = makeLabel("\(describeAgent(of: session)): \(state)")
        header.image = NSImage(
            systemSymbolName: isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill",
            accessibilityDescription: isAudible ? "unmuted" : "muted"
        )
        menu.addItem(header)

        let processes = describeProcesses(of: session)
        if !processes.isEmpty {
            let detail = makeLabel("Audio from \(processes)")
            detail.indentationLevel = 1
            menu.addItem(detail)
        }

        let toggle = makeAction(isAudible ? "Mute Again" : "Unmute This Agent", #selector(toggleSession(_:)))
        toggle.representedObject = session.session
        toggle.indentationLevel = 1
        menu.addItem(toggle)

        if !session.clips.isEmpty {
            let clips = makeAction("Show \(session.clips.count) Muted Clip(s) in Finder", #selector(showClips(_:)))
            clips.representedObject = session.clipDirectory
            clips.indentationLevel = 1
            menu.addItem(clips)
        }
    }

    private func makeLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeAction(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleSession(_ sender: NSMenuItem) {
        guard let sessionKey = sender.representedObject as? String else { return }
        daemon.setAudible(sessionKey, !daemon.readControl().audibleSessions.contains(sessionKey))
    }

    @objc private func showClips(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
    }

    @objc private func togglePaused() {
        daemon.setPaused(!daemon.readControl().isPaused)
    }

    @objc private func toggleNotifications() {
        daemon.setNotificationsEnabled(!daemon.readControl().areNotificationsEnabled)
    }

    @objc private func quit() {
        daemon.shutDown()
    }
}

/// Posts one notification per agent session, the first time its audio is muted, with an
/// Unmute button. Later audio from the same session only shows in the menu bar icon.
final class BlockedAudioNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let categoryIdentifier = "muted-agent-audio"
    private static let unmuteActionIdentifier = "unmute"

    var onUnmute: ((String) -> Void)?
    var onOpen: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var notifiedSessionKeys: Set<String> = []

    override init() {
        super.init()
        center.delegate = self
        let unmute = UNNotificationAction(identifier: Self.unmuteActionIdentifier, title: "Unmute", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [unmute], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert]) { isGranted, error in
            if !isGranted { log("notifications not allowed: \(error.map { "\($0)" } ?? "denied in System Settings")") }
        }
    }

    func observe(_ status: StatusFile, isEnabled: Bool) {
        let liveKeys = Set(status.sessions.map(\.session))
        notifiedSessionKeys.formIntersection(liveKeys)
        for session in status.sessions where session.isMuted && session.isPlayingNow {
            guard notifiedSessionKeys.insert(session.session).inserted, isEnabled else { continue }
            post(about: session)
        }
    }

    private func post(about session: StatusFile.Session) {
        let content = UNMutableNotificationContent()
        content.title = "Muted audio from \(describeAgent(of: session))"
        let processes = describeProcesses(of: session)
        content.body = "\(processes.isEmpty ? "A process" : processes) started by the agent is playing sound. "
            + "Unmute to hear it, or use the menu bar icon later."
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["session": session.session]
        center.add(UNNotificationRequest(identifier: session.session, content: content, trigger: nil)) { error in
            if let error { log("could not post notification: \(error)") }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionKey = response.notification.request.content.userInfo["session"] as? String
        let actionIdentifier = response.actionIdentifier
        DispatchQueue.main.async {
            if actionIdentifier == Self.unmuteActionIdentifier, let sessionKey {
                self.onUnmute?(sessionKey)
            } else if actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onOpen?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
