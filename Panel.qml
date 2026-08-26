import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "community.myskoda"
  ipcTarget: "community.myskoda"

  readonly property string script:
    Qt.resolvedUrl("bin/myskoda").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color chargingGreen: "#4caf50"

  readonly property string vin: setting("vin", "")
  readonly property int panelWidth: setting("panelWidth", 380)
  readonly property int mapZoom: setting("mapZoom", 16)
  readonly property string mapStyle: setting("mapStyle", "Auto")
  readonly property int pollMinutes: setting("pollMinutes", 10)
  readonly property bool showAddress: setting("showAddress", true)
  readonly property string mapsUrl: setting("mapsUrl",
    "https://www.google.com/maps/search/?api=1&query={lat},{lon}")

  readonly property bool lightTheme: {
    var bg = Color.background
    return (0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b) > 0.5
  }
  readonly property string effectiveMapStyle:
    mapStyle === "Auto" ? (lightTheme ? "Light" : "Dark") : mapStyle
  readonly property bool lightMap: effectiveMapStyle !== "Dark"
  readonly property string tileUrl: {
    if (effectiveMapStyle === "Light")
      return "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png"
    if (effectiveMapStyle === "OpenStreetMap")
      return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    return "https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
  }

  function command(args) {
    var base = [root.script, "--tile-url", root.tileUrl]
    if (root.vin !== "") base = base.concat(["--vin", root.vin])
    return base.concat(args)
  }

  function plain(value) {
    return String(value === undefined || value === null ? "" : value).replace(/[<>]/g, "")
  }

  property var reading: null
  property var mapPlan: null
  property string errorText: ""
  property string errorHint: ""
  property double now: Date.now()

  readonly property bool hasReading: reading !== null && reading.ok === true
  readonly property bool charging: hasReading && reading.charging === true
  readonly property bool stale: hasReading && (reading.stale === true || readingAge > 3600)
  readonly property bool hasPosition:
    hasReading && reading.lat !== null && reading.lon !== null
  readonly property real lat: hasPosition ? reading.lat : 0
  readonly property real lon: hasPosition ? reading.lon : 0
  readonly property real readingAge:
    hasReading ? Math.max(0, now / 1000 - reading.at) : 0

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  Process {
    id: carProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          root.errorText = "invalid response"
          root.errorHint = "The MySkoda helper did not return JSON."
          return
        }
        root.errorText = data.ok === true ? (data.error || "") : (data.error || "unknown error")
        root.errorHint = data.hint || ""
        if (data.ok !== true) return
        root.reading = data
        root.planMap()
      }
    }
  }

  function refresh() {
    if (carProc.running) return
    carProc.command = root.command(["car"])
    carProc.running = true
  }

  Timer {
    interval: Math.max(5, root.pollMinutes) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: mapProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) root.mapPlan = data
        } catch (e) {
        }
      }
    }
  }

  Timer {
    id: mapDebounce
    interval: 250
    onTriggered: {
      if (!root.opened || !root.hasPosition || mapProc.running) return
      var width = Math.round(mapArea.width)
      var height = Math.round(mapArea.height)
      if (width <= 0 || height <= 0) return
      mapProc.command = root.command([
        "map", String(root.lat), String(root.lon), String(root.mapZoom),
        String(width), String(height)
      ])
      mapProc.running = true
    }
  }

  function planMap() {
    if (root.opened && root.hasPosition) mapDebounce.restart()
  }

  onMapZoomChanged: planMap()
  onTileUrlChanged: planMap()
  onLatChanged: planMap()
  onLonChanged: planMap()
  onOpenedChanged: {
    if (!opened) return
    refresh()
    planMap()
  }

  Process { id: browserProc }

  function openInMaps() {
    if (!hasPosition) return
    var url = mapsUrl.replace(/\{lat\}/g, String(lat)).replace(/\{lon\}/g, String(lon))
    browserProc.command = ["xdg-open", url]
    browserProc.running = true
    root.close()
  }

  function ago(seconds) {
    var value = Math.max(0, Math.round(seconds))
    if (value < 45) return "just now"
    if (value < 90) return "a minute ago"
    if (value < 3600) return Math.round(value / 60) + " minutes ago"
    if (value < 7200) return "an hour ago"
    if (value < 86400) return Math.round(value / 3600) + " hours ago"
    if (value < 172800) return "yesterday"
    return Math.round(value / 86400) + " days ago"
  }

  function chargingState(value) {
    var words = String(value || "not charging").toLowerCase().replace(/_/g, " ")
    return words.charAt(0).toUpperCase() + words.slice(1)
  }

  readonly property string titleText: {
    if (!hasReading) return "MY SKODA"
    return reading.name || reading.model || "MY SKODA"
  }
  readonly property string summary: {
    if (!hasReading) return errorText !== "" ? errorText : "Waiting for vehicle data"
    var state = charging ? "Charging" : chargingState(reading.charging_state)
    if (charging && reading.charge_power_kw !== null)
      state += " at " + reading.charge_power_kw + " kW"
    return state + " · fetched " + ago(readingAge)
  }
  readonly property string openText: {
    if (!hasReading || !reading.open || reading.open.length === 0) return ""
    return "Open: " + reading.open.join(", ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    iconComponent: Component {
      Text {
        text: "\uf1b9"
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }

    active: root.charging
    activeColor: root.chargingGreen
    dimmed: root.errorText !== "" && !root.hasReading
    tooltipText: root.hasReading
      ? root.plain(root.titleText + " · " + root.summary)
      : root.plain("MySkoda · " + root.summary)

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.openInMaps()
      else root.toggle()
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    triggerMode: "click"
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      spacing: Style.space(10)

      Item {
        width: parent.width
        height: Math.max(title.implicitHeight, stateBadge.implicitHeight)

        PanelSectionHeader {
          id: title
          anchors.left: parent.left
          anchors.right: stateBadge.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.titleText.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: stateBadge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: root.errorText !== "" ? Color.urgent
                 : root.charging ? root.chargingGreen : root.accent
            opacity: root.stale ? 0.5 : 1
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.charging ? "charging" : root.stale ? "stale" : "parked"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
          }
        }
      }

      Rectangle {
        id: mapArea
        width: parent.width
        height: Math.round(width * 2 / 3)
        radius: Style.space(6)
        color: Qt.rgba(0, 0, 0, 0.35)
        clip: true

        MapView {
          anchors.fill: parent
          plan: root.mapPlan
          lightMap: root.lightMap
          stale: root.stale
          foreground: root.foreground
          accent: root.charging ? root.chargingGreen : root.accent
          fontFamily: root.fontFamily
        }

        Text {
          anchors.centerIn: parent
          visible: !root.hasPosition
          text: root.hasReading ? "Location is unavailable" : "Waiting for the car"
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.65
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.hasPosition
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openInMaps()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          width: parent.width
          visible: root.showAddress && root.hasReading && !!root.reading.address
          text: visible ? root.reading.address : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
        }

        Text {
          width: parent.width
          text: root.summary
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.65
        }
      }

      PanelSeparator { width: parent.width }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.12)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.battery !== null ? root.reading.battery : 0) / 100))
            height: parent.height
            radius: parent.radius
            color: root.charging ? root.chargingGreen : root.accent
            opacity: 0.9

            Behavior on width {
              NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
            }
          }

          Rectangle {
            visible: root.hasReading && root.reading.target_charge !== null
            x: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.target_charge !== null
                ? root.reading.target_charge : 100) / 100)) - width / 2
            width: Math.max(1, Style.space(2))
            height: parent.height
            color: root.foreground
            opacity: 0.55
          }
        }

        Item {
          width: parent.width
          height: batteryLabel.implicitHeight

          Text {
            id: batteryLabel
            anchors.left: parent.left
            text: root.hasReading && root.reading.battery !== null
              ? root.reading.battery + "%" : "—"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }

          Text {
            anchors.right: parent.right
            text: root.hasReading && root.reading.range_km !== null
              ? root.reading.range_km + " km" : "—"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }
        }
      }

      PanelSeparator { width: parent.width }

      Grid {
        id: detailGrid
        width: parent.width
        columns: 2
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(10)

        Detail {
          label: "locked"
          value: !root.hasReading || !root.reading.lock_known
            ? "—" : root.reading.locked ? "yes" : "no"
        }
        Detail {
          label: "odometer"
          value: root.hasReading && root.reading.odometer_km !== null
            ? Number(root.reading.odometer_km).toLocaleString(Qt.locale(), "f", 0) + " km" : "—"
        }
        Detail {
          label: "charge target"
          value: root.hasReading && root.reading.target_charge !== null
            ? root.reading.target_charge + "%" : "—"
        }
        Detail {
          label: "time remaining"
          value: root.hasReading && root.reading.remaining_minutes !== null
            ? root.reading.remaining_minutes + " min" : "—"
        }
        Detail {
          label: "fuel"
          value: root.hasReading && root.reading.fuel !== null ? root.reading.fuel + "%" : "—"
        }
        Detail {
          label: "charge rate"
          value: root.hasReading && root.reading.charge_rate_kmh !== null
            ? root.reading.charge_rate_kmh + " km/h" : "—"
        }
        Detail {
          label: "model"
          value: root.hasReading && root.reading.model ? root.reading.model : "—"
        }
        Detail {
          label: "software"
          value: root.hasReading && root.reading.software ? root.reading.software : "—"
        }
      }

      Text {
        width: parent.width
        visible: root.openText !== ""
        text: root.openText
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.urgent
      }

      PanelSeparator { width: parent.width }

      Row {
        id: actions
        width: parent.width
        spacing: Style.space(6)
        readonly property int buttonWidth: Math.floor((width - spacing) / 2)

        Button {
          width: actions.buttonWidth
          text: "Open in maps"
          enabled: root.hasPosition
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openInMaps()
        }

        Button {
          width: actions.buttonWidth
          text: carProc.running ? "Refreshing…" : "Refresh"
          enabled: !carProc.running
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.refresh()
        }
      }

      Text {
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorText === "not signed in"
          ? "Run  bin/myskoda login  once in a terminal."
          : root.errorHint !== "" ? root.errorHint : root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.errorText === "refresh failed" ? root.foreground : Color.urgent
        opacity: 0.75
      }
    }
  }

  component Detail: Column {
    property string label: ""
    property string value: ""

    width: Math.floor((detailGrid.width - Style.space(8)) / 2)
    spacing: Style.space(2)

    Text {
      text: label
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
    }

    Text {
      width: parent.width
      text: value
      textFormat: Text.PlainText
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
    }
  }

  IpcHandler {
    target: "community.myskoda.test"

    function refresh(): string {
      root.refresh()
      return "refreshing"
    }
  }
}
