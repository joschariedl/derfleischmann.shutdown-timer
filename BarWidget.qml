import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: a view over the singleton service plus a panel. It never runs a
// system command itself; every action goes through the service, which talks to
// one user-scoped systemd timer.
BarWidget {
  id: root

  moduleName: Model.PLUGIN_ID

  property int serviceNonce: 0
  property bool panelOpen: false
  property bool confirmOpen: false
  property int pendingSeconds: 0
  property string pendingMessage: ""
  property int customMinutes: 60

  readonly property var service: {
    var _ = root.serviceNonce
    var host = bar && bar.shell
    return host && typeof host.serviceFor === "function"
      ? host.serviceFor(root.moduleName)
      : null
  }

  readonly property bool timerActive: service ? service.active === true : false
  readonly property bool timerExpired: service ? service.expired === true : false
  readonly property bool timerBusy: service ? service.busy === true : false
  readonly property int remainingSeconds: service ? service.remainingSec : 0
  readonly property int durationSeconds: service ? service.durationSec : 0
  readonly property string remainingLabel: service ? String(service.remainingLabel || "") : ""
  readonly property string durationLabel: service ? String(service.durationLabel || "") : ""
  readonly property string lastError: service ? String(service.lastError || "") : ""
  readonly property bool notifyEnabled: service ? service.notifyEnabled === true : true

  readonly property string fontFamily: Style.font.family
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color warningColor: Color.urgent

  readonly property string barLabel: {
    if (root.timerActive && !root.vertical) return root.remainingLabel
    return ""
  }

  function open() {
    root.panelOpen = true
    root.confirmOpen = false
  }

  function close() {
    root.confirmOpen = false
    root.panelOpen = false
  }

  function togglePanel() {
    if (root.panelOpen) root.close()
    else root.open()
  }

  function closeForPopoutSwitch() { root.close() }

  readonly property bool popoutSwitchClosing: false

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  function requestStart(seconds) {
    if (root.timerBusy) return
    var n = Model.clampSeconds(seconds)
    if (n <= 0) return
    root.pendingSeconds = n
    root.pendingMessage = "Shut down in " + Model.formatDuration(n) + "?"
    root.confirmOpen = true
  }

  function requestCustomStart() {
    root.requestStart(Model.minutesToSeconds(root.customMinutes))
  }

  function confirmStart() {
    root.confirmOpen = false
    if (root.service && typeof root.service.start === "function")
      root.service.start(root.pendingSeconds)
  }

  function requestCancel() {
    root.confirmOpen = false
    if (root.service && typeof root.service.cancel === "function")
      root.service.cancel()
  }

  function toggleNotifications() {
    if (root.service && typeof root.service.setNotifyEnabled === "function")
      root.service.setNotifyEnabled(!root.notifyEnabled)
  }

  // --- bar icon ------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔟"
    labelText: root.barLabel
    active: root.timerActive && root.remainingSeconds <= 60
    tooltipText: root.timerActive
      ? "Shutting down in " + root.remainingLabel
      : root.timerExpired ? "Shutting down…" : "Shutdown timer"
    slotSize: {
      if (root.vertical || !root.timerActive) return Style.bar.iconSlot
      return Style.bar.iconSlot * (root.durationSeconds >= 3600 ? 3.8 : 2.8)
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        // Right-click cancels immediately: stopping a timer is always the safe
        // direction, so it should never need a confirmation.
        if (root.timerActive || root.timerExpired) root.requestCancel()
        else root.togglePanel()
        return
      }
      root.togglePanel()
    }
  }

  // The service is injected by the shell; retry while it is still starting.
  Timer {
    interval: 200
    repeat: true
    running: root.service === null
    onTriggered: root.serviceNonce++
  }

  IpcHandler {
    target: Model.PLUGIN_ID + ".panel"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // --- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: keyRoot
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Item {
      id: keyRoot
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.forwardTo: root.confirmOpen ? [] : [keyCatcher]
      Keys.onPressed: function(event) {
        if (!root.confirmOpen) return
        if (dialog.handleKey(event)) event.accepted = true
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        focus: false
        blocked: root.confirmOpen || (customField ? customField.field.activeFocus : false)
        onCloseRequested: {
          if (root.confirmOpen) {
            root.confirmOpen = false
            return
          }
          root.close()
        }
        onTabRequested: function(direction) { root.switchPanel(direction) }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelSectionHeader {
            text: "SHUTDOWN TIMER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.timerActive
              ? "Shutting down in " + root.remainingLabel
              : root.timerExpired ? "Shutting down…" : "No shutdown scheduled"
            color: root.timerActive || root.timerExpired ? root.warningColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: root.timerActive || root.timerExpired
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.timerActive && root.durationLabel !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: "Total " + root.durationLabel
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            width: parent.width
            visible: root.timerActive || root.timerExpired
            enabled: !root.timerBusy
            text: root.timerBusy ? "Stopping…" : "Cancel shutdown"
            iconText: "󰜺"
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            foreground: root.warningColor
            bordered: true
            onClicked: root.requestCancel()
          }

          Text {
            width: parent.width
            visible: root.lastError !== ""
            textFormat: Text.PlainText
            text: root.lastError
            color: root.warningColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "PRESETS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Grid {
            id: presetGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)

            Repeater {
              model: Model.presets()

              Button {
                required property var modelData
                width: (presetGrid.width - presetGrid.columnSpacing) / 2
                text: String(modelData.label)
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                bordered: true
                enabled: !root.timerBusy
                onClicked: root.requestStart(modelData.seconds)
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "CUSTOM"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            NumberField {
              id: customField
              Layout.alignment: Qt.AlignBottom
              label: "Minutes (1–1440)"
              value: root.customMinutes
              from: 1
              to: 1440
              stepSize: 5
              fieldWidth: Style.space(120)
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.timerBusy
              onModified: function(value) { root.customMinutes = value }
            }

            Button {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignBottom
              text: "Start"
              iconText: "󰐥"
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              foreground: root.foreground
              bordered: true
              selected: true
              enabled: !root.timerBusy
              onClicked: root.requestCustomStart()
            }
          }

          PanelSeparator { foreground: root.foreground }

          Toggle {
            width: parent.width
            label: "Notifications"
            description: "Start, warning, and cancel alerts."
            checked: root.notifyEnabled
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.toggleNotifications()
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "One user systemd timer runs the shutdown. It survives a shell restart and needs no sudo."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      ConfirmDialog {
        id: dialog
        anchors.fill: parent
        z: 20
        opened: root.confirmOpen
        selectedIndex: 0 // default to Cancel for a destructive confirm
        message: root.pendingMessage
        cancelText: "Cancel"
        confirmText: "Shut down"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmOpen = false
        onConfirmed: root.confirmStart()
      }
    }
  }
}
