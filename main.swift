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
import CoreAudio

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

/// One step of an action sequence: a keystroke, or a pause before the next step.
enum Step {
    case key(KeySpec)
    case delay(TimeInterval)

    var label: String {
        switch self {
        case .key(let k):     return k.label
        case .delay(let t):   return "\(Int(t * 1000))ms"
        }
    }
}

enum Action {
    case sequence([Step])
    case passthrough
    case ignore

    var label: String {
        switch self {
        case .sequence(let steps): return steps.map(\.label).joined(separator: " -> ")
        case .passthrough:         return "passthrough"
        case .ignore:              return "ignore"
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

func parseKey(_ spec: String) -> KeySpec? {
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

/// "cmd+d" | "cmd+d, 600ms, return" | "passthrough" | "ignore".
/// A bare number or Nms/Ns step is a pause before the next keystroke.
func parseAction(_ raw: String) -> Action? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    switch trimmed.lowercased() {
    case "passthrough": return .passthrough
    case "ignore", "none", "": return .ignore
    default: break
    }

    var steps: [Step] = []
    for piece in trimmed.split(separator: ",") {
        let token = piece.trimmingCharacters(in: .whitespaces)
        if token.isEmpty { continue }
        if let delay = parseDelay(token) { steps.append(.delay(delay)); continue }
        guard let key = parseKey(token) else { return nil }
        steps.append(.key(key))
    }
    return steps.isEmpty ? nil : .sequence(steps)
}

private func parseDelay(_ token: String) -> TimeInterval? {
    let lower = token.lowercased()
    if lower.hasSuffix("ms"), let v = Double(lower.dropLast(2)) { return v / 1000 }
    if lower.hasSuffix("s"), let v = Double(lower.dropLast(1)) { return v }
    if let v = Double(lower) { return v / 1000 }   // bare number = milliseconds
    return nil
}

// MARK: - Config

struct AppBinding {
    var actions: [Gesture: Action]
    /// Optional bundle name for passthrough ("Spotify", "Music"); nil = auto-detect.
    var passthroughApp: String?
    /// Optional second action per gesture. Successive presses alternate between the
    /// primary and this one, which is how one gesture can both start a toggle and, on the
    /// next press, run a longer sequence (stop, wait, submit).
    var alternates: [Gesture: Action] = [:]
}

let defaultConfigJSON = """
{
  "_comment": "An action is a key spec, a comma-separated sequence with pauses (\\"cmd+d, 600ms, return\\"), \\"passthrough\\" to forward to your media player, or \\"ignore\\". <gesture>Alternate gives a gesture a second action that successive presses alternate to. Keys are bundle ids; apps not listed are left alone. See the README.",
  "inputDevice": "MacBook Pro Microphone",
  "com.anthropic.claudefordesktop": {
    "single": "cmd+d",
    "singleAlternate": "cmd+d, 1s, return",
    "double": "return",
    "triple": "passthrough"
  },
  "com.microsoft.VSCode": {
    "single": "cmd+d",
    "singleAlternate": "cmd+d, 1s, cmd+return",
    "double": "cmd+return",
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

/// Config lives next to the source, so it is findable from the project rather than buried
/// in ~/.config. Falls back to ~/.config when the app has been copied away from its repo.
let configPath: String = {
    if let override = ProcessInfo.processInfo.environment["AIRPODS_KEYBIND_CONFIG"] {
        return override
    }
    // .../<repo>/build/AirPodsKeybind.app -> <repo>
    let repoRoot = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let marker = repoRoot.appendingPathComponent("build.sh").path
    if FileManager.default.fileExists(atPath: marker) {
        return repoRoot.appendingPathComponent("keymap.json").path
    }
    return ("~/.config/airpods-keybind/keymap.json" as NSString).expandingTildeInPath
}()
let configDir = (configPath as NSString).deletingLastPathComponent

struct Config {
    var apps: [String: AppBinding] = [:]
    /// Device name to pin the default input to while a configured app is focused.
    var inputDevice: String?
}

let reservedKeys: Set<String> = ["inputDevice"]

func loadConfig() -> Config {
    if !FileManager.default.fileExists(atPath: configPath) {
        try? FileManager.default.createDirectory(atPath: configDir,
                                                 withIntermediateDirectories: true)
        try? defaultConfigJSON.write(toFile: configPath, atomically: true, encoding: .utf8)
        print("wrote default config to \(configPath)")
    }

    guard let data = FileManager.default.contents(atPath: configPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("could not parse \(configPath) — no apps bound"); return Config()
    }

    var config = Config()
    config.inputDevice = root["inputDevice"] as? String
    for (bundleId, value) in root {
        if bundleId.hasPrefix("_") || reservedKeys.contains(bundleId) { continue }
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
        var alternates: [Gesture: Action] = [:]
        for gesture in Gesture.allCases {
            guard let raw = spec["\(gesture.rawValue)Alternate"] else { continue }
            guard let action = parseAction(raw) else {
                print("skipping \(bundleId).\(gesture.rawValue)Alternate: unrecognised action \"\(raw)\"")
                continue
            }
            alternates[gesture] = action
        }
        config.apps[bundleId] = AppBinding(
            actions: actions,
            passthroughApp: spec["passthroughApp"],
            alternates: alternates)
    }
    return config
}


// MARK: - Audio devices

/// macOS stores no lasting default-input preference: it re-evaluates whenever the device
/// topology changes, and Bluetooth headsets win. So reconnecting AirPods silently takes
/// the mic back, which flips them into the HFP profile and kills the transport commands
/// this tool depends on. Hence: keep putting the default input back.
enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(of id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cf as String? else { return "" }
        return s
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    /// Watch both the default-input selection and the device list.
    static func watch(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
            ) { _, _ in handler() }
        }
    }
}

// MARK: - Bridge

final class Bridge: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer?
    private var config = Config()
    private var warnedMissingInput = false
    /// For gestures with an alternate action: when the primary last fired, per app+gesture.
    /// Nothing else sends these keys, so alternation tracks the app's toggle state.
    private var primaryFiredAt: [String: Date] = [:]
    /// Treat alternation as reset after this long, limiting drift from a keypress by hand.
    private let alternationStaleAfter: TimeInterval = 120
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

        if let wanted = config.inputDevice {
            print("pinning default input to \"\(wanted)\" while a configured app is focused")
            AudioDevices.watch { [weak self] in self?.enforceInput() }
        }

        syncSlot()
        startHeartbeat()

        print("airpods-keybind running. Config: \(configPath)")
        for (bundleId, binding) in config.apps.sorted(by: { $0.key < $1.key }) {
            let summary = Gesture.allCases.compactMap { g -> String? in
                guard let action = binding.actions[g] else { return nil }
                if let alt = binding.alternates[g] {
                    return "\(g.rawValue)=\(action.label) | then \(alt.label)"
                }
                return "\(g.rawValue)=\(action.label)"
            }.joined(separator: "\n      ")
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

    @objc private func frontmostChanged() {
        syncSlot()
        enforceInput()
    }

    /// Put the default input back to the configured device. Scoped to "a configured app is
    /// focused" so calls in other apps keep using whatever mic you chose there.
    private func enforceInput() {
        guard let wanted = config.inputDevice, binding() != nil else { return }
        let current = AudioDevices.defaultInput()
        guard AudioDevices.name(of: current) != wanted else { return }
        guard let target = AudioDevices.all().first(where: {
            AudioDevices.hasInput($0) && AudioDevices.name(of: $0) == wanted
        }) else {
            if !warnedMissingInput {
                warnedMissingInput = true
                let names = AudioDevices.all().filter(AudioDevices.hasInput).map(AudioDevices.name(of:))
                print("input device \"\(wanted)\" not found. Available: \(names.joined(separator: ", "))")
            }
            return
        }
        let was = AudioDevices.name(of: current)
        if AudioDevices.setDefaultInput(target) {
            print("[\(stamp())] default input -> \(wanted) (was \(was.isEmpty ? "unknown" : was))")
        }
    }

    private func binding() -> AppBinding? {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return config.apps[id]
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
        let transition = shouldHold != holdingSlot
        // Re-assert on every activation of a configured app, not only on the transition
        // into one: switching between two configured apps used to skip the claim entirely,
        // leaving the slot with whoever took it in the meantime until the next heartbeat.
        guard transition || shouldHold else { return }
        holdingSlot = shouldHold

        let info = MPNowPlayingInfoCenter.default()
        if shouldHold {
            player?.play()
            info.nowPlayingInfo = nowPlayingPayload()
            info.playbackState = .playing
            if transition {
                print("[\(stamp())] claimed slot (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
            }
        } else {
            player?.pause()
            info.playbackState = .stopped
            info.nowPlayingInfo = nil
            primaryFiredAt.removeAll()
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
            self.enforceInput()
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

        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        var chosen = action
        var note = ""
        if let alternate = binding.alternates[gesture] {
            let stateKey = "\(bundleId)|\(gesture.rawValue)"
            let primaryActive = primaryFiredAt[stateKey].map {
                Date().timeIntervalSince($0) < alternationStaleAfter
            } ?? false
            if primaryActive {
                primaryFiredAt[stateKey] = nil
                chosen = alternate
                note = " [alternate]"
            } else {
                primaryFiredAt[stateKey] = Date()
                note = " [primary]"
            }
        }

        switch chosen {
        case .ignore:
            print("[\(stamp())] \(gesture.rawValue) -> ignored")
        case .sequence(let steps):
            run(steps)
            print("[\(stamp())] \(gesture.rawValue) -> \(chosen.label)\(note)")
        case .passthrough:
            let target = forwardToPlayer(gesture, preferred: binding.passthroughApp)
            print("[\(stamp())] \(gesture.rawValue) -> passthrough (\(target))")
        }
    }

    /// Post each keystroke, honouring any pauses between them.
    private func run(_ steps: [Step]) {
        var offset: TimeInterval = 0
        for step in steps {
            switch step {
            case .delay(let t):
                offset += t
            case .key(let spec):
                if offset == 0 {
                    post(spec)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                        self?.post(spec)
                    }
                }
            }
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
