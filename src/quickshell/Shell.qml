import QtQuick
import Quickshell
import "widgets"

ShellRoot {
    readonly property bool performanceMode: !!(Config.getSetting("general", {}).performance)

    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup() }
        function onReloadFailed(errorString) { Quickshell.inhibitReloadPopup() }
    }

    // Only the wallpaper loads up front, so it maps ~150ms after start instead
    // of waiting ~700ms for every module. LazyLoader compiles its source the
    // moment `source` is set, so set it from a timer, after this file loads.
    Loader {
        active: !performanceMode
        sourceComponent: WallpaperEngine {}
    }

    LazyLoader { id: modules }

    Timer {
        running: true
        onTriggered: {
            modules.source = "Modules.qml";
            modules.activeAsync = true;
        }
    }

    Component.onCompleted: {
        Qt.application.organization = "serpantinum";
        Qt.application.domain = "serpantinum.org";
        Qt.application.name = "serpantinum";
        FirstLaunch.checkFirstLaunch();
        SysNotif.checkBattery();
    }
}
