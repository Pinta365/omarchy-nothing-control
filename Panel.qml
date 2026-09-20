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
  moduleName: "pinta365.nothing-control"
  ipcTarget: "nothing-control"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property bool showBatteryText: setting("showBatteryText", true) === true
  readonly property bool present: ear.deviceKnown && ear.bluezConnected
  readonly property bool barTextVisible: showBatteryText && present
    && ear.barLevel !== Model.LEVEL_UNKNOWN

  TextMetrics {
    id: levelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: Model.levelText(ear.barLevel)
  }

  visible: present || !hideWhenDisconnected

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property string focusSection: "anc"
  property int focusIndex: 0
  property bool cursorActive: false

  readonly property var ancModes: Model.ANC_MODES
  readonly property var eqPresets: Model.EQ_PRESETS
  readonly property var toggles: Model.toggleRows(ear.status)

  readonly property var sections: {
    var out = []
    if (ear.status.anc.available) out.push("anc")
    if (ear.status.eq.available) out.push("eq")
    if (toggles.length > 0) out.push("options")
    return out
  }

  function rowsFor(section) {
    if (section === "anc") return ancModes
    if (section === "eq") return eqPresets
    return toggles
  }

  readonly property bool bassRowFocused: cursorActive
    && focusSection === "options"
    && focusIndex >= 0 && focusIndex < toggles.length
    && toggles[focusIndex].key === "bass"

  function moveCursor(dx, dy) {
    if (dx !== 0 && bassRowFocused && ear.toggleState("bass")) {
      ear.setBassLevel(ear.bassLevel + (dx > 0 ? 1 : -1))
      return
    }
    var step = dy !== 0 ? dy : dx
    if (step === 0 || sections.length === 0) return

    var here = sections.indexOf(focusSection)
    if (here < 0) {
      focusSection = sections[0]
      focusIndex = 0
      return
    }

    var index = focusIndex + step
    if (index < 0) {
      if (here === 0) { focusIndex = 0; return }
      focusSection = sections[here - 1]
      focusIndex = rowsFor(focusSection).length - 1
      return
    }
    if (index >= rowsFor(focusSection).length) {
      if (here === sections.length - 1) {
        focusIndex = rowsFor(focusSection).length - 1
        return
      }
      focusSection = sections[here + 1]
      focusIndex = 0
      return
    }
    focusIndex = index
  }

  function activateCursor() {
    var rows = rowsFor(focusSection)
    if (focusIndex < 0 || focusIndex >= rows.length) return
    var key = rows[focusIndex].key
    if (focusSection === "anc") ear.setAnc(key)
    else if (focusSection === "eq") ear.setEq(key)
    else ear.setToggle(key, !ear.toggleState(key))
  }

  function rowHasCursor(section, index) {
    return cursorActive && focusSection === section && focusIndex === index
  }

  function takeCursor(section, index) {
    cursorActive = true
    focusSection = section
    focusIndex = index
  }

  Service {
    id: ear
    settings: root.settings
    panelOpen: root.opened
    onNotificationRequested: function (title, body) {
      Quickshell.execDetached(["notify-send", "-a", "Nothing Ear", title, body])
    }
  }

  IpcHandler {
    target: "nothing-control"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { ear.refresh() }
    function noise(): void { ear.cycleAnc() }
    function status(): string { return ear.ancMode }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot
      + (root.barTextVisible ? levelMetrics.width + Style.space(5) : 0)
    iconComponent: Component {
      Item {
        RowLayout {
          anchors.centerIn: parent
          spacing: Style.space(4)

          NothingEarIcon {
            iconSize: Style.space(13)
            color: root.present ? (ear.barLevelLow ? root.urgent : root.foreground) : root.dim
          }

          Text {
            visible: root.barTextVisible
            text: Model.levelText(ear.barLevel)
            color: ear.barLevelLow ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) ear.cycleAnc()
      else if (buttonCode === Qt.MiddleButton) ear.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1120))

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
        var key = t.toLowerCase()
        if (key === "r") ear.refresh()
        else if (key === "c") ear.cycleAnc()
        else if (key === "o") ear.setAnc("off")
        else if (key === "t") ear.setAnc("transparency")
        else if (key === "a") ear.setAnc("adaptive")
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
          spacing: Style.space(10)

          PanelSectionHeader {
            width: parent.width
            text: ear.status.name !== "" ? ear.status.name : "Nothing Ear"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Battery. Meters rather than rings: at this width a bar carries
          // the reading and the comparison between buds in one glance.
          Repeater {
            model: Model.batteryRows(ear.status)
            BatteryRow {
              width: column.width
              label: modelData.label
              pod: modelData.pod
            }
          }

          Text {
            width: parent.width
            visible: !ear.protocol && ear.status.aggregateBattery >= 0
            text: "Showing the system battery reading"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; visible: ear.status.anc.available }

          PanelSectionHeader {
            width: parent.width
            visible: ear.status.anc.available
            text: "Noise control"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Chips rather than full-width rows: six modes as rows cost more
          // vertical space than the whole battery section. Flow wraps on the
          // available width, which matters because "Transparency" is three
          // times the width of "Off".
          Flow {
            width: column.width
            spacing: Style.space(6)

            Repeater {
              model: ear.status.anc.available ? root.ancModes : []
              Chip {
                label: modelData.label
                selected: ear.ancMode === modelData.key
                hasCursor: root.rowHasCursor("anc", index)
                onEntered: root.takeCursor("anc", index)
                onActivated: ear.setAnc(modelData.key)
              }
            }
          }

          PanelSeparator { width: parent.width; visible: ear.status.eq.available }

          PanelSectionHeader {
            width: parent.width
            visible: ear.status.eq.available
            text: "Equaliser"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flow {
            width: column.width
            spacing: Style.space(6)

            Repeater {
              model: ear.status.eq.available ? root.eqPresets : []
              Chip {
                label: modelData.label
                selected: ear.eqPreset === modelData.key
                hasCursor: root.rowHasCursor("eq", index)
                onEntered: root.takeCursor("eq", index)
                onActivated: ear.setEq(modelData.key)
              }
            }
          }

          PanelSeparator { width: parent.width; visible: root.toggles.length > 0 }

          PanelSectionHeader {
            width: parent.width
            visible: root.toggles.length > 0
            text: "Options"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.toggles
            Column {
              width: column.width
              spacing: 0

              ToggleRow {
                width: parent.width
                label: modelData.label
                caption: modelData.caption
                checked: ear.toggleState(modelData.key)
                hasCursor: root.rowHasCursor("options", index)
                onEntered: root.takeCursor("options", index)
                onActivated: ear.setToggle(modelData.key, !checked)
              }

              // Only bass carries a level, and only while it is switched on.
              BassSlider {
                width: parent.width
                visible: modelData.key === "bass" && ear.toggleState("bass")
                height: visible ? implicitHeight : 0
              }
            }
          }

          PanelSeparator { width: parent.width; visible: !ear.modelKnown && ear.protocol }

          // Unverified device: say what is missing and why, and make helping
          // a single click rather than a bug report the user has to compose.
          Column {
            width: parent.width
            visible: !ear.modelKnown && ear.protocol
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: "Unverified device"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Battery and noise control work on every Nothing and CMF model. "
                    + "Equaliser and bass use different values per model, so they are "
                    + "hidden until this one is confirmed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // A Chip rather than PanelActionButton: that one sizes itself to a
            // single glyph and clips a text label.
            Chip {
              label: "Help us add support"
              onActivated: {
                ear.reportDevice()
                root.close()
              }
            }
          }

          // Errors get their own line and outlive a background refresh, so a
          // failed click cannot be silently erased by the next poll.
          Text {
            width: parent.width
            visible: text !== ""
            text: ear.actionError !== "" ? ear.actionError : ear.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component BatteryRow: Item {
    id: batteryRow
    property string label: ""
    property var pod: Model.defaultPod()

    readonly property bool low: Model.isLow(pod, ear.lowBatteryThreshold)
    readonly property string meta: Model.podMeta(pod)

    implicitHeight: row.implicitHeight

    RowLayout {
      id: row
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: batteryRow.label
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(40)
      }

      Rectangle {
        id: track
        Layout.fillWidth: true
        implicitHeight: Style.space(6)
        radius: height / 2
        color: Qt.darker(root.foreground, 3.2)

        Rectangle {
          width: track.width * Model.levelFraction(batteryRow.pod.level)
          height: parent.height
          radius: height / 2
          color: batteryRow.low ? root.urgent : root.foreground
          // A stale reading is still worth showing, just not with the same
          // confidence as a live one.
          opacity: batteryRow.pod.stale ? 0.45 : 1.0
          Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }
        }
      }

      Text {
        text: Model.levelText(batteryRow.pod.level)
        color: batteryRow.low ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(38)
        horizontalAlignment: Text.AlignRight
      }

      Text {
        text: batteryRow.meta
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component BassSlider: Item {
    implicitHeight: Style.space(26)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      PanelSlider {
        bar: root.bar
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        minimum: Model.BASS_MIN_LEVEL
        maximum: Model.BASS_MAX_LEVEL
        step: 1
        integer: true
        tickCount: Model.BASS_MAX_LEVEL
        value: ear.bassLevel
        // Only commit on release: a drag across the track would otherwise
        // send a write per step, and each one holds the control channel.
        onReleased: function (v) { ear.setBassLevel(v) }
      }

      Text {
        text: String(ear.bassLevel)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(12)
        horizontalAlignment: Text.AlignRight
      }
    }
  }

  component ToggleRow: CursorSurface {
    id: toggleRow
    property string label: ""
    property string caption: ""
    property bool checked: false

    signal entered()
    signal activated()

    foreground: root.foreground
    implicitHeight: Math.max(Style.space(30), labels.implicitHeight + Style.spacing.sm * 2)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: toggleRow.entered()
      onClicked: toggleRow.activated()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Column {
        id: labels
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          text: toggleRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          text: toggleRow.caption
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ToggleSwitch {
        checked: toggleRow.checked
        hasCursor: toggleRow.hasCursor
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: toggleRow.activated()
        onHovered: function (on) { if (on) toggleRow.entered() }
      }
    }
  }

  component Chip: CursorSurface {
    id: chip
    property string label: ""
    property bool selected: false

    signal entered()
    signal activated()

    foreground: root.foreground
    current: selected
    bordered: true
    implicitWidth: chipLabel.implicitWidth + Style.space(18)
    implicitHeight: Math.max(Style.space(26), chipLabel.implicitHeight + Style.spacing.sm * 2)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: chip.entered()
      onClicked: chip.activated()
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: root.foreground
      // The selected chip carries the accent fill from CursorSurface, so the
      // label only needs to lift the unselected ones back rather than shout.
      opacity: chip.selected ? 1.0 : 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
