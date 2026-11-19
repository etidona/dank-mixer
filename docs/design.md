# Dank Mixer: design and decisions

This document explains how Dank Mixer works and why it works that way. Most
choices below come from a concrete failure seen while building it; where that
is the case, the failure is described.

Environment it was built and tested on: DankMaterialShell 2.1.2 (Quickshell
0.3.2) on niri, Fedora Asahi (MacBook Air M2), PipeWire with WirePlumber,
systemd 259.

## Contents

1. [Files and roles](#1-files-and-roles)
2. [What counts as an app](#2-what-counts-as-an-app)
3. [One output: plain routing](#3-one-output-plain-routing)
4. [Several outputs: bus and taps](#4-several-outputs-bus-and-taps)
5. [Loopbacks as systemd units](#5-loopbacks-as-systemd-units)
6. [Names of nodes and units](#6-names-of-nodes-and-units)
7. [Leaving a bus without freezing the app](#7-leaving-a-bus-without-freezing-the-app)
8. [Latency sync](#8-latency-sync)
9. [Devices that disappear or change name](#9-devices-that-disappear-or-change-name)
10. [Startup, reload, disable](#10-startup-reload-disable)
11. [Working with Web Popups](#11-working-with-web-popups)
12. [The popout](#12-the-popout)
13. [Saved data](#13-saved-data)
14. [Security notes](#14-security-notes)
15. [Pitfalls met along the way](#15-pitfalls-met-along-the-way)
16. [How it was tested](#16-how-it-was-tested)
17. [Known limitations and open points](#17-known-limitations-and-open-points)

## 1. Files and roles

| File | Role |
|---|---|
| `plugin.json` | Manifest. A `composite` plugin: one daemon plus one bar widget. |
| `MixerDaemon.qml` | One shared instance per shell. Owns all state, every PipeWire change and every loopback unit. |
| `MixerWidget.qml` | Bar icon and popout. Only renders the daemon's `apps` and calls its functions. |

**Why a daemon.** DMS creates one widget instance per bar (per screen), and a
popout can be closed at any time. Routing must keep working with the popout
closed and must not be duplicated per screen, so all state and side effects live
in the daemon (`PluginService.pluginDaemonInstances[pluginId]`). The widget holds
no state of its own.

The daemon's root is a `Scope`, not an `Item`: a daemon has no visual parent and
an `Item` root logs a warning.

## 2. What counts as an app

`streams` are PipeWire audio nodes that are streams, minus:

- nodes with `node.link-group`: the halves of filter chains and loopbacks. On
  Asahi the speakers are a DSP chain (`audio_effect.j313-convolver` and its
  `effect_output` stream); EasyEffects and our own loopbacks also carry a link
  group. Real apps never do;
- DMS's own streams (`AudioService.isOwnStream`).

Streams are grouped by an **app key**: `"out:"` or `"in:"` plus
`application.process.binary`, else `application.name`, else `node.name`.
The binary is preferred because it is stable across tabs and windows (a browser
opens many streams with changing names).

Exception: streams whose `application.id` starts with `webpopups.` are keyed by
that id. Web Popups runs every web app in the same engine
(`QtWebEngineProcess`), so by binary all of them would be one app, and splitting
one would split them all. See [section 11](#11-working-with-web-popups).

The key decides routing and saved state, not what is listed: each stream gets
its own card, so two browser tabs playing at once can be told apart and sent to
different devices. A split app is the exception, one card for all its streams,
since they all play into the same bus (section 4). Each entry carries an `id`
(the app key for a split app, else key + `#` + stream id) used as the list's
object key.

Cards are sorted by the smallest `object.serial` of their streams. Serials only
grow, so a new stream lands at the bottom and the list doesn't jump around.
Split apps that are not running are listed after them (see
[section 10](#10-startup-reload-disable)).

Desktop entry lookups (`DesktopEntries.heuristicLookup`) and icon paths are
cached per app key, because `apps` is recomputed on every node or link change.

## 3. One output: plain routing

An app with a single output is moved by writing WirePlumber's metadata:

```
pw-metadata -n default -- <stream id> target.object <sink name> Spa:String
```

"System default" writes `-1`, which makes WirePlumber follow the default device
again. **Deleting** the key does not move the stream back, which is why `-1` is
used.

Picking a device on a card moves only that stream; nothing is saved per app.
A new stream follows the default device, with one exception. A browser closes a
tab's stream and opens a new one for a new video or a new resolution, and
PipeWire often gives it the same id; without help it went to the default
device, which looked like the AirPlay receiver disconnecting. So a stream that
closes leaves its target in `closed` (app key → `{ target, at }`), and a stream
of the same app that becomes ready less than `replaceWindow` (5 s) later is sent
there once; after that it is left alone, so other tools can still move it. A
new tab opens without a stream closing, so it follows the default device. A
stream that followed the default device leaves nothing behind. (An earlier
version saved one device per app, `chosen`, and sent every new stream there,
new tabs included; its saved data is removed at load.)

Limits of this rule, accepted: a tab opened within 5 s of another tab of the
same app closing takes that tab's device; if a stream that followed the default
closes right after one on a device, the entry is gone; the entry is used once,
so only the first of two new streams takes it; a target that names a device no
longer present is dropped.

A new stream has no properties until it is bound, and without them its app key
is wrong (`out:Zen`, from the node name, instead of `out:zen`, from the binary).
So each delegate records the stream's key, id and serial when `PwNode.ready`
turns true, not when it is created, and only streams born after the plugin
loaded are moved. Streams already there when the plugin loads are left where
they are.

The daemon follows the `default` metadata (`pw-metadata -m`) and keeps each
stream's target in `targets` (stream id → `{ target, serial }`). Ids are reused
at once, so an entry counts only for the stream with that serial; an entry
written before its stream was ready has no serial until the stream's delegate
claims it, and one left by an older stream with the same id is dropped then.
Two kinds of removal come through:

- `remove: id:N key:'target.object'` on a live stream: some apps drop their
  stream's target now and then. Zen, through pipewire-pulse, does it to a
  stream it keeps playing, and WirePlumber then sends it to the default device.
  Tools that move a stream write a new target and never remove the key, so the
  target is put back. Split apps, apps leaving their bus, Web Popups apps and
  streams set to the default device are left out; for them the entry becomes
  `-1`, as WirePlumber now has the stream on the default device.
- `remove: id:N all keys`: the stream is going away. This is never undone, as
  the id may already belong to a new stream. The entry stays while the stream
  is still listed, so the closing delegate can read it for `closed`; otherwise
  it is deleted.

`targets` is emptied when `pw-metadata` quits (PipeWire restarted). After a
PipeWire restart, streams that reconnect within 5 s go back where they were.
A target can be an object serial instead of a node name (pipewire-pulse writes
one when a PulseAudio tool moves a stream); both are checked before use.

A card's menu shows the device its stream is linked to, or nothing while the
stream is not linked yet. Web Popups apps are left to Web Popups, which keeps
their output (see section 11).

## 4. Several outputs: bus and taps

PipeWire links a stream to one sink. To play an app on several devices, the
app's streams go into a private virtual sink, the **bus**, and each output is a
**tap** that copies the bus to one device:

```
app streams ──► bus (Audio/Sink) ──monitor──► tap 0 ──► device A
                                     └──────► tap 1 ──► device B
```

- The bus is a `pw-loopback` whose capture side is a sink
  (`media.class Audio/Sink`, `priority.session 0`, `priority.driver 0` so it is
  never picked as a default or a driver). Its playback side has
  `node.autoconnect false`: it goes nowhere, the taps read the monitor.
- Each tap is a `pw-loopback` that captures the bus monitor
  (`stream.capture.sink true`, `node.passive true`) and plays to its device.
  Its playback side sets `application.name` to the tap's own name so WirePlumber
  remembers each output's volume separately, and `state.restore-target false`
  so WirePlumber does not move it somewhere else from memory.

**Volumes.** The app slider sets the streams' volume (before the bus); each tap's
slider scales it per output. Output volumes are therefore relative to the app's
volume. An earlier idea of juggling absolute volumes was dropped: it caused
audible jumps when outputs were added or removed.

**Keeping streams on the bus.** One watcher per playback stream checks whether a
split app's stream is linked to its bus and moves it there if not. This also
catches streams the app opens later (a new tab, a new video).

**Adding an output** picks the first device not used by the app yet (the default
device counts as used when an output follows it). If none is free, nothing is
added. When an app is split for the first time, its current output keeps
following the default device if that is where it was.

## 5. Loopbacks as systemd units

The loopbacks were first child processes of the shell. That broke YouTube: DMS
runs as the systemd user service `dms` with `KillMode=control-group`, so every
shell restart or plugin reload killed the bus while the browser was playing into
it, and the browser froze its video.

Now each loopback runs as its own transient user unit:

```
systemd-run --user --collect --quiet --expand-environment=no \
  --unit=<unit name> -p PartOf=graphical-session.target \
  -p Restart=always -p RestartSec=1  pw-loopback ...
```

- Outside the shell's cgroup: shell restarts and plugin reloads leave the buses
  alone.
- `PartOf=graphical-session.target`: the units stop at logout, so nothing is
  left running for the next session.
- `Restart=always`: if PipeWire restarts, `pw-loopback` exits and systemd starts
  it again. An explicit `systemctl stop` does not trigger a restart.
- `--collect`: failed units are cleaned up instead of lingering.
- `--expand-environment=no`: see [section 14](#14-security-notes).

The daemon keeps `running`, the list of units it believes are active. `sync()`
compares it with the wanted `loopbacks`, stops the extra units and starts the
missing ones. Every 5 seconds (while anything is split or running) it re-reads
the real list with `systemctl --user list-units`, so a unit that failed to start
or died is started again.

## 6. Names of nodes and units

Node names: `dankmixer.<slug>-<hash>.bus` and `dankmixer.<slug>-<hash>.<output id>`,
where the slug is the app key reduced to `[a-z0-9-]` and cut to 40 characters,
and the hash is FNV-1a of the full key in base 36.

- The slug keeps names readable in `pw-link`, `pw-top` and `systemctl`.
- The hash keeps them unique: without it `out:Foo.bar` and `out:foo-bar` gave the
  same bus, so two apps would have shared one.
- The cut keeps unit names far below systemd's 255-character limit, whatever an
  app calls itself.

Unit names: the node name with dots turned into dashes, plus a hash of the whole
command line, e.g. `dankmixer-out-zen-5bmdeo-bus-zghouz.service`. Any change to
an output (device, delay, properties) gives a new unit name, so the old unit is
stopped and a new one started. Adopted units after a plugin update are also
replaced when their command differs, instead of running forever with old
settings.

Every bus also carries the property `dankmixer.app` with its app key, so other
programs can recognize Dank Mixer buses and which app they belong to.

## 7. Leaving a bus without freezing the app

Closing a bus while an app still plays into it stalls the app: a browser freezes
its video. This was seen when removing outputs in YouTube.

When an app goes back to one output:

1. Its streams' volume is multiplied by the remaining output's volume, so the
   level you hear does not change.
2. The streams are routed to the remaining device.
3. The app is marked as **leaving**, with a deadline 3 seconds ahead. The
   watcher of section 4 stops pulling its streams back to the bus.
4. `settled` lists the leaving apps whose streams are all linked to something
   other than their bus. As soon as an app is there, its split is removed and its
   units stop.
5. A timer closes any leaving app past its deadline, for streams that never
   report a link.

`leaving` is a map, one entry per app, each with its own deadline. A first
version tracked one app at a time: removing outputs from two apps within three
seconds closed the second app's bus with the first app's timer, before its
streams had moved. Adding an output to a leaving app cancels the leave.

When the bus closes, the split is removed **before** the leaving mark. In the
other order, for one update the app is split and not leaving: the watcher saw
its streams, already on their device, as misrouted and sent them back to the
bus that was closing. WirePlumber then found the bus gone and played them on
the default device. This showed up as about a second on the speakers when an
app split between AirPlay and another device went back to AirPlay alone.

If the shell restarts in the middle, the saved split has a single output; at
startup the daemon finds it and finishes the move.

## 8. Latency sync

Devices have very different latencies: on the test machine the speakers' DSP
chain reports about 191 ms, Bluetooth headphones about 170 ms, wired headphones
about 21 ms, an AirPlay receiver more than a second. Played together, they echo.

**Reading.** Every 5 seconds while something is split, the daemon runs
`pw-link -i -t` and `pw-metadata -n settings 0` (with `LC_ALL=C`, because the
locale prints decimal commas). For every device port it reads the input latency
`{ quantum, rate, ns }` and converts it to nanoseconds at the graph clock:
`quantum × Q / R + rate / R + ns`, where R and Q are `clock.force-rate` /
`clock.force-quantum` when set, else `clock.rate` / `clock.quantum`. It keeps the
largest value per device.

Changes smaller than 2 ms keep the previous value. Bluetooth latency wobbles,
and every change of an output's delay restarts that output (a short gap), so
noise must not reach the delays.

**Delaying.** For each split app, every output is delayed by
`slowest − its own latency` with `pw-loopback -d`. The slowest output gets no
delay; the others wait for it.

**Declaring.** The bus declares the slowest latency with
`pw-cli set-param <bus id> ProcessLatency '{ ns: N }'`. PipeWire adds it to the
latency the app sees on its output, so a browser delays the video by the same
amount and lip sync holds. This was verified: the value set on the bus shows up
on the app's output port.

**Per-device sync delay.** PipeWire does not know every delay: Bluetooth
headphones in particular add buffering they don't report, and the user still
heard them late after the automatic sync. Each device in the "Output devices"
card has a "Sync delay" in 5 ms steps, saved per device and used by every split
app. A positive value says "this device sounds later than PipeWire thinks": the
other outputs wait longer, the device itself is not delayed. It lives in the
devices card, not under each app, because the delay belongs to the device.

## 9. Devices that disappear or change name

**Absent devices.** An output whose device is not connected stays off. The first
version let its loopback fall back to the default device, so a disconnected
headphone output played a second copy on the speakers. In the popout the output
shows `<device name> (not connected)` and resumes when the device returns.

**Renamed devices.** Some sinks change name when they reconnect. AirPlay sinks
carry the network address: `raop_sink.hole.local.2a01:…:4309.5000` (IPv6)
became `raop_sink.hole.local.192.168.178.51.5000` (IPv4) after a reconnection,
and the output went silent. Every output now also saves its device's
description ("HolePlay"). When the saved name is missing and exactly one
connected device has that description, the output moves to it and the new name
is saved. Outputs saved before this existed get their description the first
time their device is seen.

## 10. Startup, reload, disable

**Startup:**

1. Saved data is loaded synchronously (`loadPluginData` is synchronous). Before,
   it was loaded in a command callback, and a click in that window could
   overwrite the saved splits.
2. The active `dankmixer-*` units are listed and adopted.
3. Latencies are read, so loopbacks start with their final delay instead of
   restarting a second later.
4. Only then `loaded` becomes true. User actions are ignored until then.

The two startup commands use their own ids in DMS's `Proc` helper, because a
call with an id already pending replaces the pending callback, and the startup
chain once lost its final step that way.

**Reload or shell restart:** units keep running (section 5) and are adopted.

**Split apps that are not running:** their card shows "Not running · N outputs
saved" and a button to forget them, which stops their units. Without it, splits
of apps no longer used would keep their units running forever.

**Disable:** DMS sets the plugin's `enabled` setting to false before unloading
it. On destruction the daemon checks it: if disabled (not a reload, not a shell
exit), it moves every split app's streams to a real device and stops all
`dankmixer-*` units a second later, leaving time for the moves.

## 11. Working with Web Popups

[Web Popups](https://github.com/etidona/dms-web-popups) is another DMS plugin
that runs web apps in popups and has its own audio output per web app. Both
plugins route audio, so they must not fight.

**What went wrong.** With Zen split on the speakers and an AirPlay receiver, and
YouTube in Web Popups on the same AirPlay receiver, removing the AirPlay output
from Zen froze YouTube and stopped the receiver. At that time Web Popups
re-checked its streams on every new sink or sink-input, which Dank Mixer creates
whenever an output changes. A test with a plain client on the same receiver
showed that Dank Mixer joining and leaving a shared sink does not block it by
itself (a 20 s file took 20.1 s, with and without the change, and PipeWire
logged no AirPlay timing errors).

**Rule agreed between the two plugins:** every web app stream has one owner,
the user's latest choice wins, and neither plugin moves a stream back after the
other moved it. Both may play on the same device at the same time.

Web Popups side:

- it moves a stream only when the stream first appears, or when the user picks
  an output in Web Popups;
- it leaves alone the streams linked to a Dank Mixer bus (recognized by the bus
  name `dankmixer.*.bus` or its `dankmixer.app` property);
- it accepts an `output` command on its helper socket, which sets a web app's
  output and saves it as if chosen in Web Popups; an empty output means "let go"
  and moves nothing.

Dank Mixer side:

- web apps are keyed by `application.id` and named and iconed from Web Popups'
  saved variants;
- picking a single device for a web app in Dank Mixer also sends it to Web
  Popups, so both menus show the same choice;
- adding a second output moves the streams to the bus, and only once all of
  them are linked to it tells Web Popups to let go. The first version did it
  the other way round: when Web Popups cleared its choice, WirePlumber sent the
  stream to the default device for about 0.4 s before it reached the bus, a
  short jump with real audio;
- going back to one output tells Web Popups the remaining device once the bus is
  closed;
- `dms ipc call dankMixer release <application.id>` is how Web Popups takes an
  app back when the user picks an output there while the app is split: Dank
  Mixer stops pulling the streams to the bus, does not move them, and closes the
  bus as soon as Web Popups has moved them (3 s fallback). It answers `released`
  or `none`, and it does not notify Web Popups back, to avoid a loop.

Dank Mixer only sends to Web Popups when the `application.id` matches one of
its saved variants.

## 12. The popout

- Opens on click only, even with the bar's hover popouts on (the widget
  overrides `triggerHoverPopout`): sliders need a popout that doesn't vanish
  when the pointer leaves.
- **Pin:** keeps the popout open while working in other windows; clicks and
  keyboard reach the other windows (`backgroundInteractive`,
  `customKeyboardFocus`). Not saved: a popout pinned at login would be a surprise.
- **Expanded view:** full height with every card open; saved.
- **Folding:** every card starts folded; each card's state is saved once the
  user changes it. A folded app keeps its name and volume.
- **What is playing:** under the app name, the card shows the stream's
  `media.name` (for a browser, the title of the video), since an app name alone
  doesn't tell which tab or video is playing. A split app shows its newest
  stream's title. Folding is saved per app, so all cards of an app fold together.
  App names and titles stay on one line and end in an ellipsis when too long.
- **Split outputs** sit on indented panels joined to the app by an accent line,
  so it is clear which sliders belong to which app.
- **Wheel:** the mouse wheel and touchpad scroll the list and never change a
  volume. DMS sliders move one full step per wheel event, and a touchpad sends
  many tiny events, so volumes raced. DMS also turns the wheel back on when its
  scroll container stops overflowing, so the widget switches it off again
  whenever that happens.
- **Dropdowns:** a choice in DMS's dropdown replaces its value binding; the
  widget restores it, so the menu keeps following the real device (for example
  when WirePlumber moves a stream after a device is unplugged).
- **Output devices card:** the radio button sets the system default output;
  each device has its volume and its sync delay. The sync delay is a small
  folded button showing its value; clicked, it shows its -/+ controls right
  next to it. Placed at the right edge of the row, the -/+ buttons read as
  volume controls.

## 13. Saved data

Saved with `PluginService.savePluginData` under the plugin id:

| Key | Content |
|---|---|
| `splits` | app key → list of `{ id, sink, label }`; `sink` "" means the default device, `label` is the device description |
| `offsets` | device name → sync delay in ms |
| `collapsed` | card key ("devices" or an app key) → folded |
| `expanded` | expanded view on or off |

## 14. Security notes

- Commands are always passed as argument lists, never through a shell, except
  one constant `sh -c` for the latency read. `pw-metadata` gets `--` before
  positional arguments. JSON properties are built with `JSON.stringify`.
- App names and device names end up in loopback arguments (descriptions). They
  are chosen by apps or, for AirPlay, announced over the network. `systemd-run`
  expands `$VAR` and `${VAR}` in arguments by default; `--expand-environment=no`
  turns that off. Tested with an app named `weird${HOME}name...`: the name
  reached PipeWire literally.
- Node and unit names are built only from a reduced slug and a hash, never from
  raw names.
- `plugin.json` declares the `process` permission. In DMS 2.1.2 permissions are
  informational except `settings_write`, which only gates a settings page, and
  this plugin has none.

## 15. Pitfalls met along the way

- Qt's JavaScript engine has no `??=` and no `flatMap`.
- Inline components cannot be nested.
- A running Quickshell `Process` ignores later changes to `command`; a
  `ScriptModel` with `objectProp` may reuse a delegate and only swap its data.
  (This mattered while loopbacks were child processes.)
- Changing a property inside its own `on…Changed` handler logs a binding loop;
  `Qt.callLater` defers it.
- A property must not be named `on` + capital letter (`onBus`): QML reads it
  as a handler name and its change handler never runs.
- DMS's `Proc.runCommand` debounces by id and replaces the pending callback.
- `pw-link -t` needs `-i` or `-o`; numbers depend on the locale.
- `pkill -f` patterns must be anchored: an unanchored pattern once matched the
  shell running the test.
- `pw-metadata -m` prints `update: id:N key:'k' value:'v' type:'t'`, then
  `remove: id:N key:'k'` or `remove: id:N all keys` (when the object goes);
  writes on an id that doesn't exist are ignored. PipeWire reuses a freed id
  at once, often for the next stream of the same app, and the `all keys`
  removal and Quickshell's node removal come in no fixed order.
- A `PwNode` has no properties until `ready`; code that reads them when the
  node appears must wait for it.
- `dms ipc call widget hide <id>` hides the widget from the bar (restore with
  `widget reset`); `widget toggle` opens and closes the popout.

## 16. How it was tested

- A test copy of the daemon with an extra `IpcHandler` (add, remove, set output,
  forget, state) drove the plugin from scripts; the published files never
  contain it.
- Test clients were copies of `pacat` under other names, playing silence, so
  real apps were never touched. `PULSE_PROP=application.id=...` imitated web
  apps.
- Checked with `pw-link -l`, `pw-dump`, `pw-metadata`, `systemctl --user` and
  the DMS journal.
- Cases covered: split and unsplit, two removals in a row, remove then add at
  once, reload during a removal, plugin reload with units adopted (same PIDs),
  unit killed and unit stopped from outside, absent device, renamed device (a
  null sink recreated under another name with the same description), plugin
  disable and enable, odd app names, a client on a shared AirPlay sink while a
  Dank Mixer output joins and leaves it, Web Popups release.
- Web Popups end to end, together with the Web Popups session: a fake web app
  (`webpopups.zz_t`) with a running Web Popups daemon. Picking a device in Dank
  Mixer, splitting, going back to one output, and picking an output in Web
  Popups while split: stream and saved choice matched on both sides each time.
- Not covered: real Bluetooth latency by ear.

## 17. Known limitations and open points

- Tested on one machine only; hence the alpha status.
- Changing an output's delay restarts that output: a short gap.
- Latency figures for Bluetooth and AirPlay are estimates; the per-device sync
  delay is the manual fix.
- Recording apps get a single input; several inputs per app are not supported.
- If the plugin folder is deleted without disabling the plugin first, its units
  keep running until logout (`systemctl --user stop 'dankmixer-*'` stops them).
- MIDI control surfaces are not supported; see the
  [feasibility study](midi-control-surfaces.md).
