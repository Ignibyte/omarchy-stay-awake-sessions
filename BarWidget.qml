import QtQuick
import qs.Commons
import qs.Ui
import "SessionModel.js" as SessionModel

// The bar face of the plugin: a coffee cup that lights up while something
// holds the machine awake, with the deadline (or what is holding it) beside
// it, and a popup for starting and ending holds.
//
//   left click   open the popup
//   right click  hold for the default duration, or release everything
//   middle click release everything
BarWidget {
  id: root
  moduleName: "ignibyte.stay-awake-sessions"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName || "ignibyte.stay-awake-sessions") : null

  readonly property var heldSessions: service && service.sessions ? service.sessions : []
  readonly property double nowMs: service ? service.nowMs : 0
  readonly property bool holding: heldSessions.length > 0
  readonly property string countdown: SessionModel.barLabel(heldSessions, nowMs)
  readonly property var rows: SessionModel.publicSessions(heldSessions, nowMs)
  readonly property bool showWhenIdle: setting("showWhenIdle", true) !== false
  readonly property bool screensaverOff: service ? service.standingScreensaverOff : false
  readonly property int defaultMinutes: service ? service.defaultMinutes : 60

  property bool opened: false

  readonly property string glyph: "󰅶"

  // Shape contract for the shell's summon/hide/toggle routing.
  function open() { root.opened = true }
  function close() { root.opened = false }
  function togglePopup() { root.opened = !root.opened }

  function hold(spec) {
    if (service) service.start(spec)
  }

  function endAll() {
    if (service) service.endAll("ended from the bar")
  }

  visible: holding || showWhenIdle
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.holding && root.countdown !== "" ? root.glyph + "  " + root.countdown : root.glyph
    fontSize: Style.font.caption
    dimmed: !root.holding
    active: root.holding
    tooltipText: SessionModel.tooltip(root.heldSessions, root.nowMs)

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.holding) root.endAll()
        else root.hold("for=" + root.defaultMinutes + "m")
      } else if (mouseButton === Qt.MiddleButton) {
        root.endAll()
      } else {
        root.togglePopup()
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: Style.space(360)
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      width: parent.width
      spacing: Style.spacing.md

      PanelSectionHeader {
        text: root.holding ? "HOLDING THIS MACHINE AWAKE" : "STAY AWAKE"
      }

      PanelSeparator { }

      Text {
        visible: !root.holding
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Nothing is holding this machine awake. It locks and sleeps on the usual timers."
        color: Qt.darker(Color.popups.text, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      // Title, time and the end button share a row; what is holding the
      // session gets the whole width underneath, because it is the part that
      // is long and the part worth reading.
      Repeater {
        model: root.rows

        Column {
          required property var modelData

          width: content.width
          spacing: Style.spacing.xxs

          Row {
            width: content.width
            spacing: Style.spacing.md

            Text {
              width: parent.width - remaining.width - endButton.width - Style.spacing.md * 2
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: modelData.label
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              id: remaining
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: modelData.remainingMs >= 0
                ? SessionModel.formatRemaining(modelData.remainingMs)
                : SessionModel.formatElapsed(modelData.heldForMs)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Button {
              id: endButton
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              tooltipText: "End this hold"
              fontSize: Style.font.caption
              onClicked: if (root.service) root.service.endOne(modelData.id, "ended from the bar")
            }
          }

          // Wrapped, not elided: a condition can be a whole shell command, and
          // the point of the line is to say exactly what is holding the machine.
          Text {
            width: content.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: modelData.describes + " · blocks " + modelData.holds
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { }

      // The screensaver switch stands apart from the sessions: it is a
      // preference that persists, not a hold with an end in sight.
      Row {
        width: content.width
        spacing: Style.spacing.md

        Column {
          width: content.width - screensaverSwitch.width - Style.spacing.md
          spacing: Style.spacing.xxs

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Screensaver"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.screensaverOff
              ? "Off. The screen still locks on its usual timer."
              : "On, after the usual idle time."
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        ToggleSwitch {
          id: screensaverSwitch
          anchors.verticalCenter: parent.verticalCenter
          checked: !root.screensaverOff
          onToggled: if (root.service) root.service.setScreensaverOff(root.screensaverOff ? false : true)
        }
      }

      PanelSeparator { }

      Row {
        spacing: Style.spacing.sm

        Button {
          text: "15m"
          bordered: true
          fontSize: Style.font.caption
          onClicked: root.hold("for=15m")
        }

        Button {
          text: "1h"
          bordered: true
          fontSize: Style.font.caption
          onClicked: root.hold("for=1h")
        }

        Button {
          text: "3h"
          bordered: true
          fontSize: Style.font.caption
          onClicked: root.hold("for=3h")
        }

        Button {
          text: "Until I stop"
          bordered: true
          fontSize: Style.font.caption
          onClicked: root.hold("label=Until you stop it")
        }
      }

      Button {
        visible: root.holding
        width: content.width
        text: "End every hold"
        bordered: true
        fontSize: Style.font.caption
        onClicked: {
          root.endAll()
          root.close()
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "From a script: stay-awake while -- cargo test"
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
