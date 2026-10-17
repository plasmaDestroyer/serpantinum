import QtQuick
import Quickshell
import "widgets"

// Everything except the wallpaper. Shell.qml loads this file by URL so its
// types are compiled after the wallpaper is on screen, not before.
Scope {
    readonly property bool performanceMode: !!(Config.getSetting("general", {}).performance)
    readonly property bool quickactionsEnabled: Config.getSetting("general", {}).quickactions !== false
    readonly property bool dockEnabled: Config.getSetting("dock", {}).enabled !== false

    ScreenshotOverlay {}
    Main {}
    Bar {}
    Lock {}
    WidgetRedactor {}

    Launcher {}
    Overview {}
    Clipboard {}

    Polkit {}
    PopoutManager {}

    Loader {
        active: dockEnabled
        sourceComponent: Dock {}
    }

    Loader {
        active: !performanceMode
        sourceComponent: Idle {}
    }
    Variants {
        model: performanceMode ? [] : Quickshell.screens
        delegate: WidgetLoader {
            required property var modelData
            screen: modelData
            monitorName: modelData.name
        }
    }
    Loader {
        active: !performanceMode && quickactionsEnabled
        sourceComponent: Floating {}
    }
}
