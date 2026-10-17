// AirPods stem press -> Claude Code voice dictation.
//
// The press is not an input event: it reaches neither a CGEventTap nor the HID layer.
// macOS delivers it as a MediaRemote command to whichever app owns the Now Playing
// slot, so this app registers as a Now Playing client to receive it, then posts the
// voice keystroke to the focused app.
//
// The slot is claimed only while a target app is frontmost, so media keys return to
// Spotify as soon as you switch away.

import Cocoa
import AVFoundation
import MediaPlayer

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Key specs

struct KeySpec {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let label: String
}

let keyCodes: [String: CGKeyCode] = [
    "d": 2, "space": 49, "v": 9, "t": 17, "k": 40, "return": 36, "escape": 53,
]

func parseKeySpec(_ spec: String) -> KeySpec? {
    var flags: CGEventFlags = []
    var key: String?
    for part in spec.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command", "meta": flags.insert(.maskCommand)
        case "ctrl", "control":        flags.insert(.maskControl)
        case "alt", "opt", "option":   flags.insert(.maskAlternate)
        case "shift":                  flags.insert(.maskShift)
        default:                       key = part
        }
    }
    guard let k = key, let code = keyCodes[k] else { return nil }
    return KeySpec(keyCode: code, flags: flags, label: spec)
}

// MARK: - Config

// bundle id -> key that toggles dictation in that app.
// VS Code: verified from the extension bundle's own handler (metaKey && "d").
// Terminals: the TUI's voice:pushToTalk action, default space.
// Claude desktop: best guess, see README — flip it in the config file if wrong.
let defaultKeymap: [String: String] = [
    "com.microsoft.VSCode":            "cmd+d",
    "com.anthropic.claudefordesktop":  "cmd+d",
    "com.apple.Terminal":              "space",
    "com.googlecode.iterm2":           "space",
    "dev.warp.Warp-Stable":            "space",
]

let configPath = ("~/.config/airpods-keybind/keymap.json" as NSString).expandingTildeInPath

func loadKeymap() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: configPath),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return defaultKeymap
    }
    print("loaded keymap override from \(configPath)")
    return parsed
}

// MARK: - App

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

final class VoiceBridge: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer?
    private var keymap: [String: String] = [:]
    private var holdingSlot = false
    private var lastFire = Date.distantPast
    private var fireCount = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        keymap = loadKeymap()

        if !AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        ) {
            print("""
            Accessibility permission is required to post keystrokes.
            A prompt should have appeared — grant it in
              System Settings > Privacy & Security > Accessibility
            Setup continues; presses will start working once granted.
            """)
        }

        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            print("silence.wav missing from the app bundle"); exit(1)
        }
        p.numberOfLoops = -1
        p.volume = 0.0
        player = p

        bindRemoteCommands()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(frontmostChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        syncSlot()
        startHeartbeat()
        print("""
        airpods-keybind running. Targets:
        \(keymap.map { "  \($0.key) -> \($0.value)" }.sorted().joined(separator: "\n"))

        The Now Playing slot is claimed only while one of these is frontmost.
        """)
    }

    private func bindRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        for cmd in [cc.togglePlayPauseCommand, cc.playCommand, cc.pauseCommand] {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                self?.fire()
                return .success
            }
        }
        // Leave next/prev alone so double/triple press stays available.
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    @objc private func frontmostChanged() { syncSlot() }

    private func targetKey() -> KeySpec? {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let spec = keymap[bundleId] else { return nil }
        return parseKeySpec(spec)
    }

    private func startHeartbeat() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reassertSlot()
        }
    }

    /// Another app can steal Now Playing without the frontmost app changing, so while a
    /// target is focused keep restating ownership.
    private func reassertSlot() {
        guard holdingSlot, targetKey() != nil else { return }
        if player?.isPlaying == false { player?.play() }
        let info = MPNowPlayingInfoCenter.default()
        if info.playbackState != .playing { info.playbackState = .playing }
        info.nowPlayingInfo = nowPlayingPayload()
    }

    private func nowPlayingPayload() -> [String: Any] {
        [
            MPMediaItemPropertyTitle: "Claude Code dictation",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: 86400.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
        ]
    }

    private func syncSlot() {
        let shouldHold = targetKey() != nil
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

    private func fire() {
        // play + togglePlayPause can both arrive for one press.
        guard Date().timeIntervalSince(lastFire) > 0.3 else { return }
        lastFire = Date()

        guard let spec = targetKey() else {
            print("[\(stamp())] press ignored (frontmost app is not a target)")
            return
        }

        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: spec.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: spec.keyCode, keyDown: false) else {
            print("[\(stamp())] failed to build key event"); return
        }
        down.flags = spec.flags
        up.flags = spec.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        fireCount += 1
        print("[\(stamp())] press -> \(spec.label)  (#\(fireCount))")
    }
}

let app = NSApplication.shared
let bridge = VoiceBridge()
app.delegate = bridge
app.setActivationPolicy(.accessory)
app.run()
