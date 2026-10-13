import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import "../"

// Niri-style overview. The whole desktop (wallpaper + live windows) zooms out
// to `zoom` around the screen centre; workspaces are stacked top to bottom as
// full-size cards, columns scrolled off-screen stick out left/right.
// Slots are linked across monitors (slot n = ws n on HDMI, n+10 on eDP), so the
// selection moves on both screens together, like SUPER+1..0.
//   Up/Down, wheel, touchpad scroll: select workspace
//   Left/Right: select window     Enter / click: go there     Esc / backdrop: back
//   Middle click: close window    Drag window onto another workspace: move it
// Toggle: SUPER+O / 4-finger swipe up (global "quickshell:overviewToggle") or
// `serpantinum ipc call overview toggle`.
Scope {
    id: root

    readonly property real zoom: 0.5

    property bool open: false        // windows mapped
    property real progress: 0        // 0 = zoomed in (looks like the desktop), 1 = overview
    property bool ready: false       // previews had time to get their first frame
    property bool pendingOpen: false
    property var clients: []
    property var monitors: []

    property int sel: 0              // index into slots, shared by all monitors
    property int startSel: 0
    property string selAddr: ""      // selected window (on the focused monitor)

    readonly property bool shown: open && anim.to === 1
    readonly property string focusedMon: Hyprland.focusedMonitor?.name ?? ""
    // Bar slots 1-6, plus slot 7 (SUPER+0) when something lives there.
    readonly property var slots: clients.some(c => c.workspace.id === 7 || c.workspace.id === 17)
        ? [1, 2, 3, 4, 5, 6, 7] : [1, 2, 3, 4, 5, 6]

    function monFor(name) { return monitors.find(m => m.name === name) ?? null }
    function baseOf(mon) { return mon ? Math.floor((mon.activeWorkspace.id - 1) / 10) * 10 : 0 }
    function slotOf(id) { return (id - 1) % 10 + 1 }
    // Tiled + floating windows of workspace `id`, left to right.
    function winsOf(id) {
        return clients.filter(c => c.workspace.id === id).sort((a, b) => a.at[0] - b.at[0] || a.at[1] - b.at[1])
    }
    function focusedWins() {
        const m = monFor(focusedMon)
        return m ? winsOf(baseOf(m) + slots[sel]) : []
    }

    function refresh() { monitorsProc.running = true }  // then clientsProc
    function show() { if (shown) return; pendingOpen = true; refresh() }
    function toggle() { shown ? cancel() : show() }
    function close() { if (!open) return; anim.to = 0; anim.restart() }
    function cancel() { sel = startSel; close() }

    function select(i) {
        sel = Math.max(0, Math.min(slots.length - 1, i))
        const m = monFor(focusedMon)
        const ws = focusedWins()
        // window closest to the monitor's left edge = what you'd see there
        const pick = ws.reduce((best, c) => !best || Math.abs(c.at[0] - (m?.x ?? 0)) < Math.abs(best.at[0] - (m?.x ?? 0)) ? c : best, null)
        selAddr = pick ? pick.address : ""
    }
    function selectWindow(dir) {
        const ws = focusedWins()
        if (!ws.length) return
        const i = ws.findIndex(c => c.address === selAddr)
        selAddr = ws[Math.max(0, Math.min(ws.length - 1, (i < 0 ? 0 : i + dir)))].address
    }

    // Go to the selected slot on both monitors (+ selected window), then zoom in.
    function commit() {
        const slot = slots[sel]
        Hyprland.dispatch(`hl.dsp.focus({ workspace = "${slot}" })`)
        Hyprland.dispatch(`hl.dsp.focus({ workspace = "${slot + 10}" })`)
        if (focusedWins().some(c => c.address === selAddr))
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${selAddr}" })`)
        else if (focusedMon)
            Hyprland.dispatch(`hl.dsp.focus({ monitor = "${focusedMon}" })`)
        close()
    }

    NumberAnimation {
        id: anim
        target: root
        property: "progress"
        duration: 300
        easing.type: Easing.OutCubic
        onFinished: if (to === 0) { root.open = false; root.ready = false }
    }

    // Mapped but invisible for a moment so screencopies + wallpaper have a frame;
    // zoomed in the overview looks like the desktop, so the delay doesn't show.
    Timer {
        id: warmup
        interval: 100
        onTriggered: { root.ready = true; anim.to = 1; anim.restart() }
    }

    IpcHandler {
        target: "overview"
        function toggle(): void { root.toggle() }
        function open(): void { root.show() }
        function close(): void { root.cancel() }
    }

    GlobalShortcut {
        name: "overviewToggle"
        description: "Toggle the niri-style overview"
        onPressed: root.toggle()
    }

    Process {
        id: monitorsProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            onStreamFinished: { root.monitors = JSON.parse(text); clientsProc.running = true }
        }
    }
    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.clients = JSON.parse(text)
                if (!root.pendingOpen) return
                root.pendingOpen = false
                const m = root.monFor(root.focusedMon)
                root.startSel = Math.max(0, root.slots.indexOf(m ? root.slotOf(m.activeWorkspace.id) : 1))
                root.sel = root.startSel
                root.selAddr = "0x" + (Hyprland.activeToplevel?.address ?? "")
                root.progress = 0
                root.ready = false
                root.open = true
                anim.to = 1          // marks "shown" for toggle; the timer starts the zoom
                warmup.restart()
            }
        }
    }

    // ponytail: re-query hyprctl on window events while open; fine for a handful of windows.
    Connections {
        target: Hyprland
        function onRawEvent(ev) {
            if (root.shown && ["openwindow", "closewindow", "movewindow", "movewindowv2"].includes(ev.name))
                root.refresh()
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.open
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.namespace: "qs-overview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open && root.focusedMon === modelData.name
                ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            readonly property var mon: root.monFor(modelData.name)
            readonly property int base: root.baseOf(mon)
            readonly property real cardW: width * root.zoom
            readonly property real cardH: height * root.zoom
            readonly property real step: cardH + cardH * 0.12
            readonly property string wallpaper: {
                const p = Wallpaper.getWallpaperPath(modelData.name)
                return p && p.startsWith("/") ? "file://" + p : (p ?? "")
            }

            // Opaque from the first frame: zoomed in, the selected card (wallpaper +
            // live windows) covers the whole screen, so it looks like the desktop and
            // the real windows never show through while zooming.
            Rectangle {
                anchors.fill: parent
                // theme colours can carry alpha; force opaque or real windows show through
                color: Qt.rgba(ThemeBackend.crust.r, ThemeBackend.crust.g, ThemeBackend.crust.b, 1)
                visible: root.ready
            }

            onVisibleChanged: if (visible) keys.forceActiveFocus()

            // Keys + wheel + backdrop click.
            Item {
                id: keys
                anchors.fill: parent
                focus: true
                Keys.onPressed: e => {
                    if (!root.shown) return
                    if (e.key === Qt.Key_Up) root.select(root.sel - 1)
                    else if (e.key === Qt.Key_Down) root.select(root.sel + 1)
                    else if (e.key === Qt.Key_Left) root.selectWindow(-1)
                    else if (e.key === Qt.Key_Right) root.selectWindow(1)
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) root.commit()
                    else if (e.key === Qt.Key_Escape) root.cancel()
                    else return
                    e.accepted = true
                }

                MouseArea {
                    anchors.fill: parent
                    property real acc: 0
                    onClicked: root.cancel()
                    onWheel: w => {
                        acc += w.angleDelta.y
                        if (Math.abs(acc) >= 120) {
                            root.select(root.sel + (acc > 0 ? -1 : 1))
                            acc = 0
                        }
                    }
                }
            }

            // Zoom: scale 1/zoom around the centre makes the selected card fill the screen.
            Item {
                id: stage
                anchors.fill: parent
                opacity: root.ready ? 1 : 0
                transform: Scale {
                    origin.x: win.width / 2
                    origin.y: win.height / 2
                    xScale: (1 / root.zoom) * (1 - root.progress) + root.progress
                    yScale: xScale
                }

                Item {
                    id: rows
                    x: (win.width - win.cardW) / 2
                    width: win.cardW
                    // selected card centred vertically
                    y: (win.height - win.cardH) / 2 - root.sel * win.step
                    Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                    Repeater {
                        model: root.slots

                        Item {
                            id: card
                            required property int modelData
                            required property int index
                            readonly property int wsId: win.base + modelData
                            readonly property bool selected: index === root.sel

                            y: index * win.step
                            width: win.cardW
                            height: win.cardH

                            Image {
                                anchors.fill: parent
                                source: win.wallpaper
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: false
                                sourceSize.width: win.width / 2
                                opacity: card.selected ? 1 : 1 - 0.45 * root.progress
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: root.shown
                                onClicked: { root.select(card.index); root.commit() }
                            }

                            Text {
                                anchors { left: parent.left; bottom: parent.top; bottomMargin: 6 }
                                text: card.modelData === 7 ? 0 : card.modelData
                                color: card.selected ? ThemeBackend.mauve : ThemeBackend.subtext0
                                opacity: root.progress
                                font.pixelSize: 14
                                font.bold: card.selected
                            }

                            // Tiles only exist while open: Hyprland 0.56 window capture
                            // doesn't clear its reused buffers, so long-lived previews of
                            // translucent windows (ghostty) showed stale frames through.
                            Repeater {
                                model: root.open ? root.winsOf(card.wsId) : []

                                Rectangle {
                                    id: tile
                                    required property var modelData
                                    readonly property var toplevel: ToplevelManager.toplevels.values
                                        .find(t => "0x" + t.HyprlandToplevel?.address === modelData.address) ?? null
                                    readonly property bool picked: modelData.address === root.selAddr && win.modelData.name === root.focusedMon

                                    x: (modelData.at[0] - (win.mon?.x ?? 0)) * root.zoom
                                    y: (modelData.at[1] - (win.mon?.y ?? 0)) * root.zoom
                                    width: modelData.size[0] * root.zoom
                                    height: modelData.size[1] * root.zoom
                                    z: area.drag.active ? 10 : 0
                                    color: ThemeBackend.surface0

                                    Text {
                                        anchors.centerIn: parent
                                        width: parent.width - 8
                                        text: tile.modelData.class
                                        color: ThemeBackend.text
                                        elide: Text.ElideRight
                                        horizontalAlignment: Text.AlignHCenter
                                    }

                                    ScreencopyView {
                                        anchors.fill: parent
                                        captureSource: root.open ? tile.toplevel : null
                                        live: true
                                    }

                                    // selection ring, drawn outside the window
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: -3
                                        color: "transparent"
                                        radius: 4
                                        border.width: 3
                                        border.color: ThemeBackend.mauve
                                        visible: tile.picked
                                        opacity: root.progress
                                    }

                                    MouseArea {
                                        id: area
                                        property bool dragged: false
                                        anchors.fill: parent
                                        enabled: root.shown
                                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                        drag.target: tile
                                        onPressed: dragged = false
                                        onPositionChanged: if (drag.active) dragged = true
                                        onReleased: mouse => {
                                            const addr = tile.modelData.address
                                            if (mouse.button === Qt.MiddleButton) {
                                                Hyprland.dispatch(`hl.dsp.window.close({ window = "address:${addr}" })`)
                                            } else if (!dragged) {
                                                root.sel = card.index
                                                root.selAddr = addr
                                                root.commit()
                                            } else {
                                                const p = tile.mapToItem(rows, tile.width / 2, tile.height / 2)
                                                const i = Math.floor((p.y + (win.step - win.cardH) / 2) / win.step)
                                                if (i >= 0 && i < root.slots.length && i !== card.index)
                                                    Hyprland.dispatch(`hl.dsp.window.move({ workspace = "${win.base + root.slots[i]}", follow = false, window = "address:${addr}" })`)
                                                root.refresh() // rebuilds tiles, snapping a dropped-nowhere tile back
                                            }
                                        }
                                    }
                                }
                            }

                            // selected-workspace outline
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: -4
                                color: "transparent"
                                border.width: 2
                                border.color: ThemeBackend.mauve
                                visible: card.selected
                                opacity: root.progress * 0.8
                            }
                        }
                    }
                }
            }
        }
    }
}
