pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Modules.ControlCenter.Widgets

// Bar icon and popout. All state lives in MixerDaemon.
PluginComponent {
    id: root

    readonly property var mixer: PluginService.pluginDaemonInstances[pluginId] ?? null

    horizontalBarPill: Component {
        DIcon {
            name: "tune"
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }
    verticalBarPill: horizontalBarPill

    // Opens on click only, even with the bar's hover popouts on: sliders need a stable popout.
    function triggerHoverPopout() {
    }

    popoutWidth: 440
    popoutContent: Component {
        PopoutComponent {
            id: popout

            readonly property real maxHeight: (root.parentScreen?.height ?? 1080) * 0.8 - toolbar.height

            // Pinned: clicks outside reach other windows, and so does the keyboard.
            Binding {
                when: !!popout.parentPopout
                target: popout.parentPopout
                property: "backgroundInteractive"
                value: !root.mixer?.pinned
            }
            Binding {
                when: !!popout.parentPopout
                target: popout.parentPopout
                property: "customKeyboardFocus"
                value: root.mixer?.pinned ? WlrKeyboardFocus.None : null
            }

            Row {
                id: toolbar
                anchors.right: parent.right
                spacing: Theme.spacingXS

                DIconButton {
                    iconName: "push_pin"
                    iconFilled: root.mixer?.pinned ?? false
                    tooltipText: root.mixer?.pinned ? "Unpin" : "Pin open"
                    onClicked: {
                        if (root.mixer)
                            root.mixer.pinned = !root.mixer.pinned;
                    }
                }
                DIconButton {
                    iconName: root.mixer?.expanded ? "close_fullscreen" : "open_in_full"
                    tooltipText: root.mixer?.expanded ? "Compact view" : "Expanded view"
                    onClicked: root.mixer?.toggleExpanded()
                }
            }

            Flickable {
                width: parent.width
                height: root.mixer?.expanded ? popout.maxHeight : Math.min(contentHeight, popout.maxHeight)
                contentHeight: list.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: list
                    width: parent.width
                    spacing: Theme.spacingXS

                    Card {
                        width: list.width

                        Header {
                            id: devicesHeader
                            key: "devices"
                            text: "Output devices"
                            iconName: "speaker"
                        }

                        Repeater {
                            model: devicesHeader.open ? root.mixer?.sinks ?? [] : []
                            delegate: Column {
                                id: device
                                required property var modelData
                                width: parent.width

                                // Click to make this the system default output.
                                Item {
                                    id: deviceName
                                    readonly property bool isDefault: device.modelData === AudioService.sink
                                    width: parent.width
                                    height: Theme.iconSizeSmall + Theme.spacingXS

                                    Row {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS

                                        DIcon {
                                            name: deviceName.isDefault ? "check_circle" : "radio_button_unchecked"
                                            filled: deviceName.isDefault
                                            size: Theme.iconSizeSmall
                                            color: deviceName.isDefault ? Theme.primary : Theme.surfaceVariantText
                                        }
                                        StyledText {
                                            width: deviceName.width - Theme.iconSizeSmall - Theme.spacingXS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: AudioService.displayName(device.modelData)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: deviceName.isDefault ? Theme.surfaceText : Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !deviceName.isDefault
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: AudioService.setDefaultSinkByName(device.modelData.name)
                                    }
                                }
                                VolumeSlider {
                                    width: parent.width
                                    node: device.modelData
                                    maxVolume: AudioService.getMaxVolumePercent(device.modelData)
                                }
                                SyncRow {
                                    width: parent.width
                                    device: device.modelData.name
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: !root.mixer?.apps.length
                        width: parent.width
                        leftPadding: Theme.spacingS
                        text: "No application is using audio."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: ScriptModel {
                            values: root.mixer?.apps ?? []
                            objectProp: "id"
                        }
                        delegate: AppCard {
                            width: list.width
                        }
                    }
                }
            }
        }
    }

    // The wheel scrolls the list, never the volume: DMS sliders move a full step
    // per wheel event, far too fast on a touchpad. DMS turns the wheel back on
    // when the list stops scrolling, so it is switched off again each time.
    component VolumeSlider: AudioSliderRow {
        id: volume

        Component.onCompleted: slider.wheelEnabled = false

        Connections {
            target: volume.slider
            function onWheelEnabledChanged() {
                if (volume.slider.wheelEnabled)
                    volume.slider.wheelEnabled = false;
            }
        }
    }

    // One slider for every stream of the app.
    component AppSlider: VolumeSlider {
        required property var app
        node: app.nodes[0] ?? null
        onSliderValueChanged: value => app.nodes.forEach(n => {
                n.audio.volume = value / 100;
                if (value > 0)
                    n.audio.muted = false;
            })
        onIconClicked: Qt.callLater(() => app.nodes.forEach(n => n.audio.muted = app.nodes[0].audio.muted))
    }

    // Fine sync: tells how late a device really sounds, so the other outputs of a
    // split app wait for it. Saved per device, used by every app.
    component SyncRow: Item {
        id: sync

        required property string device

        height: buttons.implicitHeight

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: {
                const ms = root.mixer?.offset(sync.device) ?? 0;
                return "Sync delay: " + (ms > 0 ? "+" : "") + ms + " ms";
            }
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
        Row {
            id: buttons
            anchors.right: parent.right
            DIconButton {
                widthMode: "narrow"
                iconName: "remove"
                tooltipText: "This device sounds earlier: -5 ms"
                onClicked: root.mixer?.shiftOffset(sync.device, -5)
            }
            DIconButton {
                widthMode: "narrow"
                iconName: "add"
                tooltipText: "This device sounds later: +5 ms"
                onClicked: root.mixer?.shiftOffset(sync.device, 5)
            }
        }
    }

    component Card: StyledRect {
        default property alias content: body.data

        implicitHeight: body.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: body
            x: Theme.spacingS
            y: Theme.spacingS
            width: parent.width - Theme.spacingS * 2
            spacing: Theme.spacingXS
        }
    }

    // Card title that folds the card; the folded state is kept by the daemon.
    // The expanded view opens every card and locks folding.
    component Header: Item {
        id: header

        required property string key
        property string text
        property string iconName
        property string iconSource: ""
        property string subtitle: ""
        readonly property bool locked: root.mixer?.expanded ?? false
        readonly property bool open: locked || !(root.mixer?.isCollapsed(key) ?? false)

        width: parent.width
        height: Math.max(Theme.iconSizeSmall, texts.implicitHeight) + Theme.spacingS

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            IconImage {
                visible: header.iconSource !== ""
                implicitSize: Theme.iconSizeSmall
                source: header.iconSource
            }
            DIcon {
                visible: header.iconSource === ""
                name: header.iconName
                size: Theme.iconSizeSmall
            }
            Column {
                id: texts
                anchors.verticalCenter: parent.verticalCenter
                width: header.width - Theme.iconSizeSmall * 2 - Theme.spacingS * 2

                StyledText {
                    width: parent.width
                    text: header.text
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    // StyledText wraps by default; names and titles stay on one line.
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }
                StyledText {
                    visible: header.subtitle !== "" && header.subtitle !== header.text
                    width: parent.width
                    text: header.subtitle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    // StyledText wraps by default; names and titles stay on one line.
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }
            }
        }
        DIcon {
            visible: !header.locked
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            name: header.open ? "expand_less" : "expand_more"
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
        }
        MouseArea {
            anchors.fill: parent
            enabled: !header.locked
            cursorShape: Qt.PointingHandCursor
            onClicked: root.mixer?.toggleCollapsed(header.key)
        }
    }

    // Folded, an app keeps its name and volume and hides device choice and extra outputs.
    // A split app that is not running only offers to forget its outputs.
    component AppCard: Card {
        id: card

        required property var modelData
        readonly property var app: modelData
        readonly property var devices: (app.playback ? root.mixer?.sinks : root.mixer?.sources) ?? []

        Header {
            id: header
            key: card.app.key
            text: card.app.name
            subtitle: card.app.title
            iconSource: card.app.icon
            iconName: card.app.iconName || (card.app.playback ? "music_note" : "mic")
        }

        Item {
            visible: !card.app.running
            width: parent.width
            height: forget.height

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Not running · " + card.app.outputs.length + " outputs saved"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
            DIconButton {
                id: forget
                anchors.right: parent.right
                iconName: "delete"
                tooltipText: "Forget outputs"
                onClicked: root.mixer?.forget(card.app.key)
            }
        }

        // With several outputs the app volume stays on top, each output below scales it.
        AppSlider {
            app: card.app
            visible: card.app.split && card.app.running
        }

        Repeater {
            model: ScriptModel {
                values: !card.app.running || card.app.split && !header.open ? [] : card.app.outputs
                objectProp: "id"
            }
            // Outputs of a split app sit indented on their own panels, tied to the app by an accent line.
            delegate: Item {
                id: output

                required property var modelData
                required property int index
                readonly property real inset: card.app.split ? Theme.spacingXS : 0
                // A saved device that is not connected stays listed under its own name.
                readonly property bool missing: modelData.device !== "" && !card.devices.some(n => n.name === modelData.device)

                x: card.app.split ? Theme.spacingM : 0
                width: (parent?.width ?? 0) - x
                height: rows.implicitHeight + inset * 2

                Rectangle {
                    visible: card.app.split
                    x: -Theme.spacingM / 2 - 1
                    y: -Theme.spacingXS
                    width: 2
                    height: parent.height + Theme.spacingXS
                    color: Theme.primary
                }
                Rectangle {
                    anchors.fill: parent
                    visible: card.app.split
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest
                }

                Column {
                    id: rows
                    x: output.inset
                    y: output.inset
                    width: parent.width - output.inset * 2

                    Row {
                        visible: header.open
                        width: parent.width
                        spacing: Theme.spacingS

                        DDropdown {
                            compactMode: true
                            dropdownWidth: parent.width - (button.visible ? button.width + Theme.spacingS : 0)
                            options: ["System default"].concat(card.devices.map(n => AudioService.displayName(n)), output.missing ? [(output.modelData.label || output.modelData.device) + " (not connected)"] : [])
                            optionValues: [""].concat(card.devices.map(n => n.name), output.missing ? [output.modelData.device] : [])
                            currentValue: output.modelData.device
                            // Picking an entry replaces the binding; restore it to follow the real device.
                            onValueChanged: value => {
                                root.mixer?.setOutput(card.app, output.modelData.id, value);
                                currentValue = Qt.binding(() => output.modelData.device);
                            }
                        }
                        DIconButton {
                            id: button
                            visible: card.app.playback
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: output.index === 0 ? "add" : "close"
                            tooltipText: output.index === 0 ? "Add output" : "Remove output"
                            onClicked: output.index === 0 ? root.mixer?.addOutput(card.app) : root.mixer?.removeOutput(card.app, output.modelData.id)
                        }
                    }

                    Loader {
                        width: parent.width
                        sourceComponent: card.app.split ? outputSlider : appSlider
                    }
                }

                Component {
                    id: appSlider
                    AppSlider {
                        app: card.app
                    }
                }
                Component {
                    id: outputSlider
                    VolumeSlider {
                        node: output.modelData.node
                    }
                }
            }
        }
    }
}
