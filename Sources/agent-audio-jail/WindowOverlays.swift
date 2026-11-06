import AppKit

/// Pins a bar to every on-screen window owned by a process that an agent session started,
/// while that session is playing sound, so a silent page explains itself and can be
/// unmuted (or muted again) in place.
@MainActor
final class AgentWindowOverlays: NSObject {
    private static let lingerSeconds: TimeInterval = 10
    /// Looking for new windows scans every window on screen, so it runs every few frames;
    /// following the windows we already track runs every frame.
    private static let framesPerDiscovery = 15
    private static let minimumWindowSide: CGFloat = 120

    var onSetAudible: ((String, Bool) -> Void)?
    private var sessions: [StatusFile.Session] = []
    private var panels: [CGWindowID: OverlayPanel] = [:]
    private var displayLink: CADisplayLink?
    private var frameCount = 0

    func update(with status: StatusFile) {
        let now = Date()
        sessions = status.sessions.filter { session in
            session.isTapActive && session.lastSoundAt.map { now.timeIntervalSince($0) < Self.lingerSeconds } == true
        }
        discoverWindows()
        if sessions.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil, let screen = NSScreen.main {
            let displayLink = screen.displayLink(target: self, selector: #selector(step))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        frameCount += 1
        if frameCount % Self.framesPerDiscovery == 0 {
            discoverWindows()
        } else {
            followWindows()
        }
    }

    private func discoverWindows() {
        let targets = findTargetWindows()
        for (windowID, panel) in panels where targets[windowID] == nil {
            panel.orderOut(nil)
            panels[windowID] = nil
        }
        for (windowID, target) in targets {
            let panel = panels[windowID] ?? OverlayPanel { [weak self] sessionKey, isAudible in
                self?.onSetAudible?(sessionKey, isAudible)
            }
            panels[windowID] = panel
            panel.render(session: target.session)
            panel.place(over: target.bounds)
            panel.order(.above, relativeTo: Int(windowID))
        }
    }

    private func followWindows() {
        guard !panels.isEmpty else { return }
        for (windowID, bounds) in readWindowBounds(Array(panels.keys)) {
            guard let panel = panels[windowID] else { continue }
            panel.place(over: bounds)
            // Clicking the target window raises it over the bar; put the bar back on the next frame.
            if !readWindowIDsAbove(windowID).contains(CGWindowID(panel.windowNumber)) {
                panel.order(.above, relativeTo: Int(windowID))
            }
        }
    }

    private func findTargetWindows() -> [CGWindowID: (session: StatusFile.Session, bounds: CGRect)] {
        guard !sessions.isEmpty else { return [:] }
        var sessionByOwnerPID: [pid_t: StatusFile.Session] = [:]
        for session in sessions {
            for pid in collectWindowOwnerCandidates(of: session) {
                sessionByOwnerPID[pid] = session
            }
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }

        var targets: [CGWindowID: (session: StatusFile.Session, bounds: CGRect)] = [:]
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let session = sessionByOwnerPID[ownerPID],
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = readBounds(of: window),
                  bounds.width >= Self.minimumWindowSide, bounds.height >= Self.minimumWindowSide
            else { continue }
            targets[windowID] = (session, bounds)
        }
        return targets
    }
}

/// Reads the live bounds of specific windows, which is much cheaper than listing every window.
private func readWindowBounds(_ windowIDs: [CGWindowID]) -> [CGWindowID: CGRect] {
    var pointers: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
          let windows = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    else { return [:] }
    var boundsByWindowID: [CGWindowID: CGRect] = [:]
    for window in windows {
        guard let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = readBounds(of: window)
        else { continue }
        boundsByWindowID[windowID] = bounds
    }
    return boundsByWindowID
}

/// Only the windows stacked above the target, which is a short list while the target is in front.
private func readWindowIDsAbove(_ windowID: CGWindowID) -> Set<CGWindowID> {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, windowID) as? [[String: Any]] else {
        return []
    }
    return Set(windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
}

private func readBounds(of window: [String: Any]) -> CGRect? {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary)
}

/// The audio usually comes from a windowless helper (Chrome's audio service), so the
/// windows belong to one of its ancestors below the agent itself.
private func collectWindowOwnerCandidates(of session: StatusFile.Session) -> Set<pid_t> {
    var candidates: Set<pid_t> = []
    for process in session.processes {
        var current = process.pid
        for _ in 0..<64 {
            guard current > 1, current != session.rootPID, candidates.insert(current).inserted else { break }
            guard let parent = readParentPID(of: current) else { break }
            current = parent
        }
    }
    return candidates
}

@MainActor
final class OverlayPanel: NSPanel {
    private static let bottomInset: CGFloat = 20
    private static let cornerRadius: CGFloat = 12

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let onSetAudible: (String, Bool) -> Void
    private var sessionKey = ""
    private var isSessionMuted = true

    init(onSetAudible: @escaping (String, Bool) -> Void) {
        self.onSetAudible = onSetAudible
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = makeRoundedMask(radius: Self.cornerRadius)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = #selector(toggleAudible)
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    /// `windowBounds` is in Quartz window coordinates (origin at the top-left of the primary display).
    func place(over windowBounds: CGRect) {
        let size = frame.size
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(
            x: (windowBounds.midX - size.width / 2).rounded(),
            y: (primaryScreenHeight - windowBounds.maxY + Self.bottomInset).rounded()
        )
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    func render(session: StatusFile.Session) {
        sessionKey = session.session
        let agent = describeAgent(of: session)
        let isMuted = session.isMuted
        let text = isMuted
            ? "Audio muted by Agent Audio Jail: started by \(agent)"
            : "Agent audio unmuted: started by \(agent)"
        guard text != label.stringValue || isMuted != isSessionMuted else { return }
        isSessionMuted = isMuted
        label.stringValue = text
        button.title = isMuted ? "Unmute" : "Mute"
        icon.image = NSImage(
            systemSymbolName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: isMuted ? "muted" : "unmuted"
        )
        icon.contentTintColor = isMuted ? .systemRed : .secondaryLabelColor
        setContentSize(contentView?.fittingSize ?? .zero)
        invalidateShadow()
    }

    @objc private func toggleAudible() {
        onSetAudible(sessionKey, isSessionMuted)
    }
}

/// A stretchable rounded-rectangle mask; the window shadow follows it, so there is no square outline.
private func makeRoundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
