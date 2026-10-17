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

The Now Playing slot is claimed only while a target app is frontmost, and released as soon
as you switch away, so AirPods play/pause returns to Spotify when you are not coding.

Next/previous track are left unbound, so double- and triple-press still behave normally.

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

## Key mapping

Defaults, overridable via `~/.config/airpods-keybind/keymap.json`:

| App | Key | Basis |
| --- | --- | --- |
| `com.microsoft.VSCode` | `cmd+d` | verified in the extension's own key handler |
| `com.apple.Terminal`, iTerm2, Warp | `space` | the TUI's `voice:pushToTalk` default |
| `com.anthropic.claudefordesktop` | `cmd+d` | **unverified** — see below |

The desktop app's voice key was not confirmed. If a press types a space or does nothing
there, change it:

    mkdir -p ~/.config/airpods-keybind
    cat > ~/.config/airpods-keybind/keymap.json <<'JSON'
    {
      "com.microsoft.VSCode": "cmd+d",
      "com.anthropic.claudefordesktop": "space",
      "com.apple.Terminal": "space"
    }
    JSON

## Known limits

- One app owns Now Playing at a time. While a target app is frontmost, a stem press
  drives dictation rather than music.
- If Spotify does not reclaim the slot after you switch away, play something once and it
  re-registers.
