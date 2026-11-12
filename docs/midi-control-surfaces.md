# Feasibility: MIDI control surfaces

Status: study only, nothing implemented. Written on 2026-11-12 against DMS 2.1.2,
Quickshell 0.3.2, Fedora Asahi (aarch64), PipeWire + WirePlumber.

**Short answer:** feasible, and a minimal version is cheap. No new dependencies:
`aseqdump` and `aseqsend` ship with alsa-utils (1.2.16 here), the session user
already has access to `/dev/snd/seq`, and Quickshell can already talk to an
external process. Mackie Control is best left for later.

## 1. How MIDI reaches the plugin

**Quickshell (verified)**
- Quickshell 0.3.2 has no MIDI module, nor HID, serial or evdev. Checked in the
  installed qmltypes (`/usr/lib64/qt6/qml/Quickshell/`) and in the module list on
  quickshell.org.
- `Quickshell.Io` has `Process`, `SplitParser`, `Socket`/`SocketServer` and
  `IpcHandler`. `Process` has `stdinEnabled` and `write()`, so a helper can talk
  both ways over stdin/stdout.
- Per the docs, `running = false` sends SIGTERM and the process dies with
  Quickshell. What happens when the `Process` object is destroyed (plugin
  reload) is not documented.

**DMS 2.1.2 (verified)**
- `permissions` in `plugin.json` are informational. The only one the code
  checks is `settings_write`, in `PluginSettings.qml`.
- A plugin can declare its own `IpcHandler` (usbManager, quickCapture and
  dankscale do), which enables `dms ipc call dankMixer ...`.

**System (verified)**
- The Asahi kernel has `snd-usb-audio`, `snd-seq`, `snd-seq-midi` and `snd-rawmidi`.
- `/dev/snd/seq` gets a `user:<name>:rw-` ACL from systemd's uaccess rule
  (`SUBSYSTEM=="sound"`); the `audio` group is not needed.
- PipeWire already exposes the Midi-Bridge, so ALSA seq and PipeWire clients coexist.

**Options**

| Option | Fedora packages | Assessment |
|---|---|---|
| `aseqdump -p <port>` (input) in a `Process` with `SplitParser`; feedback via `aseqsend -p <port> "B0 07 7F"` | already installed | Zero dependencies. Negligible latency, near-zero CPU. One process per outgoing message is fine for LEDs, not for motorized faders. |
| Persistent Python helper with `python3-alsa` (pyalsa/alsaseq) | in repos, not installed | One process for in and out, hot-plug via the Announce port 0:1. Suits continuous feedback. |
| mido / python-rtmidi | **not** in Fedora (pip only) | Rejected: dependency outside the repos. |
| `amidi` (rawmidi) | installed | Rejected: exclusive access to the hardware port, conflicts with PipeWire and DAWs. |
| `pw-mididump` / `pw-cat --midi` | installed | Meant for files and streams, awkward to bind to one device. |
| Plugin calling `dms ipc` | — | Wrong direction: IPC goes *to* the plugin. Useful only as an entry point for external tools (see Stream Deck). |

Unverified: whether `aseqdump` flushes stdout on every event when writing to a
pipe. If not, `stdbuf -oL` fixes it.

## 2. Mapping model

- **MIDI-learn rather than a fixed layout.** Controllers differ too much. Click
  a control in the widget, then move the fader. Save `{port, channel, type
  CC/note/pitchbend, number}` → `{strip, function}` with `savePluginData`.
- **Strips, not apps.** Apps come and go. A physical strip points to a slot:
  - pinned: a fixed app key, the same `appKey` the daemon uses (e.g. `out:firefox`);
  - or "slot N of the current list", with a bank offset and two bank ± buttons;
  - plus special strips: default output, device volume.
- **What a split app's fader controls** must be decided: the app volume (the
  stream) or one specific output, since each output has its own volume.
- **Soft takeover / pickup** for non-motorized faders: apply values only once the
  fader has "caught" the current value (within ±2/127), to avoid volume jumps.
- **Relative encoders** come in three encodings (two's complement, signed bit,
  binary offset): one option per mapping. No takeover needed for encoders.
- **Curve.** `audio.volume` is linear: map 0–127 on a cubic curve for the ear.
- **Coalescing.** Apply at most one value per strip every ~20–30 ms, so a moving
  fader does not flood PipeWire.

## 3. Mackie Control / HUI and existing tools

- **MCU** has no official specification. Sources are community references
  (NicoG60/TouchMCU docs, EMATech PythonMcu, tttapa Control-Surface reverse
  engineering). From memory, to verify there: faders = 14-bit pitchbend per
  channel, touch = notes, V-Pots = relative CCs, LED rings = CCs, scribble
  strips = SysEx.
- Mackie gives banks and display names "for free", but it is medium-to-large
  work and only helps real X-Touch/MCU devices. **Out of scope for now.**
  X-Touch Mini, nanoKONTROL2 and MIDImix also work in generic CC/note mode.
- **LED feedback per device:**
  - MIDImix: LEDs respond to note-on on channel 1, velocity > 0 = on, even
    though the buttons send CCs.
  - nanoKONTROL2: needs "LED Mode: External", set with KORG KONTROL Editor
    (Windows/macOS only). Some users report the setting is lost on power-off.
- **Existing tools to reuse:** none fits.
  - `solarnz/pamidicontrol`, `Jafner/pamidi`, `trafex/audio-midi-controller`,
    `miek/midi2pamixer`, `jesusvallejo/Midi2Vol-Linux` and `smhkd` act on pactl
    streams. They don't see Dank Mixer's buses and outputs, so they would change
    the wrong volume or fight with split apps.
  - `jayden-chan/pipewire-orchestrator` (per-app + LEDs) is archived since 2026-03-30.
  - Worth reading, not reusing (`larsks/mutewatcher` for LEDs).
- **Stream Deck.** StreamController (Flathub) supports plugins and commands. The
  simplest path: Dank Mixer exposes an `IpcHandler` (`toggleMute`, `nextBank`,
  `setOutput`, ...) and StreamController calls `dms ipc call`. One process per
  call is fine for buttons, not for faders. Native HID support is out of scope.

## 4. Effort

- **Minimal: small-to-medium.** Absolute faders + mute + MIDI-learn + pinned/slot
  strips, no feedback, using `aseqdump`. About 200–300 lines of QML: a
  `MidiInput` component in the daemon plus the learn UI in the widget.
- **Full: large.** Banks, soft takeover, encoders, LEDs via `aseqsend`, motor
  faders with a persistent helper, Mackie with scribble strips, testing on
  several devices.

## 5. Risks

- **Hot-plug.** `aseqdump -p` fails if the port is missing. Fix with a second
  `aseqdump -p 0:1` (System Announce) that restarts the input when ports change,
  or poll `aseqdump -l` every few seconds. Identify mappings by port **name**,
  not `client:port`, which changes on every plug-in.
- **Permissions.** No issue (uaccess ACL, verified). `/dev/snd` access holds only
  in the active session.
- **Asahi.** A USB class-compliant surface should work with `snd-usb-audio`
  (present). Not verified with real hardware. The MacBook Air M2 has only two
  USB-C ports, so hubs or adapters are needed; a motorized X-Touch needs its own power.
- **Lifecycle.** Unlike the loopbacks, the MIDI helper should live with the
  shell, not in a systemd unit: if it dies nothing breaks. Since `Process`
  destruction is undocumented, set `running = false` in
  `Component.onDestruction` so no `aseqdump` is orphaned on plugin reload.
- **Feedback.** Don't send feedback to the strip being moved (wait ~300 ms after
  its last event), or motor and hand fight each other.

## Recommendation

Build it into the daemon, with `aseqdump` in a `Process`/`SplitParser` and no new
dependencies. Configure strips with MIDI-learn and per-app pins, then add bank
buttons. LED feedback via `aseqsend` comes next. A Python helper with
`python3-alsa` is only worth it for a controller with motor faders.

**First step:** plug in the controller, run `aseqdump -l`, then
`aseqdump -p "<port name>"` while moving faders and pressing buttons. This shows
the real message format (CC or notes, channels) and whether pipe output is
flushed immediately. Write the parser against that.

## Sources

- [quickshell.org/docs/types](https://quickshell.org/docs/types/)
- [Quickshell Process](https://quickshell.org/docs/types/Quickshell.Io/Process/)
- [pipewire-orchestrator](https://github.com/jayden-chan/pipewire-orchestrator)
- [solarnz/pamidicontrol](https://awesome.ecosyste.ms/projects/github.com%2Fsolarnz%2Fpamidicontrol)
- [Jafner/pamidi](https://github.com/Jafner/pamidi)
- [trafex/audio-midi-controller](https://www.github.com/TrafeX/audio-midi-controller)
- [miek/midi2pamixer](https://github.com/miek/midi2pamixer)
- [Midi2Vol-Linux](https://www.github.com/jesusvallejo/Midi2Vol-Linux)
- [smhkd](https://awesome.ecosyste.ms/projects/github.com%2Farkanosis%2Fsmhkd)
- [larsks/mutewatcher](https://github.com/larsks/mutewatcher)
- [TouchMCU](https://github.com/NicoG60/TouchMCU)
- [PythonMcu](https://github.imc.re/EMATech/PythonMcu/blob/main/docs/manual.rst)
- [tttapa MCU reverse engineering](https://tttapa.github.io/Control-Surface/Doxygen/d3/d85/Mackie-Control-Universal-Reverse-Engineering_8ino-example.html)
- [MIDImix LEDs (Cycling74)](https://cycling74.com/forums/controlling-akai-midi-mix-leds)
- [nanoKONTROL2 LEDs (Launchpad bug)](https://code.launchpad.net/bugs/1165501)
- [StreamController](https://github.com/StreamController/streamcontroller)
