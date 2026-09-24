import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.kbbahapro.iphone"
  ipcTarget: "io.github.kbbahapro.iphone"
  // This panel owns the single IpcHandler the target allows, so it can expose
  // pair/clear alongside the standard open/close verbs.
  manageIpc: false

  // The bar sizes each slot from the widget's implicit size. Without these
  // the slot collapses to 0x0 and the widget never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Resolve the plugin's own directory so the helper is found wherever the
  // plugin is installed, rather than hardcoding a path under $HOME.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color barIconColor: {
    if (!iphone.connected) return Qt.darker(barForeground, 1.6)
    if (iphone.focusMode) return Qt.darker(barForeground, 1.35)
    if (iphone.batteryLow) return bar ? bar.urgent : Color.urgent
    return barForeground
  }
  readonly property string badge: Model.badgeText(iphone.unread)

  property int selectedIndex: 0
  property bool cursorActive: false
  property int nowMs: Date.now()

  function ensureCursor() {
    if (iphone.items.length === 0) { selectedIndex = 0; return }
    if (selectedIndex >= iphone.items.length) selectedIndex = iphone.items.length - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0 || iphone.items.length === 0) return
    selectedIndex = Math.max(0, Math.min(iphone.items.length - 1, selectedIndex + dy))
  }

  function selectedEntry() {
    if (iphone.items.length === 0) return null
    return iphone.items[Math.max(0, Math.min(selectedIndex, iphone.items.length - 1))]
  }

  function activateCursor() {
    var entry = selectedEntry()
    if (entry) iphone.dismiss(entry)
    ensureCursor()
  }

  onOpenedChanged: {
    if (!opened) return
    iphone.markRead()
    nowMs = Date.now()
    cursorActive = false
    selectedIndex = 0
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: iphone
    settings: root.settings
    pluginDir: root.pluginDir
  }

  // Relative timestamps go stale while the panel sits open.
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function pair(): string { iphone.startPairing(); return "advertising" }
    function focus(): string { iphone.toggleFocus(); return iphone.focusMode ? "on" : "off" }
    // Diagnostic: run the exact action path the panel buttons use, against
    // the newest notification, and report what the service saw.
    function actNewest(): string { return iphone.actOnNewest("negative") }
    function lastError(): string { return iphone.lastError }
    function focusOn(): string { iphone.setFocus(true); return "on" }
    function focusOff(): string { iphone.setFocus(false); return "off" }
    function clear(): string { iphone.clearAll(); return "ok" }
    function status(): string { return iphone.statusText }
    function unread(): string { return String(iphone.unread) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.barIconColor
    tooltipText: iphone.statusText + (iphone.unread > 0 ? " · " + iphone.unread + " unread" : "")
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) iphone.markRead()
      else if (buttonCode === Qt.MiddleButton) iphone.toggleFocus()
      else root.toggle()
    }

    // Unread count rides the top-right corner, the way it does on the phone.
    Rectangle {
      visible: root.badge !== ""
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(1)
      anchors.topMargin: Style.space(3)
      implicitWidth: Math.max(Style.space(10), badgeText.implicitWidth + Style.space(4))
      implicitHeight: Style.space(10)
      width: implicitWidth
      height: implicitHeight
      radius: height / 2
      color: root.bar ? root.bar.urgent : Color.urgent

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: root.badge
        color: Color.background
        font.family: root.fontFamily
        font.pixelSize: Math.max(7, Style.font.caption - 2)
        font.bold: true
        textFormat: Text.PlainText
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "c" || t === "C") iphone.clearAll()
        else if (t === "p" || t === "P") iphone.startPairing()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "iPhone"
            meta: iphone.statusText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: iphone.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                textFormat: Text.PlainText
              }
            }

            trailingControl: Component {
              RowLayout {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: iphone.focusMode ? "" : ""
                  tooltipText: iphone.focusMode
                               ? "Focus on — click to allow popups again"
                               : "Focus: silence everything except VIPs"
                  foreground: iphone.focusMode ? Color.accent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: iphone.toggleFocus()
                }

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Advertise for pairing"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: iphone.startPairing()
                }
              }
            }
          }

          // Setup guidance, shown only while the system daemon is missing —
          // an empty list would otherwise look like a quiet phone.
          Column {
            visible: !iphone.observerUp
            width: parent.width
            spacing: Style.spacing.labelGap

            Text {
              width: parent.width
              text: iphone.daemonInstalled
                    ? "The ANCS bridge daemon is installed but not running."
                    : "One-time setup: the ANCS bridge daemon is not installed yet."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
            Text {
              width: parent.width
              text: iphone.daemonInstalled
                    ? "sudo systemctl start ancs4linux-observer"
                    : "sudo " + root.pluginDir + "install-ancs4linux.sh"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WrapAnywhere
              textFormat: Text.PlainText
            }
          }

          Text {
            visible: iphone.actionStatus !== "" || iphone.lastError !== ""
            width: parent.width
            text: iphone.lastError !== "" ? iphone.lastError : iphone.actionStatus
            color: iphone.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          // Now playing, straight off the BLE link via Apple Media Service.
          // Works whether or not the phone is connected as an audio source.
          Column {
            visible: iphone.amsAvailable && iphone.npPlayer !== ""
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "NOW PLAYING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.xxs

                Text {
                  Layout.fillWidth: true
                  text: iphone.npTitle !== "" ? iphone.npTitle : iphone.npPlayer
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                Text {
                  Layout.fillWidth: true
                  visible: iphone.npArtist !== "" || iphone.npPlayback !== ""
                  text: iphone.npArtist !== ""
                        ? iphone.npArtist + (iphone.npAlbum !== "" ? " — " + iphone.npAlbum : "")
                        : iphone.npPlayback
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              PanelActionButton {
                iconText: "\uf04a"
                tooltipText: "Previous"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: iphone.mediaCommand("prev")
              }

              PanelActionButton {
                iconText: iphone.npPlaying ? "\uf04c" : "\uf04b"
                tooltipText: iphone.npPlaying ? "Pause" : "Play"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: iphone.mediaCommand("toggle")
              }

              PanelActionButton {
                iconText: "\uf04e"
                tooltipText: "Next"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: iphone.mediaCommand("next")
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(sectionHeader.implicitHeight, clearButton.implicitHeight)

            PanelSectionHeader {
              id: sectionHeader
              anchors.verticalCenter: parent.verticalCenter
              text: "NOTIFICATIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // What iOS says is still queued on the device, as opposed to what
            // we have collected here.
            Text {
              anchors.left: sectionHeader.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              visible: iphone.phonePending > 0
              text: "· " + iphone.phonePending + " on phone"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Button {
              id: clearButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: iphone.items.length > 0
              text: "Clear all"
              tooltipText: "Dismiss every notification, here and on the phone"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: iphone.clearAll()
            }
          }

          Text {
            visible: iphone.items.length === 0
            width: parent.width
            text: iphone.observerUp
                  ? (iphone.connected ? "Nothing new. Notifications will appear here."
                                      : "Connect your iPhone to start mirroring notifications.")
                  : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Repeater {
            model: iphone.threads

            Item {
              id: row
              required property var modelData
              readonly property var entry: modelData.latest
              required property int index

              width: column.width
              implicitHeight: rowLayout.implicitHeight + Style.spacing.md * 2

              readonly property bool hasCursor: root.cursorActive && root.selectedIndex === index

              // Urgent rows carry a faint tint so calls stand out in a long list.
              Rectangle {
                anchors.fill: parent
                visible: Model.isUrgent(row.entry)
                color: root.urgent
                opacity: 0.10
              }

              CursorSurface {
                anchors.fill: parent
                hasCursor: row.hasCursor || rowMouse.containsMouse
                foreground: root.foreground
                accent: Color.accent
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: { root.cursorActive = true; root.selectedIndex = row.index }
                onClicked: function (mouse) {
                  if (mouse.button === Qt.RightButton) iphone.dismissThread(row.modelData)
                }
              }

              RowLayout {
                id: rowLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.controlGap

                Text {
                  Layout.alignment: Qt.AlignTop
                  text: Model.glyphFor(row.entry)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  textFormat: Text.PlainText
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.xxs

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    Text {
                      visible: row.modelData.count > 1
                      text: "×" + row.modelData.count
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      textFormat: Text.PlainText
                    }

                    Text {
                      text: Model.displayAppName(row.entry)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      textFormat: Text.PlainText
                    }

                    Text {
                      visible: text !== ""
                      text: Model.categoryLabel(row.entry)
                      color: Model.isUrgent(row.entry) ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                      text: Model.relativeTime(row.entry.ts, root.nowMs)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    visible: String(row.entry.title || "") !== ""
                    text: String(row.entry.title || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  Text {
                    Layout.fillWidth: true
                    visible: String(row.entry.body || "") !== ""
                    text: String(row.entry.body || "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                }

                // Positive action first (Answer, Accept), then dismiss. ANCS
                // only ever offers these two, so there is nothing else to show.
                PanelActionButton {
                  Layout.alignment: Qt.AlignVCenter
                  visible: row.entry.positiveAction !== undefined
                           && row.entry.positiveAction !== null
                           && Model.isActionable(row.entry, iphone.currentSession)
                  iconText: ""
                  tooltipText: String(row.entry.positiveAction || "Accept")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: iphone.accept(row.entry)
                }

                PanelActionButton {
                  Layout.alignment: Qt.AlignVCenter
                  // Stale rows keep a local-only dismiss; the phone cannot be
                  // told about a notification from a previous connection.
                  opacity: Model.isActionable(row.entry, iphone.currentSession) ? 1.0 : 0.45
                  tooltipText: Model.isActionable(row.entry, iphone.currentSession)
                               ? String(row.entry.negativeAction || "Dismiss on phone")
                               : "Remove here only — too old to act on the phone"
                  iconText: ""
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: iphone.dismissThread(row.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
