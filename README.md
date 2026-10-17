# airpods-keybind

Single AirPods stem press toggles Claude Code voice dictation.

## Why it works this way

An AirPods press is not an input event on macOS. Two probes established this:

- A session `CGEventTap` at head position sees keyboard media keys (`NX_SYSDEFINED`,
  subtype 8) but never sees a stem press.
- An `IOHIDManager` listener on the `Headset` consumer-control device (usage page 12,
  usage 1) likewise sees keyboard media keys and never a stem press.

The press arrives instead as a MediaRemote command, delivered to whichever app owns the
system's single Now Playing slot. So this app does not intercept anything — it registers
as a Now Playing client (`MPRemoteCommandCenter`, backed by a silent looping audio file)
and receives the command directly.

## Behaviour

Owning the Now Playing slot makes this a router rather than a consumer: every gesture
arrives here first, and each one is dispatched per the config for the app that currently
has focus — to a keystroke, passed through to the real media player, or dropped.

The slot is claimed only while a configured app is frontmost and released as soon as you
switch away, and re-asserted on a heartbeat so another media app cannot quietly take it.

## Build and run

    ./build.sh
    open build/AirPodsKeybind.app      # or run the binary directly to see logs

First launch prompts for Accessibility (needed to post keystrokes). The bundle is ad-hoc
signed so that grant survives rebuilds.

To see what it is doing:

    ./build/AirPodsKeybind.app/Contents/MacOS/AirPodsKeybind

## Requires

`voice.mode: "tap"` in `~/.claude/settings.json` — a single press is instantaneous and
cannot express hold-to-talk. Already set.

## Configuration

`~/.config/airpods-keybind/keymap.json`, written with defaults on first run.

Each focused app maps gestures to actions. macOS does the multi-press detection, so each
gesture arrives as its own command — no timing logic here.

| Gesture | Arrives as |
| --- | --- |
| `single` | `togglePlayPause` |
| `double` | `nextTrack` |
| `triple` | `previousTrack` |

An action is one of:

- **a key spec** — `"cmd+d"`, `"space"`, `"shift+tab"`; posted to the focused app
- **`"passthrough"`** — forwarded to your media player via AppleScript, so music keeps
  working while the slot is held
- **`"ignore"`** — swallowed

Apps not listed are left alone entirely: the Now Playing slot is released when they are
focused, so your media keys behave normally.

    {
      "com.microsoft.VSCode": {
        "single": "cmd+d",
        "double": "passthrough",
        "triple": "passthrough"
      }
    }

Passthrough auto-detects Spotify, then Music. Pin it per app with
`"passthroughApp": "Spotify"`.

### Pinning the microphone

    "inputDevice": "MacBook Pro Microphone"

Starting dictation opens the mic, which flips the AirPods from A2DP into the HFP headset
profile. In HFP a stem press is telephony control (mute), not a transport command — macOS
reports *"cannot control mic with AirPods Pro"* and nothing reaches this app, so a second
press cannot stop dictation. Keeping the mic on the built-in device avoids the profile
switch entirely, and keeps output audio out of 24 kHz while recording.

macOS stores no lasting default-input preference — it re-evaluates whenever the device
topology changes, and Bluetooth wins, so reconnecting AirPods takes the mic back. This
watches CoreAudio for those changes and puts the default input back.

Scoped to "a configured app is focused", so calls in other apps are not re-pinned. Note it
does **not** restore the previous device on release or quit. Omit the key to disable.

VS Code's `cmd+d` is verified from the extension's own key handler; `space` is the TUI's
`voice:pushToTalk` default. The Claude desktop app's voice key is **unverified** — flip it
in the config if a press misbehaves there.

## Known limits

- **Left and right cannot be distinguished.** Both stems emit the same AVRCP command, and
  `MPRemoteCommandEvent` carries only the command and a timestamp. The information is not
  in the message, so no hook recovers it.
- Passthrough only reaches scriptable players. Browser audio (YouTube, web players) has no
  AppleScript surface and will not respond.
- One app owns Now Playing at a time. Gestures bound to keys are not available to music
  while a configured app is focused — hence `passthrough` for the ones you want to keep.
