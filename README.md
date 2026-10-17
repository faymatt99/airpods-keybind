# airpods-keybind

AirPods stem presses become keystrokes in whatever macOS app has focus.

Single, double and triple press each map to a key, a sequence of keys with pauses, or a
passthrough to your media player, configurable per in-focus app.

The obvious use is hands-free dictation: give any push-to-talk or voice tool a shortcut,
bind a gesture to it, and talk without reaching for the keyboard. But the gestures are
just keystrokes, so they can drive anything the focused app responds to.

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

## Configuration

`keymap.json` in this directory, written with defaults on first run. Kept next to the
source so it is findable from the project rather than buried in `~/.config`.

Resolution order: `$AIRPODS_KEYBIND_CONFIG`, then this repo (detected by `build.sh`
sitting one level above the app bundle), then `~/.config/airpods-keybind/keymap.json` for
when the app has been copied away from its repo.

Keys are bundle identifiers. Find one with:

    osascript -e 'id of app "Visual Studio Code"'

macOS does the multi-press detection, so each gesture arrives as its own command — no
timing logic here.

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
the two. That is how one gesture can both start something and, on the next press, run a
different and longer sequence:

    "single": "cmd+d",
    "singleAlternate": "cmd+d, 600ms, return"

For a dictation tool bound to `cmd+d`: press once to start, press again to stop, wait for
the transcription to land, and submit. The sequence carries that knowledge — dispatch has
no notion of dictation.

Two consequences of tracking alternation:

- A pause is a guess at how long the app needs. Too short and the follow-up key lands
  early (for dictation: a truncated prompt). Raise it if you see that.
- Pressing the key by hand desyncs the alternation. It resets when you leave the app, and
  goes stale after 120s.

Binding the follow-up plainly on another gesture (`"double": "return"`) covers both cases.

### Examples

**One gesture, start and finish** — press to start, press again to stop, wait, and submit.
Double press is a plain submit in case alternation desyncs; triple still skips tracks.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "singleAlternate": "cmd+d, 600ms, return",
      "double": "return",
      "triple": "passthrough"
    }

**No hidden state** — nothing to desync, at the cost of finishing on a different gesture
than you started with.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "double": "cmd+d, 600ms, return",
      "triple": "passthrough"
    }

**Music first** — the action moved off the single press, so play/pause and track-skip
behave exactly as they always did.

    "com.microsoft.VSCode": {
      "single": "passthrough",
      "double": "passthrough",
      "triple": "cmd+d, 600ms, return"
    }

**A terminal** — whatever key your tool uses there; `space` is the Claude Code TUI's.

    "com.apple.Terminal": {
      "single": "space",
      "double": "passthrough",
      "triple": "passthrough"
    }

**Nothing to do with voice** — bind whatever the focused app understands. Here: interrupt
on double, and swallow triple so a stray press does nothing.

    "com.microsoft.VSCode": {
      "single": "cmd+d",
      "double": "escape",
      "triple": "ignore"
    }

**Longer chains** — sequences take any number of steps.

    "double": "cmd+d, 900ms, return, 200ms, shift+tab"

## Using it with a dictation tool

Two things decide whether a given tool works well.

**It needs a toggle, not a hold.** A stem press is instantaneous and cannot express
press-and-hold, so a tool whose shortcut is hold-to-talk will not work — the press
registers as an immediate down-up. Look for a tap/toggle mode, or separate start and stop
shortcuts, and bind those.

**Pin the microphone.** Any tool that opens the AirPods mic flips them into the HFP
profile, which kills the gestures mid-session. See below.

Beyond that it is just a shortcut: set one in the tool's preferences (Wispr Flow,
Superwhisper, macOS Dictation and similar all expose one), then bind a gesture to it.

### Claude Code

Voice settings live in `~/.claude/settings.json`, shared by the TUI and the VS Code
extension:

    {
      "voice": {
        "enabled": true,
        "mode": "tap"
      }
    }

`mode` must be `"tap"` — the default `"hold"` is hold-to-talk, which a press cannot
express. `voice.autoSubmit` does not help either: it is documented as hold-mode only.
Tap mode stops recording without submitting, which is what an alternating action or a
sequence is for.

The key differs by surface: `cmd+d` in the VS Code extension, verified from its own key
handler, and `space` in the TUI (`voice:pushToTalk`). The Claude desktop app's key is
**unverified** — flip it in the config if a press misbehaves there.

The *submit* key differs too. The VS Code extension has a
`claudeCode.useCtrlEnterToSend` setting: off (the default) Enter sends, on it is
Cmd+Enter and Enter makes a newline. Match whichever you use, or the follow-up key in a
sequence inserts a line break instead of sending.

The desktop app has no such setting. Its Code tab does carry the keybindings system, so
`~/.claude/keybindings.json` is read there (and by terminal sessions, though not by the VS
Code extension, which has its own). Note that reassigning a key does **not** override its
default — user bindings are additive, so `"enter": "chat:newline"` leaves Enter still
submitting. Unbinding with `"enter": null` works, but then Enter does nothing and newline
falls back to `ctrl+j`. Verified on the version in *Tested with*.

Simplest is to leave the desktop app on Enter-to-send and bind `return` for it, which is
what the defaults here do.

### Pinning the microphone

    "inputDevice": "MacBook Pro Microphone"

Starting dictation opens the mic, which flips the AirPods from A2DP into the HFP headset
profile. In HFP a stem press is telephony control (mute), not a transport command — macOS
reports *"cannot control mic with AirPods Pro"* and nothing reaches this app, so a second
press cannot stop anything. Keeping the mic on the built-in device avoids the profile
switch entirely, and keeps output audio out of 24 kHz while recording.

macOS stores no lasting default-input preference — it re-evaluates whenever the device
topology changes, and Bluetooth wins, so reconnecting AirPods takes the mic back. This
watches CoreAudio for those changes and puts the default input back.

Scoped to "a configured app is focused", so calls in other apps are not re-pinned. Note it
does **not** restore the previous device on release or quit. Omit the key to disable.

## Tested with

- macOS 26.7 (build 25G229), MacBook Pro M4 Max (`Mac16,6`)
- AirPods Pro, Bluetooth product ID `0x2024`, firmware `9A348`

Everything here rests on undocumented behaviour — which layer a stem press reaches, how
MediaRemote routes it, and how Bluetooth profile switching affects it. Apple can change
any of that in a point release. If presses stop arriving, re-run the reasoning in *Why it
works this way* before assuming the config is wrong.

## Known limits

- **Left and right cannot be distinguished.** Both stems emit the same AVRCP command, and
  `MPRemoteCommandEvent` carries only the command and a timestamp. The information is not
  in the message, so no hook recovers it.
- Passthrough only reaches scriptable players. Browser audio (YouTube, web players) has no
  AppleScript surface and will not respond.
- One app owns Now Playing at a time. Gestures bound to keys are not available to music
  while a configured app is focused — hence `passthrough` for the ones you want to keep.
