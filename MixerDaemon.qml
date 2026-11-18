import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Common
import qs.Services

// One shared instance per shell: owns the routing state and the loopback units.
// Bar widgets only render `apps` and call the functions below.
//
// An app sent to several outputs plays into a private virtual sink (the bus);
// each output is a loopback from the bus monitor to a device, so every output
// has its own volume, relative to the app's volume.
Scope {
    id: root

    property string pluginId
    // Passed by DMS on creation; the PluginService singleton is used instead.
    property var pluginService

    // Every PipeWire node and systemd unit this plugin creates starts with it.
    readonly property string prefix: "dankmixer"

    // App key -> [{ id, sink, label }] for apps sent to two or more outputs;
    // label is the device's description, to find it again under a new name.
    property var splits: ({})
    // Card key ("devices" or an app key) -> folded or not, once the user chose.
    property var collapsed: ({})
    // Popout stays open while working elsewhere (this session only).
    property bool pinned: false
    // Popout at full height with every card open (saved).
    property bool expanded: false
    // Saved data, running units and latencies are known; actions wait for it.
    property bool loaded: false
    // When it became loaded (ms); streams older than this are not new.
    property real loadedAt: 0
    // App key -> { until (ms), handBack } for apps whose streams are moving off
    // their bus; handBack tells Web Popups the device they end up on.
    property var leaving: ({})
    // Device name -> latency in ns as PipeWire reports it.
    property var latencies: ({})
    // App key -> { sink, label } for apps sent to one chosen device (saved).
    // Browsers open a new stream for every video; new streams go there too.
    // Web Popups apps are not kept here: Web Popups remembers their output.
    property var chosen: ({})
    // Device name -> extra latency in ms set by the user, for delay PipeWire doesn't know about (saved).
    property var offsets: ({})
    // Systemd units of the loopbacks running now.
    property var running: []
    // Web apps just split: Web Popups is told to let go once their streams are
    // on the bus, not before, or WirePlumber would send them to the default
    // device in between.
    property var handOff: ({})
    // App key -> { name, icon }; desktop entry lookups are slow, apps change often.
    property var labels: ({})

    readonly property var sinks: AudioService.getAvailableSinks().filter(n => !n.isStream && !isOwn(n))
    readonly property var sources: Pipewire.nodes.values.filter(n => n.audio && !n.isSink && !n.isStream)
    // Halves of filters and loopbacks (DSP chains, EasyEffects, ours) carry a link group; apps never do.
    readonly property var streams: Pipewire.nodes.values.filter(n => n.audio && n.isStream && !n.properties?.["node.link-group"] && !AudioService.isOwnStream(n))
    readonly property string defaultSink: AudioService.sink?.name ?? ""

    // One entry per stream (a browser tab is a stream of its own), oldest
    // first (PipeWire serials only grow, so new streams land at the bottom).
    // A split app is one entry: all its streams share its bus. Split apps that
    // are not running stay listed, so they can be forgotten.
    readonly property var apps: {
        const groups = {};
        for (const n of streams) {
            const key = appKey(n);
            groups[key] = (groups[key] ?? []).concat(n);
        }
        for (const key of Object.keys(splits))
            groups[key] = groups[key] ?? [];
        return Object.keys(groups).reduce((all, key) => all.concat(splits[key] ? [describe(key, groups[key])] : groups[key].map(n => describe(key, [n]))), []).sort((a, b) => (a.since - b.since) || 0);
    }

    // Loopbacks run for every saved split, so new streams find their bus at once.
    // An output whose device is not connected stays off instead of falling back
    // to the default device.
    readonly property var loopbacks: loaded ? Object.keys(splits).reduce((all, key) => {
        const bus = busName(key);
        return all.concat(loopback(bus, 0, {
                "media.class": "Audio/Sink",
                "node.name": bus,
                "node.description": "Mixer bus: " + appName(key),
                "dankmixer.app": key,
                "priority.session": 0,
                "priority.driver": 0
            }, {
                "node.name": bus + ".out",
                "node.autoconnect": false
            }), splits[key].filter(tap => present(tap.sink)).map(tap => {
            const name = tapName(key, tap.id);
            const delay = Math.round((slowest(key) - latency(tap.sink)) / 1e6);
            return loopback(name, delay, {
                "node.name": name + ".in",
                "target.object": bus,
                "stream.capture.sink": true,
                "node.passive": true
            }, Object.assign({
                "node.name": name + ".out",
                "node.description": "Mixer output: " + appName(key),
                "application.name": name, // own key for WirePlumber's volume memory
                "state.restore-target": false
            }, tap.sink ? {
                "target.object": tap.sink
            } : {}));
        }));
    }, []) : []

    // "" stands for the default device.
    function deviceName(sink) {
        return sink || defaultSink;
    }

    // The default device is always there.
    function present(sink) {
        return !sink || sinks.some(n => n.name === sink);
    }

    function isOwn(node) {
        return (node?.name ?? "").startsWith(prefix + ".");
    }

    function node(name) {
        return Pipewire.nodes.values.find(n => n.name === name) ?? null;
    }

    function appSource(props) {
        return props["application.process.binary"] || props["application.name"] || "";
    }

    // Web Popups runs every web app in the same browser engine, so its apps
    // are told apart by their application.id ("webpopups.<variant id>").
    function appKey(node) {
        const p = node.properties ?? {};
        const id = p["application.id"] ?? "";
        return (node.isSink ? "out:" : "in:") + (id.startsWith("webpopups.") ? id : (appSource(p) || node.name));
    }

    // Web Popups variant behind an app key, or null.
    function webApp(key) {
        const id = appName(key);
        if (!id.startsWith("webpopups."))
            return null;
        const variants = SettingsData.getPluginSetting("webPopups", "variants", []) ?? [];
        return variants.find(v => v.id === id.slice(10)) ?? null;
    }

    // Web Popups keeps its own output per web app; it is told every choice made
    // here, so both plugins agree and neither moves the stream back. "" lets go.
    function tellWebPopups(key, sink) {
        const dir = PluginService.availablePlugins["webPopups"]?.pluginDirectory;
        if (!dir || !webApp(key))
            return;
        Quickshell.execDetached(["python3", dir + "/helper/webpopups.py", "send", JSON.stringify({
                "cmd": "output",
                "id": appName(key).slice(10),
                "output": sink
            })]);
    }

    function appName(key) {
        return key.replace(/^(out|in):/, "");
    }

    // FNV-1a, base 36: keeps names unique where the slug merges two keys.
    function hash(text) {
        let h = 0x811c9dc5;
        for (let i = 0; i < text.length; i++)
            h = Math.imul(h ^ text.charCodeAt(i), 0x01000193) >>> 0;
        return h.toString(36);
    }

    // Short and safe for node and unit names, whatever the app calls itself.
    function base(key) {
        return prefix + "." + key.replace(/[^A-Za-z0-9]+/g, "-").toLowerCase().slice(0, 40) + "-" + hash(key);
    }

    function busName(key) {
        return base(key) + ".bus";
    }

    function tapName(key, id) {
        return base(key) + "." + id;
    }

    function tapNode(key, id) {
        return node(tapName(key, id) + ".out");
    }

    // The unit name carries a hash of the whole command: any change (delay,
    // device, properties) starts a new unit and stops the old one.
    function loopback(name, delayMs, capture, playback) {
        const command = ["pw-loopback", "-n", name, "-d", String(delayMs / 1000), "--capture-props", JSON.stringify(capture), "--playback-props", JSON.stringify(playback)];
        return {
            "unit": name.replace(/\./g, "-") + "-" + hash(JSON.stringify(command)) + ".service",
            "command": command
        };
    }

    // The device a stream is linked to, or "" while it is not linked.
    function linkedDevice(stream) {
        const group = Pipewire.linkGroups.values.find(g => stream.isSink ? g.source === stream : g.target === stream);
        return (stream.isSink ? group?.target?.name : group?.source?.name) ?? "";
    }

    function label(key, props) {
        const web = webApp(key);
        if (web)
            return {
                "name": web.name ?? "",
                "icon": "",
                "iconName": web.icon ?? ""
            };
        if (!labels[key] && props) {
            const entry = DesktopEntries.heuristicLookup(appSource(props));
            labels[key] = {
                "name": entry?.name || props["application.name"] || "",
                "icon": Quickshell.iconPath(props["application.icon-name"] || entry?.icon || "", true)
            };
        }
        return labels[key] ?? {
            "name": "",
            "icon": ""
        };
    }

    function describe(key, nodes) {
        const first = nodes[0] ?? null;
        const taps = splits[key];
        const text = label(key, first?.properties);
        return {
            "key": key,
            // Unique per entry: the app for a split app, else the stream.
            "id": taps ? key : key + "#" + (first?.id ?? ""),
            "nodes": nodes,
            "running": !!first,
            "playback": first ? first.isSink : key.startsWith("out:"),
            "split": !!taps,
            "since": first ? Math.min(...nodes.map(n => Number(n.properties?.["object.serial"] ?? n.id))) : Infinity,
            "name": text.name || first?.name || appName(key),
            // What is playing (a video or song title), from the newest stream.
            "title": nodes.map(n => ({
                        "serial": Number(n.properties?.["object.serial"] ?? n.id),
                        "title": n.properties?.["media.name"] ?? ""
                    })).filter(n => n.title).sort((a, b) => b.serial - a.serial)[0]?.title ?? "",
            "icon": text.icon,
            "iconName": text.iconName ?? "",
            "outputs": taps ? taps.map(tap => ({
                        "id": tap.id,
                        "device": tap.sink,
                        "label": tap.label ?? "",
                        "node": tapNode(key, tap.id)
                    })) : [
                {
                    "id": 0,
                    // Where the stream plays; the chosen device until it is linked.
                    "device": (first ? linkedDevice(first) : "") || (chosen[key]?.sink ?? ""),
                    "label": chosen[key]?.label ?? "",
                    "node": first
                }
            ]
        };
    }

    // Sends a stream to a device by name; "" (WirePlumber's -1) follows the default device.
    function route(stream, name) {
        Proc.runCommand(prefix + ".route." + stream.id, ["pw-metadata", "-n", "default", "--", String(stream.id), "target.object", name || "-1", "Spa:String"], null, 0, undefined, root);
    }

    // Stream id -> { target, serial }: the stream's target.object as last seen in
    // the default metadata, and the stream it was set for (ids are reused).
    property var targets: ({})

    // Some apps drop their stream's target now and then: Zen, through
    // pipewire-pulse, does when YouTube restarts its player for a new
    // resolution. WirePlumber then sends the stream to the default device.
    // Tools that move a stream write a new target and never remove one, so a
    // removed target is put back. Split apps are kept on their bus elsewhere,
    // and Web Popups looks after its own apps.
    function metadataLine(line) {
        const m = /^(update|remove): id:(\d+) (?:all keys|key:'([^']*)'(?: value:'(.*)' type:'[^']*')?)$/.exec(line);
        if (!m || (m[3] !== undefined && m[3] !== "target.object"))
            return;
        const id = Number(m[2]);
        const stream = streams.find(n => n.id === id && n.isSink) ?? null;
        const serial = stream?.properties?.["object.serial"] ?? "";
        if (m[1] === "update") {
            targets[id] = {
                "target": m[4],
                "serial": serial
            };
            return;
        }
        const was = targets[id];
        delete targets[id];
        if (!stream || !was || (was.serial && was.serial !== serial) || was.target === "-1")
            return;
        const key = appKey(stream);
        if (splits[key] || key in leaving || webApp(key))
            return;
        console.info("dankMixer: stream", id, "lost its target, sent back to", was.target);
        route(stream, was.target);
    }

    Process {
        id: metadataWatch
        command: ["pw-metadata", "-n", "default", "-m"]
        stdout: SplitParser {
            onRead: line => root.metadataLine(line)
        }
        // pw-metadata quits when PipeWire restarts.
        onExited: restartWatch.start()
    }

    Timer {
        id: restartWatch
        interval: 2000
        onTriggered: metadataWatch.running = true
    }

    function makeTap(id, sink) {
        return {
            "id": id,
            "sink": sink,
            "label": node(sink)?.description ?? ""
        };
    }

    // Some devices change name when they reconnect (AirPlay names carry the
    // network address). A missing device is matched again by its description
    // when exactly one connected device has it; taps saved before labels
    // existed get one from their connected device.
    // The device to use for a saved { sink, label }, or "" to keep it as is.
    function renamed(t) {
        if (!t.sink || present(t.sink))
            return t.sink && !t.label ? t.sink : "";
        const same = t.label ? sinks.filter(n => n.description === t.label) : [];
        return same.length === 1 ? same[0].name : "";
    }

    function findDevices() {
        if (!loaded)
            return;
        let changed = false;
        const next = {};
        for (const key in splits)
            next[key] = splits[key].map(t => {
                const sink = renamed(t);
                if (!sink)
                    return t;
                changed = true;
                return makeTap(t.id, sink);
            });
        if (changed)
            setSplits(next);
        for (const key in chosen) {
            const sink = renamed(chosen[key]);
            if (sink)
                choose(key, sink);
        }
    }

    function choose(key, sink) {
        if (webApp(key))
            return;
        const next = Object.assign({}, chosen);
        if (sink)
            next[key] = {
                "sink": sink,
                "label": node(sink)?.description ?? ""
            };
        else
            delete next[key];
        chosen = next;
        PluginService.savePluginData(pluginId, "chosen", next);
    }

    onSinksChanged: Qt.callLater(findDevices)

    function setSplits(next) {
        splits = next;
        PluginService.savePluginData(pluginId, "splits", next);
        readLatencies();
    }

    // Latency sync: a split app's bus declares its slowest output's latency, so the
    // app delays its video to match; every faster output waits the difference.
    function latency(sink) {
        return (latencies[deviceName(sink)] ?? 0) + offset(sink) * 1e6;
    }

    function offset(sink) {
        return offsets[deviceName(sink)] ?? 0;
    }

    function shiftOffset(sink, ms) {
        const name = deviceName(sink);
        if (!name)
            return;
        const next = Object.assign({}, offsets, {
            [name]: offset(sink) + ms
        });
        offsets = next;
        PluginService.savePluginData(pluginId, "offsets", next);
    }

    function slowest(key) {
        return Math.max(0, ...(splits[key] ?? []).filter(tap => present(tap.sink)).map(tap => latency(tap.sink)));
    }

    // PipeWire reports latency in quanta, samples and ns; all become ns at the
    // graph clock (a forced rate or quantum wins over the configured one).
    // Changes under 2 ms are measurement noise and would only restart outputs.
    function readLatencies(done) {
        Proc.runCommand(prefix + ".latency" + (done ? ".init" : ""), ["sh", "-c", "LC_ALL=C pw-link -i -t; pw-metadata -n settings 0"], output => {
            const setting = name => Number(output.match(new RegExp("'clock\\." + name + "' value:'(\\d+)'"))?.[1]) || 0;
            const rate = setting("force-rate") || setting("rate") || 48000;
            const quantum = setting("force-quantum") || setting("quantum") || 1024;
            const next = {};
            const lines = output.split("\n");
            for (let i = 0; i + 1 < lines.length; i++) {
                const value = lines[i + 1].match(/input +latency: +\{ quantum=\[ \S+ (\S+) \], rate=\[ \d+ (\d+) \], ns=\[ \d+ (\d+) \]/);
                if (/^\s/.test(lines[i]) || !value)
                    continue;
                const device = lines[i].slice(0, lines[i].lastIndexOf(":"));
                const ns = Number(value[1]) * quantum / rate * 1e9 + Number(value[2]) / rate * 1e9 + Number(value[3]);
                next[device] = Math.max(next[device] ?? 0, ns);
            }
            for (const device in next) {
                const before = latencies[device];
                if (before !== undefined && Math.abs(before - next[device]) < 2e6)
                    next[device] = before;
            }
            if (JSON.stringify(next) !== JSON.stringify(latencies))
                latencies = next;
            done?.();
        }, 0, undefined, root);
    }

    // The units that really run; a unit that failed to start or died with
    // PipeWire is then started again by sync().
    function readUnits(done) {
        Proc.runCommand(prefix + ".units" + (done ? ".init" : ""), ["systemctl", "--user", "list-units", "--plain", "--no-legend", prefix + "-*"], output => {
            running = output.split("\n").map(line => line.trim().split(/\s+/)).filter(cols => cols[0].startsWith(prefix + "-") && cols[2] === "active").map(cols => cols[0]);
            if (done)
                done();
            else
                sync();
        }, 0, undefined, root);
    }

    // Bluetooth codecs and clock changes move latencies while playing.
    Timer {
        running: root.loaded && (Object.keys(root.splits).length > 0 || root.running.length > 0)
        interval: 5000
        repeat: true
        onTriggered: {
            root.readLatencies();
            root.readUnits();
        }
    }

    Instantiator {
        model: ScriptModel {
            values: Object.keys(root.splits)
        }
        delegate: QtObject {
            id: declaration
            required property string modelData
            readonly property var bus: root.node(root.busName(modelData))
            readonly property real ns: Math.round(root.slowest(modelData))
            readonly property string declared: bus ? bus.id + " " + ns : ""
            function declare() {
                if (bus)
                    Proc.runCommand(root.prefix + ".declare." + modelData, ["pw-cli", "set-param", String(bus.id), "ProcessLatency", "{ ns: " + ns + " }"], null, 0, undefined, root);
            }
            onDeclaredChanged: declare()
            Component.onCompleted: declare()

            readonly property bool inBus: !!bus && root.streams.filter(n => root.appKey(n) === modelData).every(n => root.linkedDevice(n) === bus.name)
            onInBusChanged: if (inBus && root.handOff[modelData]) {
                const next = Object.assign({}, root.handOff);
                delete next[modelData];
                root.handOff = next;
                root.tellWebPopups(modelData, "");
            }
        }
    }

    // Every card starts folded.
    function isCollapsed(key) {
        return collapsed[key] ?? true;
    }

    function toggleExpanded() {
        expanded = !expanded;
        PluginService.savePluginData(pluginId, "expanded", expanded);
    }

    function toggleCollapsed(key) {
        const next = Object.assign({}, collapsed, {
            [key]: !isCollapsed(key)
        });
        collapsed = next;
        PluginService.savePluginData(pluginId, "collapsed", next);
    }

    function setOutput(app, id, device) {
        if (!loaded)
            return;
        const taps = splits[app.key];
        if (!taps) {
            choose(app.key, device);
            tellWebPopups(app.key, device);
            app.nodes.forEach(n => route(n, device));
            return;
        }
        stayOnBus(app.key);
        setSplits(Object.assign({}, splits, {
            [app.key]: taps.map(t => t.id === id ? makeTap(id, device) : t)
        }));
        const tap = tapNode(app.key, id);
        if (tap)
            route(tap, device);
    }

    // A new output goes to the first device not in use yet. The app's current
    // output keeps following the default device if it was on it.
    function addOutput(app) {
        if (!loaded)
            return;
        const current = app.outputs[0].device;
        const taps = splits[app.key] ?? [makeTap(0, current === defaultSink ? "" : current)];
        const used = taps.map(tap => deviceName(tap.sink));
        const free = sinks.find(n => !used.includes(n.name));
        if (!free)
            return;
        if (!splits[app.key])
            choose(app.key, "");
        if (!splits[app.key] && webApp(app.key))
            handOff = Object.assign({}, handOff, {
                [app.key]: true
            });
        stayOnBus(app.key);
        setSplits(Object.assign({}, splits, {
            [app.key]: taps.concat(makeTap(Math.max(...taps.map(t => t.id)) + 1, free.name))
        }));
    }

    function removeOutput(app, id) {
        if (!loaded)
            return;
        const taps = splits[app.key].filter(tap => tap.id !== id);
        setSplits(Object.assign({}, splits, {
            [app.key]: taps
        }));
        if (taps.length < 2)
            leaveBus(app.key);
    }

    // Split app that is not running: nothing plays into its bus, so it closes at once.
    function forget(key) {
        if (!loaded || streams.some(n => appKey(n) === key))
            return;
        const next = Object.assign({}, splits);
        delete next[key];
        stayOnBus(key);
        setSplits(next);
    }

    // Back to a single output: keep its level and move the streams; the bus
    // closes only once they play on the device (see `settled`).
    function leaveBus(key) {
        const tap = splits[key][0];
        if (!tap) {
            const next = Object.assign({}, splits);
            delete next[key];
            setSplits(next);
            return;
        }
        const gain = tapNode(key, tap.id)?.audio?.volume ?? 1;
        if (tap.sink)
            choose(key, tap.sink);
        streams.filter(n => appKey(n) === key).forEach(n => {
            n.audio.volume *= gain;
            route(n, tap.sink);
        });
        leave(key, true, tap.sink);
    }

    // `sink` is the device the app ends up on, handed back to Web Popups.
    function leave(key, handBack, sink) {
        leaving = Object.assign({}, leaving, {
            [key]: {
                "until": Date.now() + 3000,
                "handBack": handBack,
                "sink": sink ?? ""
            }
        });
    }

    // Another plugin takes the app over (Web Popups when the user picks an
    // output there): its streams are left where that plugin moves them, and
    // the bus closes once they are off it.
    IpcHandler {
        target: "dankMixer"

        function release(app: string): string {
            const key = /^(out|in):/.test(app) ? app : "out:" + app;
            if (!root.splits[key])
                return "none";
            root.leave(key, false);
            return "released";
        }
    }

    function stayOnBus(key) {
        if (!(key in leaving))
            return;
        const next = Object.assign({}, leaving);
        delete next[key];
        leaving = next;
    }

    // Closing a bus under a stream that still plays into it stalls the app
    // (a browser freezes its video), so wait until every stream has moved.
    readonly property var settled: Object.keys(leaving).filter(key => streams.every(n => {
            if (appKey(n) !== key)
                return true;
            const device = linkedDevice(n);
            return device !== "" && device !== busName(key);
        }))
    onSettledChanged: if (settled.length)
        Qt.callLater(closeBuses, settled)

    function closeBuses(keys) {
        const next = Object.assign({}, splits);
        const still = Object.assign({}, leaving);
        let changed = false;
        for (const key of keys) {
            if (!(key in still))
                continue;
            if (still[key].handBack)
                tellWebPopups(key, still[key].sink);
            delete still[key];
            delete next[key];
            changed = true;
        }
        if (!changed)
            return;
        // Splits first: for a moment the app would otherwise be split and
        // not leaving, and its streams, already on their device, would be
        // sent back to the bus that is about to close.
        setSplits(next);
        leaving = still;
    }

    // Fallback for streams that never report a link.
    Timer {
        running: Object.keys(root.leaving).length > 0
        interval: 500
        repeat: true
        onTriggered: root.closeBuses(Object.keys(root.leaving).filter(key => root.leaving[key].until < Date.now()))
    }

    PwObjectTracker {
        objects: Pipewire.nodes.values.filter(n => n.audio)
    }

    // Keeps every stream of a split app on its bus, including streams opened later.
    // A new stream of an app with a chosen device is sent there once; after
    // that it is left alone, so other tools can still move it.
    Instantiator {
        model: ScriptModel {
            values: root.streams.filter(n => n.isSink)
        }
        delegate: QtObject {
            required property PwNode modelData
            readonly property string bus: {
                const key = root.appKey(modelData);
                return root.splits[key] && !(key in root.leaving) && root.node(root.busName(key)) ? root.busName(key) : "";
            }
            readonly property bool misrouted: bus !== "" && root.linkedDevice(modelData) !== bus
            function fix() {
                if (misrouted)
                    root.route(modelData, bus);
            }
            onMisroutedChanged: fix()
            // A new stream has no properties until it is bound, and without
            // them its app key is wrong. Streams already there when the plugin
            // loads are left where they are.
            property bool placed: false
            readonly property real born: Date.now()
            readonly property bool ready: modelData.ready
            function place() {
                if (placed || !ready || !root.loaded || born < root.loadedAt)
                    return;
                placed = true;
                const key = root.appKey(modelData);
                const sink = root.chosen[key]?.sink ?? "";
                if (!root.splits[key] && sink && root.present(sink))
                    root.route(modelData, sink);
            }
            onReadyChanged: place()
            Component.onCompleted: {
                fix();
                place();
            }
        }
    }

    // Each loopback runs as its own systemd user unit, outside the shell: a shell
    // restart or plugin reload leaves the buses alone, so apps playing into them
    // never lose their device (a browser would freeze its video). The units stop
    // with the graphical session. App and device names reach the command line,
    // so systemd must not expand "$" in them.
    function sync() {
        const want = loopbacks.map(l => l.unit);
        for (const unit of running)
            if (!want.includes(unit))
                Quickshell.execDetached(["systemctl", "--user", "stop", unit]);
        for (const l of loopbacks)
            if (!running.includes(l.unit))
                Quickshell.execDetached(["systemd-run", "--user", "--collect", "--quiet", "--expand-environment=no", "--unit=" + l.unit, "-p", "PartOf=graphical-session.target", "-p", "Restart=always", "-p", "RestartSec=1"].concat(l.command));
        running = want;
    }

    onLoopbacksChanged: if (loaded)
        sync()

    // Saved data first, then the units still running from before a reload are
    // adopted; sync() stops the ones no longer wanted and starts the missing
    // ones. Loopbacks start only with latencies known, so none restarts right away.
    Component.onCompleted: {
        splits = PluginService.loadPluginData(pluginId, "splits", {});
        collapsed = PluginService.loadPluginData(pluginId, "collapsed", {});
        expanded = PluginService.loadPluginData(pluginId, "expanded", false);
        offsets = PluginService.loadPluginData(pluginId, "offsets", {});
        chosen = PluginService.loadPluginData(pluginId, "chosen", {});
        readUnits(() => readLatencies(() => {
                loadedAt = Date.now();
                loaded = true;
                metadataWatch.running = true;
                findDevices();
                // Left half-way by a restart while moving off a bus.
                Object.keys(splits).filter(key => splits[key].length < 2).forEach(key => leaveBus(key));
            }));
    }

    // Disabled by the user (not reloaded, not shell exit): move the streams off
    // their buses, then stop every unit once they had time to move.
    Component.onDestruction: {
        if (SettingsData.getPluginSetting(pluginId, "enabled", true))
            return;
        for (const n of streams) {
            const taps = splits[appKey(n)];
            const tap = taps?.find(tap => present(tap.sink)) ?? taps?.[0];
            if (tap)
                Quickshell.execDetached(["pw-metadata", "-n", "default", "--", String(n.id), "target.object", tap.sink || "-1", "Spa:String"]);
        }
        Quickshell.execDetached(["sh", "-c", "sleep 1; systemctl --user stop '" + prefix + "-*'"]);
    }
}
