import QtQuick
import Quickshell
import Quickshell.Io
import "../../../reusables"
import "../../../"

// AirDrop receive toggle. Runs ~/.local/bin/airdrop (owly radio + receive into ~/Downloads).
// off → click → starting (radio coming up, label breathes) → ready (listening) → a transfer lands, the script
// stops itself → "Received". A stop nobody asked for (failed start, crash) → "Stopped".
// Same ClickButton chip as the wifi / bt / vol pills.
Item {
    id: root

    property var module: null
    property var widget: module

    // As the sibling faces: the guide's preview passes `widget` with isPreview set.
    readonly property var activeTarget: widget || module
    property string orientation: (activeTarget && activeTarget.orientation !== undefined) ? activeTarget.orientation : "horizontal"
    readonly property bool isVertical: orientation === "vertical"
    readonly property bool isCompact: activeTarget ? Boolean(activeTarget.isCompact) : false
    readonly property var barWindow: activeTarget ? activeTarget.barWindow : null
    readonly property bool isPreview: activeTarget ? Boolean(activeTarget.isPreview) : false

    function s(v) { return barWindow ? barWindow.cs(v) : v; }

    // "off" | "starting" | "on" | "received" | "stopped"
    property string mode: "off"
    readonly property bool active: mode === "starting" || mode === "on"
    readonly property bool flashing: mode === "received" || mode === "stopped"
    property bool draining: false     // the script is still cleaning up: its "starting" is not a new start
    property real ignorePollUntil: 0  // a click's own state wins over a poll that raced it
    property bool pendingStart: false // clicked while the old script cleaned up: start once it's gone
    property real breath: 0           // starting: the label brightens 0..1 towards lavender and back; never dims

    readonly property bool hovered: pill.isHoveredOrHighlighted
    readonly property string word: mode === "on" ? "Ready"
        : mode === "starting" ? "Starting"
        : mode === "received" ? "Received"
        : mode === "stopped" ? "Stopped" : ""

    function flash(m) {
        mode = m;
        draining = true;
        flashTimer.restart();
        if (m === "received") pop.restart();
    }

    function setMode(m) {
        if (m === "off") {
            draining = false;
            if (pendingStart) { pendingStart = false; return start(); }
        }
        if (flashing || draining) return;  // until the old script is gone, nothing it shows is news
        if (mode === "on" && m !== "on") return flash("stopped");          // receiver died, nothing came in
        if (mode === "starting" && m === "off") return flash("stopped");   // radio never came up
        if (mode === "starting" && m === "on") pop.restart();  // the accent fills in, once
        mode = m;
    }

    function toggle() {
        if (isPreview) return;  // a settings preview never touches the radio
        if (mode === "received") {  // the check is a door to what just arrived
            Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/Downloads"]);
            return;
        }
        if (active) {
            ignorePollUntil = Date.now() + 1500;
            draining = true;
            pendingStart = false;
            mode = "off";
            Quickshell.execDetached(["sh", "-c", "pkill -f '^owly [r]eceive'; pkill -f '^bash [^ ]*bin/[a]irdrop'"]);
        } else if (draining) {
            pendingStart = true;  // the old script still holds the radio
            mode = "starting";    // show the click landed; the poll starts it once the old one is gone
            flashTimer.stop();
            pendingTimer.restart();
        } else {
            start();
        }
    }

    function start() {
        ignorePollUntil = Date.now() + 1500;
        flashTimer.stop();
        draining = false;
        mode = "starting";
        Quickshell.execDetached([Quickshell.env("HOME") + "/.local/bin/airdrop", "--accept"]);
    }

    // ponytail: polls every 1 s; a status file or D-Bus signal would be instant.
    // Exit 3 = the script left its "something arrived" marker (proof for "Received").
    Process {
        id: check
        command: ["sh", "-c", "f=${XDG_RUNTIME_DIR:-/tmp}/airdrop-received; [ -e \"$f\" ] && rm -f \"$f\" && exit 3; pgrep -f '^owly [r]eceive' >/dev/null && exit 0; pgrep -f '^bash [^ ]*bin/[a]irdrop' >/dev/null && exit 1; exit 2"]
        onExited: code => {
            if (code === 3) return root.flash("received");
            if (Date.now() < root.ignorePollUntil) return;
            root.setMode(code === 0 ? "on" : (code === 1 ? "starting" : "off"));
        }
    }
    Timer {
        interval: 1000
        running: !root.isPreview
        repeat: true
        triggeredOnStart: true
        onTriggered: check.running = true
    }
    Timer {
        id: pendingTimer  // the old script never let go: give up the queued start rather than show Starting forever
        interval: 10000
        onTriggered: if (root.pendingStart) { root.pendingStart = false; root.flash("stopped"); }
    }
    Timer {
        id: flashTimer
        interval: 2600
        onTriggered: root.mode = "off"
    }
    SequentialAnimation {
        running: root.mode === "starting"
        loops: Animation.Infinite
        onRunningChanged: running ? breathOut.stop() : breathOut.restart()  // never two writers on breath
        NumberAnimation { target: root; property: "breath"; to: 1; duration: 650; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "breath"; to: 0; duration: 650; easing.type: Easing.InOutSine }
    }

    NumberAnimation { id: breathOut; target: root; property: "breath"; to: 0; duration: 150; easing.type: Easing.OutCubic }

    // Grouped (compact) pills lighten their colours, as the wifi / bt / vol faces do.
    function c(col) { return isCompact ? Qt.lighter(col, 1.08) : col; }
    readonly property color surface: isCompact ? Qt.lighter(ThemeBackend.surface0, 1.18) : ThemeBackend.surface0

    // The label: restColor follows the state and is the only colour that eases (with ClickButton's fill); the
    // breath is a brightening layered on top every frame, never through a Behavior (a Behavior restarted every
    // frame never moves). Brightening only, so contrast never drops below the resting colour's.
    property color restColor: (mode === "on" || mode === "received") ? ThemeBackend.base
        : mode === "starting" ? c(ThemeBackend.blue)
        : mode === "stopped" ? c(ThemeBackend.subtext0)
        : (isCompact ? Qt.lighter(ThemeBackend.text, 1.05) : ThemeBackend.text)
    Behavior on restColor { ColorAnimation { duration: 150 } }

    // One width for every labelled state (the widest real word), so the pill doesn't jump between words.
    TextMetrics { id: wStarting; font.family: ThemeBackend.fontFamily; font.weight: Font.Bold; font.pixelSize: pill.textFontSize; text: "Starting" }
    TextMetrics { id: wReceived; font.family: ThemeBackend.fontFamily; font.weight: Font.Bold; font.pixelSize: pill.textFontSize; text: "Received" }
    readonly property real chipWidth: pill.buttonText !== ""
        ? pill.desiredWidth - pill.rawTextWidth + Math.ceil(Math.max(wStarting.advanceWidth, wReceived.advanceWidth))
        : pill.desiredWidth

    // The host pill and the chip share one target and one clock (BarModule: 250 ms OutCubic).
    property real targetLength: chipWidth + s(isCompact ? 8 : 10)
    implicitWidth: isVertical ? (activeTarget && activeTarget.thickness ? activeTarget.thickness : pill.height) : targetLength
    implicitHeight: isVertical ? pill.height + s(isCompact ? 8 : 10) : (activeTarget && activeTarget.thickness ? activeTarget.thickness : pill.height)

    ClickButton {
        id: pill
        anchors.centerIn: parent
        height: s(root.isCompact ? 28 : 30)
        cornerRadius: Math.max(0, ThemeBackend.borderRadius - s(2))
        horizontalPadding: s(root.isCompact ? 10 : 12)
        contentSpacing: s(8)
        contentAlignment: Qt.AlignLeft  // the glyph never moves between states; only the word changes
        // Hover swaps the glyph to what a click does (stop-circle outline / open the folder); the word stays, nothing reflows.
        buttonIcon: (root.active && root.hovered) ? "󰙧"
            : root.mode === "received" ? (root.hovered ? "󰉋" : "󰄬") : "󰀃"
        iconFontSize: s(root.isCompact ? 14 : 15)
        buttonText: root.isVertical ? "" : root.word
        textFontSize: s(root.isCompact ? 11 : 12)

        // off: house surface chip · starting: faint accent · ready: accent (as wifi on)
        // received: bright chip (as the battery) · stopped: surface again
        accentColor: root.mode === "on" ? root.c(ThemeBackend.blue)
            : root.mode === "received" ? root.c(ThemeBackend.text)
            : root.mode === "starting" ? Qt.tint(root.surface, Qt.rgba(ThemeBackend.blue.r, ThemeBackend.blue.g, ThemeBackend.blue.b, 0.26))
            : root.surface
        textColor: Qt.tint(root.restColor, Qt.rgba(1, 1, 1, 0.35 * root.breath))

        width: root.chipWidth
        // Clip only while the label is revealed: a standing clip flattens the ends of the 1.015 hover scale.
        clip: widthAnim.running
        Behavior on width { NumberAnimation { id: widthAnim; duration: 250; easing.type: Easing.OutCubic } }

        onClicked: root.toggle()

        SequentialAnimation {
            id: pop
            // scale, not ClickButton's popScale: popScale grows the shape past the chip's own clip
            NumberAnimation { target: pill; property: "scale"; to: 1.03; duration: 120; easing.type: Easing.OutQuad }
            NumberAnimation { target: pill; property: "scale"; to: 1.0; duration: 420; easing.type: Easing.OutQuint }
        }
    }
}
