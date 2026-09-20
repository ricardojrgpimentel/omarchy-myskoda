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
  readonly property bool lightForeground:
    (0.2126 * foreground.r + 0.7152 * foreground.g + 0.0722 * foreground.b) > 0.5

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
  readonly property string tileUrl: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

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
  property string setupMessage: ""
  property double now: Date.now()

  readonly property bool hasReading: reading !== null && reading.ok === true
  readonly property bool charging: hasReading && reading.charging === true
  readonly property string powertrain: hasReading ? (reading.powertrain || "unknown") : "unknown"
  readonly property bool combustion: powertrain === "combustion"
  readonly property bool hybrid: powertrain === "hybrid"
  readonly property var primaryLevel: !hasReading ? null : combustion ? reading.fuel : reading.battery
  readonly property bool stale: hasReading && (reading.stale === true || readingAge > 3600)
  readonly property bool hasPosition:
    hasReading && reading.lat !== null && reading.lon !== null
  readonly property real lat: hasPosition ? reading.lat : 0
  readonly property real lon: hasPosition ? reading.lon : 0
  readonly property real readingAge:
    hasReading ? Math.max(0, now / 1000 - reading.at) : 0
  readonly property bool keyExpiringSoon: {
    if (!hasReading || !reading.api_key_expires_at) return false
    var expiry = Date.parse(reading.api_key_expires_at)
    return !isNaN(expiry) && expiry - root.now < 7 * 24 * 60 * 60 * 1000
  }

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
        if (data.ok !== true) {
          if (data.vin) vinField.text = data.vin
          // Do not keep showing a prior fixture or cached vehicle reading
          // after sign-out. This makes the account setup flow visible at once.
          if (data.error === "not configured"
              || data.error === "Public API key required"
              || data.error === "API key expired"
              || data.error === "API key not authorized"
              || data.error === "vehicle not found") {
            root.reading = null
            root.mapPlan = null
            root.setupMessage = data.hint || data.error
          }
          return
        }
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
    if (!opened) {
      apiKeyField.revealed = false
      return
    }
    planMap()
  }

  Process { id: browserProc }

  Process {
    id: connectProc
    stdinEnabled: true
    property string pendingKey: ""

    onStarted: {
      write(pendingKey + "\n")
      pendingKey = ""
      apiKeyField.text = ""
    }

    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok !== true) {
            root.setupMessage = data.hint || data.error || "Could not connect MySkoda."
            return
          }
          root.reading = data
          root.errorText = data.error || ""
          root.errorHint = data.hint || ""
          root.setupMessage = "MySkoda API key connected."
          root.planMap()
        } catch (e) {
          root.setupMessage = "Could not connect MySkoda."
        }
      }
    }
  }

  Process {
    id: logoutProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.reading = null
        root.mapPlan = null
        root.errorText = "not configured"
        root.errorHint = ""
        root.setupMessage = ""
        apiKeyField.text = ""
      }
    }
  }

  function openKeySetup() {
    if (browserProc.running) return
    browserProc.command = ["xdg-open", "https://public.api.connect.skoda-auto.cz/docs"]
    browserProc.running = true
  }

  function connect() {
    var selectedVin = vinField.text.trim().toUpperCase()
    var key = apiKeyField.text.trim()
    if (!/^[A-Z0-9]{17}$/.test(selectedVin)) {
      setupMessage = "Enter the 17-character VIN associated with the API key."
      return
    }
    if (key === "") {
      setupMessage = "Paste the API key created in the MySkoda app."
      return
    }
    if (connectProc.running) return
    setupMessage = "Checking the API key and vehicle…"
    connectProc.pendingKey = key
    connectProc.command = [root.script, "configure", selectedVin]
    connectProc.running = true
  }

  function logout() {
    if (logoutProc.running) return
    logoutProc.command = [root.script, "logout"]
    logoutProc.running = true
  }

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

  function keyExpiry(value) {
    if (!value) return "—"
    return String(value).slice(0, 10)
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
      Image {
        width: Style.bar.iconFont
        height: Style.bar.iconFont
        source: Qt.resolvedUrl(root.lightForeground ? "assets/skoda-light.svg" : "assets/skoda.svg")
        fillMode: Image.PreserveAspectFit
        smooth: true
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

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: root.hasReading ? content : vinField
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      spacing: Style.space(10)
      Keys.onEscapePressed: root.close()

      Item {
        width: parent.width
        height: Math.max(title.implicitHeight, stateBadge.implicitHeight)
        visible: root.hasReading

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

          PanelActionButton {
            iconText: "󰍃"
            tooltipText: "Sign out"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !logoutProc.running
            onClicked: root.logout()
          }
        }
      }

      Column {
        width: parent.width
        visible: !root.hasReading
        spacing: Style.space(8)

        Text {
          width: parent.width
          text: "CONNECT MYŠKODA"
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
          color: root.foreground
          opacity: 0.8
        }

        Text {
          width: parent.width
          text: "Create an API key in the MyŠkoda app, select your vehicle, then paste the key below. The key is sent directly to the official public API."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.72
        }

        Button {
          width: parent.width
          text: "Open official API key setup"
          enabled: !browserProc.running && !connectProc.running
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openKeySetup()
        }

        TextField {
          id: vinField
          width: parent.width
          enabled: !connectProc.running
          text: root.vin
          placeholderText: "VIN — 17 characters"
          foreground: root.foreground
          font.family: root.fontFamily
          maximumLength: 17
          inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhNoPredictiveText
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              apiKeyField.forceActiveFocus()
              event.accepted = true
            }
          }
        }

        TextField {
          id: apiKeyField
          property bool revealed: false
          width: parent.width
          enabled: !connectProc.running
          placeholderText: "Paste MyŠkoda API key"
          echoMode: revealed ? TextInput.Normal : TextInput.Password
          rightPadding: revealKeyButton.width + Style.space(12)
          onTextChanged: if (text === "") revealed = false
          inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
          foreground: root.foreground
          font.family: root.fontFamily
          PanelActionButton {
            id: revealKeyButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            iconText: apiKeyField.revealed ? "󰈉" : "󰈈"
            tooltipText: apiKeyField.revealed ? "Hide API key" : "Show API key"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            Accessible.name: tooltipText
            onClicked: {
              apiKeyField.revealed = !apiKeyField.revealed
              apiKeyField.forceActiveFocus()
            }
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.connect()
              event.accepted = true
            }
          }
        }

        Button {
          width: parent.width
          text: connectProc.running ? "Connecting…" : "Save and connect"
          enabled: vinField.text.trim().length === 17
            && apiKeyField.text.trim() !== "" && !connectProc.running
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.connect()
        }

        Text {
          width: parent.width
          visible: root.setupMessage !== ""
          text: root.setupMessage
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.setupMessage.indexOf("Could not") === 0
              || root.setupMessage.indexOf("Paste") === 0
              || root.setupMessage.indexOf("Enter") === 0
            ? Color.urgent : root.foreground
          opacity: 0.75
        }
      }

      PanelSeparator {
        visible: !root.hasReading
        width: parent.width
      }

      Rectangle {
        id: mapArea
        width: parent.width
        visible: root.hasReading
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
        visible: root.hasReading
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

      PanelSeparator { width: parent.width; visible: root.hasReading }

      Column {
        width: parent.width
        visible: root.hasReading
        spacing: Style.space(4)

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.12)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(1,
              (root.primaryLevel !== null ? root.primaryLevel : 0) / 100))
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
            text: root.primaryLevel !== null ? root.primaryLevel + "%" : "—"
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

      PanelSeparator { width: parent.width; visible: root.hasReading }

      Grid {
        id: detailGrid
        width: parent.width
        visible: root.hasReading
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
          visible: !root.combustion
          value: root.hasReading && root.reading.target_charge !== null
            ? root.reading.target_charge + "%" : "—"
        }
        Detail {
          label: "time remaining"
          visible: !root.combustion
          value: root.hasReading && root.reading.remaining_minutes !== null
            ? root.reading.remaining_minutes + " min" : "—"
        }
        Detail {
          label: "fuel"
          visible: root.hybrid
          value: root.hasReading && root.reading.fuel !== null ? root.reading.fuel + "%" : "—"
        }
        Detail {
          label: "charge rate"
          visible: !root.combustion
          value: root.hasReading && root.reading.charge_rate_kmh !== null
            ? root.reading.charge_rate_kmh + " km/h" : "—"
        }
        Detail {
          label: "license plate"
          value: root.hasReading && root.reading.license_plate ? root.reading.license_plate : "—"
        }
        Detail {
          label: "key expires"
          value: root.hasReading ? root.keyExpiry(root.reading.api_key_expires_at) : "—"
        }
      }

      Text {
        width: parent.width
        visible: root.hasReading && root.openText !== ""
        text: root.openText
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.urgent
      }

      PanelSeparator { width: parent.width; visible: root.hasReading }

      Row {
        id: actions
        width: parent.width
        visible: root.hasReading
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
        visible: root.hasReading && root.errorText !== ""
        text: root.errorHint !== "" ? root.errorHint : root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.errorText === "refresh failed" ? root.foreground : Color.urgent
        opacity: 0.75
      }

      Text {
        width: parent.width
        visible: root.keyExpiringSoon
        text: "The MyŠkoda API key expires on " + root.keyExpiry((root.reading || {}).api_key_expires_at)
          + ". Renew it in the app, then sign out and connect the new key."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: Color.urgent
        opacity: 0.85
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
