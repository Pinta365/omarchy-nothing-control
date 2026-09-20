import QtQuick
import qs.Commons

// A pair of stemmed earbuds, drawn rather than set in a font.
//
// Nerd Font coverage cannot be trusted from fc-match: a glyph can be reported
// as present and still paint as garbage at bar size. Drawing the silhouette
// removes the font from the question entirely.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize * 1.05
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  readonly property real budSize: height * 0.46
  readonly property real stemWidth: height * 0.17
  readonly property real stemHeight: height * 0.46

  Bud { mirrored: false }
  Bud { mirrored: true }

  component Bud: Item {
    property bool mirrored: false

    width: root.width / 2
    height: root.height
    x: mirrored ? root.width / 2 : 0

    transform: Rotation {
      origin.x: bud.x + bud.width / 2
      origin.y: bud.y + bud.height / 2
      angle: parent.mirrored ? 12 : -12
    }

    Rectangle {
      id: bud
      width: root.budSize
      height: root.budSize
      radius: width / 2
      color: root.color
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.height * 0.06
    }

    Rectangle {
      width: root.stemWidth
      height: root.stemHeight
      radius: width / 2
      color: root.color
      anchors.horizontalCenter: parent.horizontalCenter
      y: bud.y + bud.height * 0.78
    }
  }
}
