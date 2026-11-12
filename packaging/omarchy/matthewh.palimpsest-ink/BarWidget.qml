import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Optional Omarchy bar control for the palimpsest-ink daemon.
// Left click toggles annotation, middle click pastes, right click opens the menu.
BarWidget {
  id: root
  moduleName: "matthewh.palimpsest-ink"

  property bool annotating: false
  property string ink: "#FF3B30FF"
  property bool daemonUp: false
  property bool popupOpen: false
  property var menu: ({
    annotating: false,
    strokes: 0,
    ink: "#FF3B30FF",
    palette: [],
    windows: [],
    pasteTarget: "previousApp",
    pasteOverride: null,
    pasteTitle: "Previous window",
    palettePosition: "topRight",
    action: "copyAndPaste",
    pasteShown: true
  })

  readonly property string ctl: {
    var home = Quickshell.env("HOME") || ""
    return home + "/.local/bin/palimpsestctl"
  }

  readonly property color inkColor: qmlColor(ink)
  readonly property var paletteItems: menu && menu.palette ? menu.palette : []
  readonly property var windowItems: menu && menu.windows ? menu.windows : []
  readonly property var historyItems: {
    var list = menu && menu.history ? menu.history : []
    if (!list || !list.length) return []
    var out = []
    var n = Math.min(10, list.length)
    for (var i = 0; i < n; i++) out.push(list[i])
    return out
  }
  readonly property var extraItems: {
    var list = menu && menu.extras ? menu.extras : []
    return list && list.length ? list : []
  }
  readonly property string folderPath: menu && menu.folder ? String(menu.folder) : ""
  readonly property string hotkeyCaption: {
    if (menu && menu.hotkey !== undefined && menu.hotkey !== null && String(menu.hotkey) !== "")
      return String(menu.hotkey)
    return "Super+Alt+D"
  }
  // Hide only if menu JSON later reports the picker as missing.
  readonly property bool showColourPicker: {
    if (!menu) return true
    if (menu.picker === false || menu.hyprpicker === false) return false
    return true
  }
  readonly property bool pastePinned: !!(menu && menu.pasteOverride)
  readonly property bool copyAndPaste: {
    if (!menu) return false
    if (menu.pasteShown === true) return true
    if (menu.pasteShown === false) return false
    return menu.action === "copyAndPaste" || menu.action === "copy-and-paste"
  }
  readonly property int selectedColourIndex: {
    var items = paletteItems
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].selected) {
        var idx = items[i].index
        return idx === undefined ? i : idx
      }
    }
    if (menu && menu.paletteIndex !== undefined && menu.paletteIndex !== null)
      return menu.paletteIndex
    return 0
  }
  readonly property string selectedColourName: {
    var items = paletteItems
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].selected) return String(items[i].name || "")
    }
    return items.length ? String(items[0].name || "") : ""
  }
  readonly property string selectedColourHex: {
    var items = paletteItems
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].selected) return String(items[i].hex || "")
    }
    return items.length ? String(items[0].hex || "") : ""
  }
  readonly property string stopLabel: {
    if (!annotating) return "Start Annotating"
    var strokes = menu && menu.strokes ? menu.strokes : 0
    if (strokes > 0) return copyAndPaste ? "Stop & Paste" : "Stop & Copy"
    return "Stop Annotating"
  }
  readonly property string tip: !daemonUp
    ? "ScribbleEverywhere\nDaemon not running — click to start"
    : (annotating
        ? "Annotating " + ink + "\nClick: " + (copyAndPaste ? "paste and stop" : "copy and stop") + "\nRight-click: menu\nMiddle: paste"
        : "ScribbleEverywhere\nClick: annotate\nRight-click: colour, paste, and settings\nMiddle: paste")

  function qmlColor(hex) {
    var h = String(hex || "")
    if (h.charAt(0) === "#") h = h.slice(1)
    if (h.length === 8) return "#" + h.slice(6, 8) + h.slice(0, 6)
    if (h.length === 6) return "#" + h
    return "#ff3b30"
  }

  // # optional, 6 or 8 hex digits. Returns "#RRGGBB" / "#RRGGBBAA" or "".
  function parseColourHex(text) {
    var h = String(text || "").trim()
    if (h.charAt(0) === "#") h = h.slice(1)
    if (h.length !== 6 && h.length !== 8) return ""
    var digits = "0123456789abcdefABCDEF"
    for (var i = 0; i < h.length; i++) {
      if (digits.indexOf(h.charAt(i)) < 0) return ""
    }
    return "#" + h
  }

  function applyHexInput(text) {
    var hex = parseColourHex(text)
    if (hex === "") return
    if (paletteItems.length > 0)
      run("colour-replace", String(selectedColourIndex), hex)
    else
      run("colour-add", hex)
  }

  function startPicker() {
    close()
    pickerKick.restart()
  }

  function applyPickedColour(raw) {
    var hex = parseColourHex(raw)
    if (hex !== "") run("colour-add", hex)
  }

  function menuFlag(key, fallback) {
    if (!menu || menu[key] === undefined || menu[key] === null) return fallback
    return !!menu[key]
  }

  function elideTitle(text) {
    var s = String(text || "").trim()
    if (s.length <= 42) return s
    return s.slice(0, 41) + "…"
  }

  function applyStatus(raw) {
    var text = String(raw || "").trim()
    if (text.charAt(0) === "{") {
      applyMenuText(text)
      return
    }
    if (text.indexOf("annotating=") < 0) {
      if (text.indexOf("ok") === 0)
        return
      root.daemonUp = false
      root.annotating = false
      return
    }
    root.daemonUp = true
    var parts = text.split(" ")
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].split("=")
      if (pair.length < 2) continue
      if (pair[0] === "annotating") root.annotating = pair[1] === "true"
      if (pair[0] === "ink") root.ink = pair[1]
    }
  }

  function applyMenuText(raw) {
    try {
      var parsed = JSON.parse(String(raw || "").trim())
      root.menu = parsed
      root.daemonUp = true
      root.annotating = !!parsed.annotating
      if (parsed.ink) root.ink = parsed.ink
    } catch (e) {
    }
  }

  function refresh() {
    if (statusTimeout.running) return
    if (!statusSocket.connected) {
      statusSocket.connected = true
      return
    }
    statusTimeout.start()
    statusSocket.write("status\n")
    statusSocket.flush()
  }

  function loadMenu() {
    if (!menuProc.running) menuProc.running = true
  }

  property int actionSlot: 0

  function run() {
    var args = [root.ctl]
    for (var i = 0; i < arguments.length; i++) args.push(String(arguments[i]))
    var proc = root.actionSlot === 0 ? actionProc : actionProc2
    root.actionSlot = 1 - root.actionSlot
    proc.command = args
    proc.running = false
    proc.running = true
    settle.restart()
  }

  function close() { popupOpen = false }

  function isPastePrevious() {
    return !root.pastePinned && root.menu && root.menu.pasteTarget === "previousApp"
  }

  function isPasteFrontmost() {
    return !root.pastePinned && root.menu && root.menu.pasteTarget === "frontmostApp"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // The daemon accepts multiple newline-delimited requests per connection.
  Socket {
    id: statusSocket
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/palimpsest-ink.sock"
    onConnectionStateChanged: {
      if (connected) {
        root.refresh()
      } else {
        statusTimeout.stop()
        root.applyStatus("")
      }
    }
    onError: {
      statusTimeout.stop()
      root.applyStatus("")
    }
    parser: SplitParser {
      onRead: function(line) {
        if (!statusTimeout.running) return
        statusTimeout.stop()
        root.applyStatus(line)
      }
    }
  }

  Timer {
    id: statusTimeout
    interval: 5000
    onTriggered: statusSocket.connected = false
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: actionProc2
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: menuProc
    command: [root.ctl, "menu"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMenuText(text)
    }
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPickedColour(text)
    }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settle
    interval: 250
    onTriggered: {
      root.refresh()
      if (root.popupOpen) root.loadMenu()
    }
  }

  // Let the popup unmap before hyprpicker freezes the screen.
  Timer {
    id: pickerKick
    interval: 80
    onTriggered: {
      pickerProc.running = false
      pickerProc.command = ["/usr/bin/hyprpicker", "-f", "hex", "-b", "-q"]
      pickerProc.running = true
    }
  }

  onPopupOpenChanged: if (popupOpen) root.loadMenu()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "✎"
    active: root.annotating
    activeColor: root.inkColor
    tooltipText: root.popupOpen ? "" : root.tip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.popupOpen = !root.popupOpen
      else if (b === Qt.MiddleButton) root.run("paste")
      else root.run("toggle")
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(560))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: column
        width: flick.width
        spacing: Style.space(8)

        Text {
          text: "ScribbleEverywhere"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: root.stopLabel
          onClicked: root.run("toggle")
        }

        Text {
          text: root.selectedColourName !== "" ? "Ink Colour (" + root.selectedColourName + ")" : "Ink Colour"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.paletteItems
            delegate: Rectangle {
              required property var modelData
              width: Style.space(22)
              height: Style.space(22)
              radius: height / 2
              color: root.qmlColor(modelData.hex)
              border.width: modelData.selected ? 3 : 1
              border.color: modelData.selected ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.7)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  var idx = modelData.index === undefined ? "" : String(modelData.index)
                  if (mouse.button === Qt.RightButton) {
                    if (root.paletteItems.length > 1 && idx !== "")
                      root.run("colour-remove", idx)
                  } else if (idx !== "") {
                    root.run("colour", idx)
                  }
                }
              }
            }
          }

          Button {
            foreground: root.bar.foreground
            text: "+"
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(2)
            onClicked: root.run("colour-add")
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)
          visible: root.extraItems.length > 0

          Repeater {
            model: root.extraItems
            delegate: Item {
              required property var modelData
              width: Style.space(16)
              height: Style.space(16)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: root.qmlColor(modelData.hex)
              }

              // Rectangle has no dashed stroke; Canvas draws the unused-extra ring.
              Canvas {
                anchors.fill: parent
                antialiasing: true
                contextType: "2d"
                onPaint: {
                  var ctx = getContext("2d")
                  if (!ctx) return
                  ctx.clearRect(0, 0, width, height)
                  ctx.strokeStyle = "rgba(255,255,255,0.75)"
                  ctx.lineWidth = 1.5
                  if (typeof ctx.setLineDash === "function")
                    ctx.setLineDash([3, 2])
                  ctx.beginPath()
                  ctx.arc(width / 2, height / 2, Math.max(1, width / 2 - 1), 0, Math.PI * 2)
                  ctx.stroke()
                }
                Component.onCompleted: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var hex = modelData && modelData.hex ? String(modelData.hex) : ""
                  if (hex !== "") root.run("colour-add", hex)
                }
              }
            }
          }
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          visible: root.showColourPicker
          text: "Pick colour"
          onClicked: root.startPicker()
        }

        Text {
          visible: root.selectedColourName !== ""
          text: root.selectedColourName
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          elide: Text.ElideRight
        }

        TextField {
          id: colourNameField
          width: parent.width
          visible: root.paletteItems.length > 0
          placeholderText: "Name"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalPadding: Style.space(2)

          Binding on text {
            value: root.selectedColourName
            when: !colourNameField.activeFocus
          }

          onAccepted: {
            if (root.selectedColourIndex >= 0)
              root.run("colour-name", String(root.selectedColourIndex), text)
            focus = false
          }
          Keys.onEscapePressed: function(event) {
            text = root.selectedColourName
            event.accepted = true
            focus = false
          }
        }

        TextField {
          id: colourHexField
          width: parent.width
          placeholderText: "#RRGGBB or #RRGGBBAA"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalPadding: Style.space(2)

          Binding on text {
            value: root.selectedColourHex
            when: !colourHexField.activeFocus
          }

          onAccepted: {
            root.applyHexInput(text)
            focus = false
          }
          Keys.onEscapePressed: function(event) {
            text = root.selectedColourHex
            event.accepted = true
            focus = false
          }
        }

        Text {
          text: "On stop"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          selected: !root.copyAndPaste
          text: "Copy to clipboard"
          onClicked: root.run("action", "clipboard")
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          selected: root.copyAndPaste
          text: "Copy and paste"
          onClicked: root.run("action", "copy-and-paste")
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Paste into (" + (root.menu && root.menu.pasteTitle ? root.menu.pasteTitle : "Previous window") + ")"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }

          Button {
            width: parent.width
            leftAlign: true
            foreground: root.bar.foreground
            selected: root.isPastePrevious()
            text: "Previous window"
            onClicked: root.run("paste-target", "previous")
          }

          Button {
            width: parent.width
            leftAlign: true
            foreground: root.bar.foreground
            selected: root.isPasteFrontmost()
            text: "Frontmost window"
            onClicked: root.run("paste-target", "frontmost")
          }

          Repeater {
            model: root.windowItems
            delegate: Button {
              required property var modelData
              width: column.width
              leftAlign: true
              foreground: root.bar.foreground
              selected: root.menu && root.menu.pasteOverride === modelData.address
              text: root.elideTitle(modelData.title || modelData.class || modelData.address)
              onClicked: root.run("paste-target", "pin", String(modelData.address), String(modelData.title || ""))
            }
          }

          Text {
            visible: root.windowItems.length === 0
            text: "No other windows running"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "History"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.historyItems.length === 0
            text: "No saved annotations"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Repeater {
            model: root.historyItems
            delegate: Button {
              required property var modelData
              width: column.width
              leftAlign: true
              foreground: root.bar.foreground
              text: root.elideTitle(modelData.name || modelData.path)
              onClicked: if (modelData.path) root.run("history-open", String(modelData.path))
            }
          }
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: "Open Annotations Folder"
          onClicked: root.run("history-open")
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          opacity: (root.menu && root.menu.strokes > 0) ? 1 : 0.45
          text: "Clear"
          onClicked: if (root.menu && root.menu.strokes > 0) root.run("clear")
        }

        Text {
          text: "Floating Palette"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)
          Button {
            foreground: root.bar.foreground
            selected: root.menu && root.menu.palettePosition === "none"
            text: "None"
            onClicked: root.run("palette-position", "none")
          }
          Button {
            foreground: root.bar.foreground
            selected: root.menu && root.menu.palettePosition === "topLeft"
            text: "Top left"
            onClicked: root.run("palette-position", "top-left")
          }
          Button {
            foreground: root.bar.foreground
            selected: root.menu && root.menu.palettePosition === "topRight"
            text: "Top right"
            onClicked: root.run("palette-position", "top-right")
          }
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          selected: root.menuFlag("saveAnnotations", false)
          text: "Save annotations"
          onClicked: root.run("save-annotations", root.menuFlag("saveAnnotations", false) ? "off" : "on")
        }

        Text {
          text: "Save folder"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextField {
          id: folderField
          width: parent.width
          placeholderText: "Folder path"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalPadding: Style.space(2)

          Binding on text {
            value: root.folderPath
            when: !folderField.activeFocus
          }

          onAccepted: {
            var path = String(text || "").trim()
            if (path !== "") root.run("folder", path)
            focus = false
          }
          Keys.onEscapePressed: function(event) {
            text = root.folderPath
            event.accepted = true
            focus = false
          }
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          selected: root.menuFlag("paperTone", false)
          text: "Soften white backgrounds"
          onClicked: root.run("paper-tone", root.menuFlag("paperTone", false) ? "off" : "on")
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          selected: root.menuFlag("launchOnStartup", false)
          text: "Launch at login"
          onClicked: root.run("autostart", root.menuFlag("launchOnStartup", false) ? "off" : "on")
        }

        Text {
          text: "Idle pen pointer behaviour is controlled by Hyprland."
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: "Check Permissions"
          onClicked: root.run("permissions")
        }

        Text {
          text: "About ScribbleEverywhere"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: "Readme & Star ★"
          onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/matthewhand/scribble-everywhere"])
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: "Report an Issue / Feedback"
          onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/matthewhand/scribble-everywhere/issues"])
        }

        Text {
          text: root.hotkeyCaption
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          width: parent.width
          leftAlign: true
          foreground: root.bar.foreground
          text: "Quit ScribbleEverywhere"
          onClicked: {
            root.run("quit")
            root.close()
          }
        }
      }
    }
  }
}
