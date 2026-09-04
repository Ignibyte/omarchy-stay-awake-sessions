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
  readonly property var quickMinutes: service ? service.quickMinutes : [5, 15, 30]
  readonly property var quickHours: service ? service.quickHours : [1, 2, 4]

  // Read when the panel opens rather than bound: a picker only has to be right
  // at the moment it is looked at, and this keeps the widget off the
  // compositor's toplevel signals.
  property var appOptions: []

  function refreshApps() {
    root.appOptions = service ? service.openApps() : []
  }

  readonly property int defaultMinutes: service ? service.defaultMinutes : 60

  property bool opened: false

  readonly property string glyph: String(setting("icon", "󰅶")) || "󰅶"
  readonly property bool showCountdown: setting("showCountdown", true) !== false

  // Shape contract for the shell's summon/hide/toggle routing.
  function open() {
    root.refreshApps()
    root.opened = true
  }
  function close() { root.opened = false }
  function togglePopup() {
    if (!root.opened) root.refreshApps()
    root.opened = !root.opened
  }

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
    text: root.holding && root.showCountdown && root.countdown !== ""
      ? root.glyph + "  " + root.countdown : root.glyph
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

      // Two rows because minutes and hours are two different intentions, and
      // both lists come from settings — everyone's idea of a short hold differs.
      Row {
        width: content.width
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          textFormat: Text.PlainText
          text: "Minutes"
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.quickMinutes

          Button {
            required property var modelData
            text: modelData + "m"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.hold("for=" + modelData + "m")
          }
        }
      }

      Row {
        width: content.width
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          textFormat: Text.PlainText
          text: "Hours"
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.quickHours

          Button {
            required property var modelData
            text: modelData + "h"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.hold("for=" + modelData + "h")
          }
        }
      }

      // Anything the buttons do not cover, typed: a duration or a time of day.
      Row {
        width: content.width
        spacing: Style.spacing.sm

        TextField {
          id: customDuration
          width: content.width - customButton.width - untilStopButton.width - Style.spacing.sm * 2
          placeholderText: "90m, 1h30m, 17:00 or 5pm"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          onAccepted: customButton.submit()
        }

        Button {
          id: customButton
          anchors.verticalCenter: parent.verticalCenter
          text: "Hold"
          bordered: true
          fontSize: Style.font.caption

          // A colon or an am/pm means a time of day; anything else is a
          // duration. Both go through the same parser the CLI uses.
          function submit() {
            var typed = String(customDuration.text).trim()
            if (typed === "") return
            var isClock = typed.indexOf(":") !== -1 || /(am|pm)$/i.test(typed)
            root.hold((isClock ? "until=" : "for=") + typed)
            customDuration.text = ""
          }

          onClicked: submit()
        }

        Button {
          id: untilStopButton
          anchors.verticalCenter: parent.verticalCenter
          text: "No end"
          tooltipText: "Hold until you stop it"
          bordered: true
          fontSize: Style.font.caption
          onClicked: root.hold('label="Until you stop it"')
        }
      }

      PanelSeparator { }

      PanelSectionHeader { text: "WHILE AN APP IS OPEN" }

      // Inline rather than a dropdown: a dropdown's list is laid out inside
      // this popup window, which is sized to exactly fit its content, so the
      // list had nowhere to go and was cut off at the bottom. Buttons that
      // wrap make the card grow instead, and match the quick holds above.
      Flow {
        width: content.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.appOptions

          Button {
            required property var modelData
            text: SessionModel.shortAppLabel(modelData.appId)
            tooltipText: modelData.title === ""
              ? modelData.appId : modelData.appId + " — " + modelData.title
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.hold('while-app="' + modelData.appId
              + '" label="' + SessionModel.shortAppLabel(modelData.appId) + '"')
          }
        }
      }

      Text {
        visible: root.appOptions.length === 0
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "No windows are open to watch."
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
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
