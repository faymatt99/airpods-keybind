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

Voice mode in `~/.claude/settings.json` — shared by the Claude Code TUI and the VS Code
extension:

    {
      "voice": {
        "enabled": true,
        "mode": "tap"
      }
    }

`mode` must be `"tap"`. The default is `"hold"` (hold-to-talk), and an AirPods press is
instantaneous — it cannot express a hold, so on the default the keystroke does nothing
useful. `"tap"` is tap to start, tap to stop.

`voice.autoSubmit` does **not** help here: it is documented as hold-mode only. Tap mode
stops recording without submitting, which is what `autoSubmitOnStop` below is for.

## Configuration

`keymap.json` in this directory, written with defaults on first run. Kept next to the
source so it is findable from the project rather than buried in `~/.config`.

Resolution order: `$AIRPODS_KEYBIND_CONFIG`, then this repo (detected by `build.sh`
sitting one level above the app bundle), then `~/.config/airpods-keybind/keymap.json` for
when the app has been copied away from its repo.

Each focused app maps gestures to actions. macOS does the multi-press detection, so each
gesture arrives as its own command — no timing logic here.

| Gesture | Arrives as |
| --- | --- |
| `single` | `togglePlayPause` |
| `double` | `nextTrack` |
| `triple` | `previousTrack` |

An action is one of:

- **a key spec** — `"cmd+d"`, `"space"`, `"shift+tab"`; posted to the focused app
- **a sequence** — comma-separated steps with pauses: `"cmd+d, 600ms, return"`. A bare
  number is milliseconds; `600ms` and `0.6s` also work.
- **`"passthrough"`** — forwarded to your media player via AppleScript, so music keeps
  working while the slot is held
- **`"ignore"`** — swallowed

Apps not listed are left alone entirely: the Now Playing slot is released when they are
focused, so your media keys behave normally.

### Alternating actions

`<gesture>Alternate` gives a gesture a second action; successive presses alternate between
the two. That is how one gesture both starts a toggle and, on the next press, runs a
longer sequence:

    "single": "cmd+d",
    "singleAlternate": "cmd+d, 600ms, return"

Press once to start dictation. Press again and it stops, waits for the transcription to
land, and submits. Nothing about dictation is special-cased in the code — it is the
sequence that knows what to do.

Two consequences of tracking alternation:

- The pause is a guess at transcription latency. Too short submits a truncated prompt;
  raise it if you see clipped messages.
- Pressing the key by hand desyncs the alternation. It resets when you leave the app, and
  goes stale after 120s.

Keeping a plain submit on another gesture (`"double": "return"`) covers both cases.

### Examples

**One gesture, stop and submit** — the default. Press to start, press again to stop, wait
for the transcription, and send. Double press is a plain submit in case alternation
desyncs; triple still skips tracks.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "singleAlternate": "cmd+d, 600ms, return",
      "double": "return",
      "triple": "passthrough"
    }

**No hidden state** — nothing to desync, at the cost of stopping on a different gesture
than you started with. Single only ever starts; double stops and submits.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "double": "cmd+d, 600ms, return",
      "triple": "passthrough"
    }

**Music first** — dictation moved off the single press, so play/pause and track-skip behave
exactly as they always did while coding.

    "com.microsoft.VSCode": {
      "single": "passthrough",
      "double": "passthrough",
      "triple": "cmd+d, 600ms, return"
    }

**Terminal / TUI** — the TUI's voice key is `space` rather than `cmd+d`. Submit behaviour
there may differ, so start without the alternate and add it once you have checked.

    "com.apple.Terminal": {
      "single": "space",
      "double": "passthrough",
      "triple": "passthrough"
    }

**Nothing to do with voice** — gestures are just keystrokes, so bind whatever the focused
app understands. Here: interrupt on double, and swallow triple so a stray press does
nothing.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "double": "escape",
      "triple": "ignore"
    }

**Longer chains** — sequences take any number of steps.

    "double": "cmd+d, 900ms, return, 200ms, shift+tab"

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
