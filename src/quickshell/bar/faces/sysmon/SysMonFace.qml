import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import "../../../reusables"
import "../../../"

Item {
    id: root

    property var module: null
    property var widget: module

    readonly property var activeTarget: widget || module
    readonly property bool isCompact: activeTarget ? activeTarget.isCompact : false
    readonly property var barWindow: activeTarget ? activeTarget.barWindow : null

    property int configRevision: 0

    Connections {
        target: (typeof Config !== "undefined") ? Config : null
        function onSettingsLoaded() { root.configRevision++; }
        function onRawSettingsChanged() { root.configRevision++; }
    }

    property string circleStyle: {
        if (widget && widget !== root && widget.sysmonStyle !== undefined) return widget.sysmonStyle;
        if (module && module.sysmonStyle !== undefined) return module.sysmonStyle;
        let dummy = configRevision;
        if (typeof Config !== "undefined" && Config.rawSettings && Config.rawSettings.bar) {
            let bs = Config.rawSettings.bar;
            if (bs.sysmonStyle) return bs.sysmonStyle;
            if (bs.sysmon && bs.sysmon.style) return bs.sysmon.style;
        }
        return "wave";
    }

    readonly property bool useSineWave: circleStyle !== "circle"

    property var activeStats: {
        if (widget && widget !== root && widget.sysmonStats !== undefined) return widget.sysmonStats;
        if (module && module.sysmonStats !== undefined) return module.sysmonStats;
        let dummy = configRevision;
        if (typeof Config !== "undefined" && Config.rawSettings && Config.rawSettings.bar) {
            let bs = Config.rawSettings.bar;
            if (Array.isArray(bs.sysmonStats)) return bs.sysmonStats;
            if (bs.sysmon && Array.isArray(bs.sysmon.stats)) return bs.sysmon.stats;
            if (bs.sysmonShowCpu !== undefined || bs.sysmonShowRam !== undefined || bs.sysmonShowTemp !== undefined || bs.sysmonShowDisk !== undefined) {
                let stats = [];
                if (bs.sysmonShowCpu !== false) stats.push("cpu");
                if (bs.sysmonShowRam !== false) stats.push("ram");
                if (bs.sysmonShowTemp !== false) stats.push("temp");
                if (bs.sysmonShowDisk === true) stats.push("disk");
                return stats;
            }
        }
        return ["cpu", "ram", "temp"];
    }

    property bool showLayout: (!barWindow || (root.activeTarget && root.activeTarget.isPreview)) ? true : false
    property int circleSize: barWindow ? barWindow.s(isCompact ? 22 : 28) : (isCompact ? 22 : 28)

    property bool isSysVisible: (!activeTarget || activeTarget.moduleActive) && showLayout
    property color basePrimary: (ThemeBackend.primary !== undefined && ThemeBackend.primary !== "") ? ThemeBackend.primary : ThemeBackend.mauve

    property bool isSubscribed: false

    function updateSubscription() {
        if (isSysVisible && !isSubscribed) {
            isSubscribed = true;
            SysData.subscribe();
        } else if (!isSysVisible && isSubscribed) {
            isSubscribed = false;
            SysData.unsubscribe();
        }
    }

    Component.onCompleted: updateSubscription()
    Component.onDestruction: {
        if (isSubscribed) {
            isSubscribed = false;
            SysData.unsubscribe();
        }
    }
    onIsSysVisibleChanged: updateSubscription()

    property real targetWidth: ((!activeTarget || activeTarget.moduleActive) && sysLayout.implicitWidth > 0) ? (sysLayout.implicitWidth + (barWindow ? barWindow.s(isCompact ? 8 : 10) : (isCompact ? 8 : 10))) : 0
    property bool isFaceVisible: showLayout && targetWidth > 0

    implicitWidth: targetWidth
    implicitHeight: parent ? parent.height : 0

    Timer {
        running: (!activeTarget || activeTarget.moduleActive) && barWindow && barWindow.isStartupReady && barWindow.isDataReady && !root.showLayout
        interval: 100
        onTriggered: root.showLayout = true
    }

    transform: Translate {
        x: root.showLayout ? 0 : (barWindow ? barWindow.s(60) : 60)
        Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
    }

    component SysMonCircle: Rectangle {
        id: circleRoot
        property real value: 0
        property string textVal: ""
        property string icon: ""
        property color accentColor: root.basePrimary
        property bool showText: textVal !== ""
        property bool useSineWave: root.useSineWave
        property bool initAnimTrigger: (!barWindow || !!(root.activeTarget && root.activeTarget.isPreview))

        property real animValue: initAnimTrigger ? value : 0
        // ponytail: snap instead of animating; a 600ms tween per poll repainted the Canvas every frame (~30% shell CPU)

        property real fillRatio: Math.max(0.0, Math.min(1.0, isNaN(animValue) ? 0.0 : animValue))

        implicitWidth: root.circleSize
        implicitHeight: root.circleSize
        width: implicitWidth
        height: implicitHeight
        radius: width / 2
        color: "transparent"
        border.width: 0

        Timer {
            running: (!activeTarget || activeTarget.moduleActive) && root.showLayout && !initAnimTrigger
            interval: 150
            onTriggered: initAnimTrigger = true
        }

        opacity: initAnimTrigger ? 1.0 : 0.0
        transform: Translate {
            y: initAnimTrigger ? 0 : (barWindow ? barWindow.s(15) : 15)
            Behavior on y { NumberAnimation { duration: 620; easing.type: Easing.OutQuint } }
        }
        Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

        ShaderEffect {
            id: circleGauge
            anchors.fill: parent

            property vector2d itemSize: Qt.vector2d(width, height)
            property real fillRatio: circleRoot.fillRatio
            property real strokeWidth: barWindow ? barWindow.s(2.2) : 2.2
            property real useSineWave: circleRoot.useSineWave ? 1.0 : 0.0
            property color accentColor: circleRoot.accentColor
            property vector4d params: Qt.vector4d(barWindow ? barWindow.s(0.9) : 0.9, 0.0, 0.0, 0.0)

            fragmentShader: "file://" + Caching.serpantinumDir + "/assets/shaders/gauges/circular_wave_gauge.frag.qsb"
        }

        Text {
            anchors.centerIn: parent
            text: circleRoot.showText ? circleRoot.textVal : circleRoot.icon
            font.pixelSize: Math.round(circleRoot.showText
                ? (barWindow ? barWindow.s(root.isCompact ? 7.5 : 9) : (root.isCompact ? 7.5 : 9))
                : (barWindow ? barWindow.s(root.isCompact ? 9 : 11) : (root.isCompact ? 9 : 11)))
            font.bold: circleRoot.showText
            font.family: circleRoot.showText
                ? ((ThemeBackend.fontFamily !== undefined && ThemeBackend.fontFamily !== "") ? ThemeBackend.fontFamily : "sans-serif")
                : ThemeBackend.iconFont
            color: (ThemeBackend.text !== undefined && ThemeBackend.text !== "") ? ThemeBackend.text : "#ffffff"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Local: style "pill" = the pre-2.2 look (icon + value in a filled pill), drawn with plain
    // Rectangles instead of a Canvas: no per-frame repaints, nothing to miss while hidden.
    readonly property bool usePills: circleStyle === "pill"
    property int pillHeight: barWindow ? barWindow.s(isCompact ? 28 : 30) : (isCompact ? 28 : 30)
    property int pillWidth: barWindow ? barWindow.s(isCompact ? 48 : 52) : (isCompact ? 48 : 52)

    component PillLabel: Row {
        property string icon
        property string textVal
        property color iconColor
        property color valueColor
        spacing: barWindow ? barWindow.s(root.isCompact ? 3 : 4) : (root.isCompact ? 3 : 4)
        Text {
            text: parent.icon
            font.family: ThemeBackend.fontFamily
            font.pixelSize: barWindow ? barWindow.s(root.isCompact ? 13.5 : 14.5) : (root.isCompact ? 13.5 : 14.5)
            color: parent.iconColor
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: parent.textVal
            font.family: ThemeBackend.fontFamily
            font.pixelSize: barWindow ? barWindow.s(root.isCompact ? 12 : 13) : (root.isCompact ? 12 : 13)
            font.bold: true
            color: parent.valueColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    component SysMonPill: Rectangle {
        id: pillRoot
        property real value: 0
        property string textVal: ""
        property string icon: ""
        property color accentColor: ThemeBackend.mauve
        property bool initAnimTrigger: (!barWindow || !!(root.activeTarget && root.activeTarget.isPreview))

        property real fillRatio: Math.max(0.0, Math.min(1.0, isNaN(value) ? 0.0 : value))
        // Static wave on the fill's top edge (the old pill's curve, phase 0); flat when empty/full.
        property real fillY: height * (1.0 - fillRatio)
        property real waveAmp: (fillRatio < 0.99 && fillRatio > 0.01) ? (barWindow ? barWindow.s(3.75) : 3.75) * Math.sin(fillRatio * Math.PI) : 0
        // no tween: animating every poll keeps the compositor redrawing (measured ~42% shell / 28% Hyprland CPU)

        height: root.pillHeight
        width: root.pillWidth
        radius: Math.min(Math.max(0, ThemeBackend.borderRadius - (barWindow ? barWindow.s(2) : 2)), height / 2)
        color: root.isCompact ? Qt.lighter(ThemeBackend.surface0, 1.18) : ThemeBackend.surface0
        border.color: root.isCompact ? ThemeBackend.surface2 : ThemeBackend.surface1
        border.width: 1

        Timer {
            running: (!activeTarget || activeTarget.moduleActive) && root.showLayout && !initAnimTrigger
            interval: 150
            onTriggered: initAnimTrigger = true
        }

        opacity: initAnimTrigger ? 1.0 : 0.0
        transform: Translate {
            y: initAnimTrigger ? 0 : (barWindow ? barWindow.s(15) : 15)
            Behavior on y { NumberAnimation { duration: 620; easing.type: Easing.OutQuint } }
        }
        Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

        PillLabel {
            // same whole-pixel position as the dark slices below, so the two copies line up
            x: Math.round((pillRoot.width - implicitWidth) / 2)
            y: Math.round((pillRoot.height - implicitHeight) / 2)
            icon: pillRoot.icon
            textVal: pillRoot.textVal
            iconColor: root.isCompact ? ThemeBackend.text : ThemeBackend.subtext0
            valueColor: ThemeBackend.text
        }

        // Fill: one Shape whose path is the rounded pill cut at the (static) wave line.
        // No mask/layer (those re-rendered constantly and gave hard, jagged corners);
        // CurveRenderer antialiases the curves at full resolution.
        // Rounded pill cut at a wave line through y. The wave is a tapered sine (zero at
        // both sides, so it always meets the rounded outline); shift moves its crest.
        function pillPath(y, amp, shift) {
            const w = width, h = height;
            const r = Math.max(0, Math.min(radius, h / 2, w / 2));
            if (w <= 0 || h <= 0 || y >= h) return "";
            y = Math.max(0, y);
            const inset = yy => yy < r ? r - Math.sqrt(Math.max(0, r * r - (r - yy) * (r - yy)))
                              : yy > h - r ? r - Math.sqrt(Math.max(0, r * r - (yy - (h - r)) * (yy - (h - r)))) : 0;
            const xl = inset(y), xr = w - xl, span = xr - xl, n = 16;
            let p = `M ${xl} ${y} `;
            for (let k = 1; k <= n; k++) {
                const t = k / n;
                p += `L ${xl + span * t} ${y - amp * Math.sin(Math.PI * t) * Math.cos(2 * Math.PI * (t - 0.3 - shift))} `;
            }
            if (y < r) p += `A ${r} ${r} 0 0 1 ${w} ${r} `;
            if (y <= h - r) p += `L ${w} ${h - r} `;
            p += `A ${r} ${r} 0 0 1 ${w - r} ${h} L ${r} ${h} `;
            if (y <= h - r) {
                p += `A ${r} ${r} 0 0 1 0 ${h - r} `;
                p += y < r ? `L 0 ${r} A ${r} ${r} 0 0 1 ${xl} ${y} ` : `L 0 ${y} `;
            } else {
                p += `A ${r} ${r} 0 0 1 ${xl} ${y} `;
            }
            return p + "Z";
        }
        property string fillPath: pillPath(fillY, waveAmp, 0)
        // second, "further away" wave: crest shifted right, a bit higher, darker and faint
        property string backPath: pillPath(fillY - (barWindow ? barWindow.s(2.5) : 2.5), waveAmp * 0.8, 0.35)

        Shape {
            anchors.fill: parent
            visible: pillRoot.fillRatio > 0
            preferredRendererType: Shape.CurveRenderer
            opacity: 0.45
            ShapePath {
                strokeWidth: -1
                fillColor: Qt.darker(pillRoot.accentColor, 1.35)
                PathSvg { path: pillRoot.backPath }
            }
        }

        Shape {
            anchors.fill: parent
            visible: pillRoot.fillRatio > 0
            preferredRendererType: Shape.CurveRenderer
            opacity: 0.95
            ShapePath {
                strokeWidth: -1
                fillGradient: LinearGradient {
                    x1: 0; y1: 0; x2: 0; y2: pillRoot.height
                    GradientStop { position: 0.0; color: Qt.lighter(pillRoot.accentColor, 1.25) }
                    GradientStop { position: 1.0; color: pillRoot.accentColor }
                }
                PathSvg { path: pillRoot.fillPath }
            }
        }

        // Dark copy of the label only where the FRONT wave fill is: 16 thin slices, each
        // clipped to the wave height at its centre (rectangular clips, no mask/layer).
        // Text over the back wave / empty area keeps the light colour.
        function frontWaveY(t) {
            return fillY - waveAmp * Math.sin(Math.PI * t) * Math.cos(2 * Math.PI * (t - 0.3));
        }
        Repeater {
            model: pillRoot.fillRatio > 0 ? 16 : 0
            Item {
                readonly property real sliceW: pillRoot.width / 16
                x: index * sliceW
                y: Math.max(0, Math.min(pillRoot.height, pillRoot.frontWaveY((index + 0.5) / 16)))
                width: sliceW + 0.5
                height: pillRoot.height - y
                clip: true

                PillLabel {
                    x: Math.round((pillRoot.width - implicitWidth) / 2) - parent.x
                    y: Math.round((pillRoot.height - implicitHeight) / 2) - parent.y
                    icon: pillRoot.icon
                    textVal: pillRoot.textVal
                    iconColor: Qt.rgba(ThemeBackend.crust.r, ThemeBackend.crust.g, ThemeBackend.crust.b, 0.75)
                    valueColor: ThemeBackend.crust
                }
            }
        }
    }

    Row {
        id: sysLayout
        anchors.centerIn: parent
        spacing: barWindow ? barWindow.s(root.isCompact ? 5 : 6) : (root.isCompact ? 5 : 6)
        property int circleSize: root.circleSize

        Repeater {
            model: root.usePills ? root.activeStats : []

            SysMonPill {
                readonly property string statType: modelData
                value: {
                    if (statType === "cpu") return isNaN(SysData.cpu) ? 0 : SysData.cpu / 100.0;
                    if (statType === "ram") return isNaN(SysData.ramPercent) ? 0 : SysData.ramPercent / 100.0;
                    if (statType === "temp") return isNaN(SysData.temp) ? 0 : Math.max(0, Math.min(1, SysData.temp / 100.0));
                    if (statType === "disk") return isNaN(SysData.diskPercent) ? 0 : SysData.diskPercent / 100.0;
                    return 0;
                }
                textVal: {
                    if (statType === "cpu") return (isNaN(SysData.cpu) ? 0 : Math.round(SysData.cpu)) + "%";
                    if (statType === "ram") return (isNaN(SysData.ramPercent) ? 0 : Math.round(SysData.ramPercent)) + "%";
                    if (statType === "temp") return (isNaN(SysData.temp) ? 0 : Math.round(SysData.temp)) + "°";
                    if (statType === "disk") return (isNaN(SysData.diskPercent) ? 0 : Math.round(SysData.diskPercent)) + "%";
                    return "";
                }
                icon: {
                    if (statType === "cpu") return String.fromCodePoint(0xF2DB);
                    if (statType === "ram") return "󰍛";
                    if (statType === "temp") return String.fromCodePoint(0xF2C9);
                    if (statType === "disk") return String.fromCodePoint(0xF0A0);
                    return "";
                }
                accentColor: {
                    if (statType === "cpu") return ThemeBackend.mauve;
                    if (statType === "ram") return ThemeBackend.sapphire;
                    if (statType === "temp") return ThemeBackend.red;
                    return ThemeBackend.peach;
                }
            }
        }

        Repeater {
            model: root.usePills ? [] : root.activeStats

            SysMonCircle {
                readonly property string statType: modelData
                value: {
                    if (statType === "cpu") return isNaN(SysData.cpu) ? 0 : SysData.cpu / 100.0;
                    if (statType === "ram") return isNaN(SysData.ramPercent) ? 0 : SysData.ramPercent / 100.0;
                    if (statType === "temp") return isNaN(SysData.temp) ? 0 : Math.max(0, Math.min(1, SysData.temp / 100.0));
                    if (statType === "disk") return isNaN(SysData.diskPercent) ? 0 : SysData.diskPercent / 100.0;
                    return 0;
                }
                textVal: {
                    if (statType === "temp") return isNaN(SysData.temp) ? "0" : Math.round(SysData.temp).toString();
                    return "";
                }
                icon: {
                    if (statType === "cpu") return String.fromCodePoint(0xF035B);
                    if (statType === "ram") return String.fromCodePoint(0xF035C);
                    if (statType === "temp") return String.fromCodePoint(0xF050F);
                    if (statType === "disk") return String.fromCodePoint(0xF0A0);
                    return "";
                }
                accentColor: {
                    if (statType === "cpu") return Qt.tint(root.basePrimary, Qt.rgba(1.0, 0.22, 0.22, 0.25));
                    if (statType === "ram") return Qt.lighter(root.basePrimary, 1.15);
                    if (statType === "temp") return Qt.darker(root.basePrimary, 1.15);
                    if (statType === "disk") return Qt.darker(root.basePrimary, 1.35);
                    return root.basePrimary;
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        enabled: !(root.activeTarget && root.activeTarget.isPreview)
        onClicked: {
            FloatingController.showSystemUsage(root.barWindow ? root.barWindow.screen : null);
        }
    }
}
