// AirPods stem presses -> configurable actions, per focused app.
//
// The press is not an input event: it reaches neither a CGEventTap nor the HID layer.
// macOS delivers it as a MediaRemote command to whichever app owns the Now Playing
// slot, so this app registers as a Now Playing client to receive it.
//
// Owning that slot makes this a router: each gesture is dispatched to a keystroke, or
// passed through to the real media player, or dropped — whatever the config says for
// the app that currently has focus.

import Cocoa
import AVFoundation
import MediaPlayer

setvbuf(stdout, nil, _IONBF, 0)

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - Gestures

/// macOS does the multi-press detection; each gesture arrives as its own command.
enum Gesture: String, CaseIterable {
    case single, double, triple

    var appleScriptVerb: String {
        switch self {
        case .single: return "playpause"
        case .double: return "next track"
        case .triple: return "previous track"
        }
    }
}

// MARK: - Actions

struct KeySpec {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let label: String
}

enum Action {
    case key(KeySpec)
    case passthrough
    case ignore

    var label: String {
        switch self {
        case .key(let k):   return k.label
        case .passthrough:  return "passthrough"
        case .ignore:       return "ignore"
        }
    }
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
    "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
    "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "space": 49, "return": 36, "enter": 36, "escape": 53, "esc": 53, "tab": 48,
    "delete": 51, "up": 126, "down": 125, "left": 123, "right": 124,
]

func parseAction(_ raw: String) -> Action? {
    switch raw.lowercased() {
    case "passthrough": return .passthrough
    case "ignore", "none", "": return .ignore
    default: break
    }
    var flags: CGEventFlags = []
    var key: String?
    for part in raw.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command", "meta": flags.insert(.maskCommand)
        case "ctrl", "control":        flags.insert(.maskControl)
        case "alt", "opt", "option":   flags.insert(.maskAlternate)
        case "shift":                  flags.insert(.maskShift)
        default:                       key = part
        }
    }
    guard let k = key, let code = keyCodes[k] else { return nil }
    return .key(KeySpec(keyCode: code, flags: flags, label: raw))
}

// MARK: - Config

struct AppBinding {
    var actions: [Gesture: Action]
    /// Optional bundle name for passthrough ("Spotify", "Music"); nil = auto-detect.
    var passthroughApp: String?
}

let defaultConfigJSON = """
{
  "_comment": "Each app maps gestures to an action: a key spec (\\"cmd+d\\"), \\"passthrough\\" to forward to your media player, or \\"ignore\\". Apps not listed here are left alone entirely - the Now Playing slot is released when they are focused, so your media keys behave normally.",
  "com.microsoft.VSCode": {
    "single": "cmd+d",
    "double": "passthrough",
    "triple": "passthrough"
  },
  "com.anthropic.claudefordesktop": {
    "single": "cmd+d",
    "double": "passthrough",
    "triple": "passthrough"
  },
  "com.apple.Terminal": {
    "single": "space",
    "double": "passthrough",
    "triple": "passthrough"
  },
  "com.googlecode.iterm2": {
    "single": "space",
    "double": "passthrough",
    "triple": "passthrough"
  }
}
"""

let configDir = ("~/.config/airpods-keybind" as NSString).expandingTildeInPath
let configPath = configDir + "/keymap.json"

func loadConfig() -> [String: AppBinding] {
    if !FileManager.default.fileExists(atPath: configPath) {
        try? FileManager.default.createDirectory(atPath: configDir,
                                                 withIntermediateDirectories: true)
        try? defaultConfigJSON.write(toFile: configPath, atomically: true, encoding: .utf8)
        print("wrote default config to \(configPath)")
    }

    guard let data = FileManager.default.contents(atPath: configPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("could not parse \(configPath) — no apps bound"); return [:]
    }

    var result: [String: AppBinding] = [:]
    for (bundleId, value) in root {
        if bundleId.hasPrefix("_") { continue }
        guard let spec = value as? [String: String] else {
            print("skipping \(bundleId): expected an object of gesture -> action"); continue
        }
        var actions: [Gesture: Action] = [:]
        for gesture in Gesture.allCases {
            guard let raw = spec[gesture.rawValue] else { continue }
            guard let action = parseAction(raw) else {
                print("skipping \(bundleId).\(gesture.rawValue): unrecognised action \"\(raw)\"")
                continue
            }
            actions[gesture] = action
        }
        guard !actions.isEmpty else { continue }
        result[bundleId] = AppBinding(actions: actions, passthroughApp: spec["passthroughApp"])
    }
    return result
}

// MARK: - Bridge

final class Bridge: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer?
    private var config: [String: AppBinding] = [:]
    private var holdingSlot = false
    private var lastFire: [Gesture: Date] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        config = loadConfig()

        if !AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        ) {
            print("""
            Accessibility permission is required to post keystrokes.
            Grant it in System Settings > Privacy & Security > Accessibility.
            Setup continues; keystrokes start working once granted.
            """)
        }

        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            print("silence.wav missing from the app bundle"); exit(1)
        }
        p.numberOfLoops = -1
        p.volume = 0.0
        player = p

        bindCommands()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        syncSlot()
        startHeartbeat()

        print("airpods-keybind running. Config: \(configPath)")
        for (bundleId, binding) in config.sorted(by: { $0.key < $1.key }) {
            let summary = Gesture.allCases.compactMap { g in
                binding.actions[g].map { "\(g.rawValue)=\($0.label)" }
            }.joined(separator: "  ")
            print("  \(bundleId)\n      \(summary)")
        }
        print("\nUnlisted apps are untouched — the slot is released when they are focused.")
    }

    private func bindCommands() {
        let cc = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, Gesture)] = [
            (cc.togglePlayPauseCommand, .single),
            (cc.playCommand,            .single),
            (cc.pauseCommand,           .single),
            (cc.nextTrackCommand,       .double),
            (cc.previousTrackCommand,   .triple),
        ]
        for (cmd, gesture) in pairs {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                self?.dispatch(gesture)
                return .success
            }
        }
    }

    // MARK: Slot ownership

    @objc private func frontmostChanged() { syncSlot() }

    private func binding() -> AppBinding? {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return config[id]
    }

    private func nowPlayingPayload() -> [String: Any] {
        [
            MPMediaItemPropertyTitle: "airpods-keybind",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: 86400.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
        ]
    }

    private func syncSlot() {
        let shouldHold = binding() != nil
        guard shouldHold != holdingSlot else { return }
        holdingSlot = shouldHold

        let info = MPNowPlayingInfoCenter.default()
        if shouldHold {
            player?.play()
            info.nowPlayingInfo = nowPlayingPayload()
            info.playbackState = .playing
            print("[\(stamp())] claimed slot (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        } else {
            player?.pause()
            info.playbackState = .stopped
            info.nowPlayingInfo = nil
            print("[\(stamp())] released slot")
        }
    }

    private func startHeartbeat() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.holdingSlot, self.binding() != nil else { return }
            if self.player?.isPlaying == false { self.player?.play() }
            let info = MPNowPlayingInfoCenter.default()
            if info.playbackState != .playing { info.playbackState = .playing }
            info.nowPlayingInfo = self.nowPlayingPayload()
        }
    }

    // MARK: Dispatch

    private func dispatch(_ gesture: Gesture) {
        // play + togglePlayPause can both arrive for one press.
        if let last = lastFire[gesture], Date().timeIntervalSince(last) < 0.3 { return }
        lastFire[gesture] = Date()

        guard let binding = binding() else {
            print("[\(stamp())] \(gesture.rawValue): focused app is not configured")
            return
        }
        guard let action = binding.actions[gesture] else {
            print("[\(stamp())] \(gesture.rawValue): no action bound")
            return
        }

        switch action {
        case .ignore:
            print("[\(stamp())] \(gesture.rawValue) -> ignored")
        case .key(let spec):
            post(spec)
            print("[\(stamp())] \(gesture.rawValue) -> \(spec.label)")
        case .passthrough:
            let target = forwardToPlayer(gesture, preferred: binding.passthroughApp)
            print("[\(stamp())] \(gesture.rawValue) -> passthrough (\(target))")
        }
    }

    private func post(_ spec: KeySpec) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: spec.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: spec.keyCode, keyDown: false) else {
            print("[\(stamp())] failed to build key event"); return
        }
        down.flags = spec.flags
        up.flags = spec.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Forward the gesture to a scriptable player. Returns the app it went to.
    @discardableResult
    private func forwardToPlayer(_ gesture: Gesture, preferred: String?) -> String {
        let candidates: [String]
        if let preferred { candidates = [preferred] }
        else {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            var found: [String] = []
            if running.contains("com.spotify.client") { found.append("Spotify") }
            if running.contains("com.apple.Music")    { found.append("Music") }
            candidates = found
        }
        guard let app = candidates.first else { return "no player running" }

        let script = "tell application \"\(app)\" to \(gesture.appleScriptVerb)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        return app
    }
}

let app = NSApplication.shared
let bridge = Bridge()
app.delegate = bridge
app.setActivationPolicy(.accessory)
app.run()
