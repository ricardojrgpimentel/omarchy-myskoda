import QtQuick
import qs.Commons

Item {
  id: root

  property var plan: null
  property bool lightMap: false
  property bool stale: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property bool ready:
    plan && plan.ok === true && plan.tiles && plan.tiles.length > 0

  clip: true

  Rectangle {
    anchors.fill: parent
    color: root.lightMap ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.35)
  }

  Repeater {
    model: root.ready ? root.plan.tiles : []

    Image {
      required property var modelData

      x: modelData.x
      y: modelData.y
      width: root.ready ? root.plan.tileSize : 256
      height: width
      source: "file://" + modelData.path
      asynchronous: true
      cache: true
      smooth: false
      opacity: root.stale ? 0.55 : 1
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !root.ready
    text: "Loading map"
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    color: root.foreground
    opacity: 0.6
  }

  Item {
    id: marker
    visible: root.ready
    width: Style.space(28)
    height: width
    x: (root.ready ? root.plan.carX : 0) - width / 2
    y: (root.ready ? root.plan.carY : 0) - height / 2

    Rectangle {
      id: halo
      anchors.centerIn: parent
      width: parent.width
      height: width
      radius: width / 2
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)

      SequentialAnimation on scale {
        loops: Animation.Infinite
        running: marker.visible
        NumberAnimation { from: 0.75; to: 1.15; duration: 1200; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.15; to: 0.75; duration: 1200; easing.type: Easing.InOutSine }
      }
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.52
      height: width
      radius: width / 2
      color: root.accent
      border.width: Math.max(1, Style.space(2))
      border.color: root.lightMap ? Qt.rgba(0, 0, 0, 0.75) : Qt.rgba(1, 1, 1, 0.9)
    }
  }

  Text {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(4)
    visible: root.ready
    text: root.ready ? root.plan.attribution : ""
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Math.max(8, Style.font.caption - Style.space(2))
    color: root.lightMap ? "#111111" : root.foreground
    opacity: 0.5
    style: Text.Outline
    styleColor: root.lightMap ? "#ffffff" : "#000000"
  }
}
