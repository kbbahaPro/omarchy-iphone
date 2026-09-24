import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Incoming-call surface.
//
// A ringing call is actionable for seconds, so it gets its own layer-shell
// window rather than a row buried in the panel. The layout follows the phone
// convention everyone already knows — big caller name, red decline on the
// left, green accept on the right — while the chrome uses Omarchy's theme
// tokens so it belongs to this desktop rather than imitating iOS.
Item {
  id: root

  property var service: null
  property var bar: null

  readonly property var call: service ? service.activeCall : null
  readonly property bool active: call !== null && call !== undefined

  readonly property string callerName: {
    if (!active) return ""
    var t = String(call.title || "").trim()
    return t !== "" ? t : "Unknown caller"
  }
  readonly property string callerDetail: {
    if (!active) return ""
    var b = String(call.body || "").trim()
    return b !== "" ? b : "Incoming call"
  }

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Answer and decline are the one place a theme colour would hurt: these two
  // meanings are universal, and a themed pair would be ambiguous under
  // pressure.
  readonly property color acceptColor: "#2fb457"
  readonly property color declineColor: "#e2453c"

  function accept() { if (service) service.answerCall() }
  function decline() { if (service) service.declineCall() }

  PanelWindow {
    id: window
    visible: root.active || closeAnim.running
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-iphone-call"
    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand so the card can take Enter/Escape once clicked, without
    // stealing focus from whatever you were typing in the moment it appears.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Only the card accepts input; the rest of the screen stays clickable.
    mask: Region { item: card }

    Item {
      id: stage
      anchors.fill: parent

      Rectangle {
        id: card
        width: Math.min(Style.space(420), stage.width - Style.space(40))
        implicitHeight: content.implicitHeight + Style.spacing.panelPadding * 2
        height: implicitHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: Style.space(48)

        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(18)
        color: Color.popups.background
        border.width: Math.max(1, Style.space(1))
        border.color: Color.popups.border

        // Entry: drop in and settle. Scale and opacity are driven from the
        // same state so the card never appears half-formed.
        opacity: 0
        scale: 0.94
        transformOrigin: Item.Top

        states: State {
          name: "shown"
          when: root.active
          PropertyChanges { target: card; opacity: 1; scale: 1.0; y: Style.space(64) }
        }

        transitions: [
          Transition {
            to: "shown"
            NumberAnimation {
              properties: "opacity,scale,y"
              duration: 260
              easing.type: Easing.OutBack
              easing.overshoot: 0.8
            }
          },
          Transition {
            from: "shown"
            NumberAnimation {
              id: closeAnim
              properties: "opacity,scale,y"
              duration: 160
              easing.type: Easing.InCubic
            }
          }
        ]

        Keys.onEscapePressed: root.decline()
        Keys.onReturnPressed: root.accept()
        Keys.onEnterPressed: root.accept()
        focus: root.active

        ColumnLayout {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.xl

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap

            // Avatar with a slow pulse, so the card reads as "still ringing"
            // without animating anything that carries meaning.
            Item {
              Layout.alignment: Qt.AlignVCenter
              implicitWidth: Style.space(52)
              implicitHeight: Style.space(52)

              Rectangle {
                id: pulse
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, Style.space(2))
                border.color: root.acceptColor
                opacity: 0

                SequentialAnimation {
                  running: root.active
                  loops: Animation.Infinite
                  ParallelAnimation {
                    NumberAnimation { target: pulse; property: "scale"; from: 1.0; to: 1.35; duration: 1400; easing.type: Easing.OutCubic }
                    SequentialAnimation {
                      NumberAnimation { target: pulse; property: "opacity"; from: 0.0; to: 0.55; duration: 350 }
                      NumberAnimation { target: pulse; property: "opacity"; from: 0.55; to: 0.0; duration: 1050 }
                    }
                  }
                }
              }

              Rectangle {
                anchors.centerIn: parent
                width: Style.space(44)
                height: Style.space(44)
                radius: width / 2
                color: Qt.rgba(root.acceptColor.r, root.acceptColor.g, root.acceptColor.b, 0.16)

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.acceptColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  textFormat: Text.PlainText
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.xxs

              Text {
                Layout.fillWidth: true
                text: root.callerName
                color: Color.popups.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                Layout.fillWidth: true
                text: root.callerDetail
                color: Qt.darker(Color.popups.text, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                Layout.fillWidth: true
                visible: root.service && root.service.deviceName !== ""
                text: root.service ? root.service.deviceName : ""
                color: Qt.darker(Color.popups.text, 1.9)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap

            CallButton {
              Layout.fillWidth: true
              accent: root.declineColor
              // A hung-up handset is the phone glyph turned over; this avoids
              // depending on a phone-slash glyph the font may not carry.
              glyph: ""
              glyphRotation: 135
              label: root.active ? String(root.call.negativeAction || "Decline") : "Decline"
              onTriggered: root.decline()
            }

            CallButton {
              Layout.fillWidth: true
              accent: root.acceptColor
              glyph: ""
              label: root.active ? String(root.call.positiveAction || "Answer") : "Answer"
              onTriggered: root.accept()
            }
          }

          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: "Enter to answer · Esc to decline"
            color: Qt.darker(Color.popups.text, 2.1)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  component CallButton: Rectangle {
    id: button

    property color accent: "#888888"
    property string glyph: ""
    property real glyphRotation: 0
    property string label: ""
    signal triggered()

    implicitHeight: Style.space(44)
    radius: height / 2
    color: mouse.containsMouse
           ? Qt.rgba(accent.r, accent.g, accent.b, 0.26)
           : Qt.rgba(accent.r, accent.g, accent.b, 0.15)
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.rgba(accent.r, accent.g, accent.b, mouse.containsMouse ? 0.9 : 0.5)

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on scale { NumberAnimation { duration: 90 } }
    scale: mouse.pressed ? 0.96 : 1.0

    RowLayout {
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Text {
        text: button.glyph
        rotation: button.glyphRotation
        color: button.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        textFormat: Text.PlainText
      }

      Text {
        text: button.label
        color: button.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.triggered()
    }
  }
}
