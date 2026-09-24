import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns all iPhone state: the long-lived bridge process, the notification
// list, unread tracking, and outgoing actions. The panel is a pure view
// over this.
Item {
  id: root

  property var settings: ({})
  // Absolute path to this plugin's directory, supplied by Panel.qml so the
  // helper resolves wherever the plugin is installed.
  property string pluginDir: ""

  readonly property string bridgePath: pluginDir + "bin/omarchy-iphone-bridge"
  readonly property string amsPath: pluginDir + "bin/omarchy-iphone-ams"

  // --- live state -----------------------------------------------------
  property bool observerUp: false
  // False until the ancs4linux system daemon has actually been installed.
  property bool daemonInstalled: false
  property bool connected: false
  property string deviceName: ""
  // -1 when unknown; BlueZ only reports it while the phone is connected.
  property int phoneBattery: -1
  property var items: []
  property int unread: 0
  property string lastError: ""
  property string pairingCode: ""
  property string actionStatus: ""
  property bool advertising: false

  // --- Apple Media Service (now playing over the same BLE link) ---
  // Focus mode: everything stays silent except the VIP list, so deep work is
  // protected without the fear of missing the one call that matters.
  property bool focusMode: false
  property string lastCode: ""

  property bool amsAvailable: false
  property string npTitle: ""
  property string npArtist: ""
  property string npAlbum: ""
  property string npPlayer: ""
  property string npPlayback: ""
  readonly property bool npPlaying: npPlayback === "playing"
  readonly property bool hasNowPlaying: amsAvailable && (npTitle !== "" || npArtist !== "")

  readonly property bool ready: observerUp
  readonly property bool batteryKnown: connected && phoneBattery >= 0
  readonly property bool batteryLow: batteryKnown && phoneBattery <= 20
  readonly property string statusText: {
    if (focusMode) return vipApps.length > 0 ? "Focus — VIP only" : "Focus — all silent"
    if (!daemonInstalled) return "Setup needed"
    if (!observerUp) return "Bridge not running"
    if (advertising) return "Ready to pair — open Bluetooth on your iPhone"
    if (connected) {
      var who = deviceName !== "" ? deviceName : "iPhone"
      return batteryKnown ? who + " · " + phoneBattery + "%" : who + " connected"
    }
    return "Waiting for iPhone"
  }

  // --- settings -------------------------------------------------------
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int historyLimit: {
    var n = parseInt(String(setting("historyLimit", 200)), 10)
    if (!isFinite(n)) n = 200
    return Math.max(10, Math.min(2000, n))
  }
  readonly property bool showToasts: setting("showToasts", true) === true
  readonly property string advertiseName: String(setting("advertiseName", "Omarchy"))
  readonly property var mutedApps: Model.normalizeList(setting("mutedApps", ""))
  // People and apps allowed to interrupt focus mode.
  readonly property var vipApps: Model.normalizeList(setting("vipApps", ""))
  readonly property bool autoCopyCodes: setting("autoCopyCodes", true) === true

  // --- incoming events -------------------------------------------------
  function handleLine(line) {
    var event = Model.parseLine(line)
    if (!event) return

    if (event.type === "history") {
      items = Model.sortNewestFirst(event.items || [], historyLimit)
      return
    }
    if (event.type === "status") {
      observerUp = event.observer === true
      daemonInstalled = event.installed === true
      connected = event.connected === true
      deviceName = String(event.deviceName || "")
      phoneBattery = event.battery === undefined ? -1 : Number(event.battery)
      if (observerUp) lastError = ""
      // A phone that has actually connected makes the advertising banner
      // stale, whether or not this session started the advertising.
      if (connected) advertising = false
      return
    }
    if (event.type === "notification") {
      receive(event)
      return
    }
    if (event.type === "dismiss") {
      // Cleared on the phone — mirror that here so the two stay in step.
      items = Model.removeById(items, event.id)
      return
    }
    if (event.type === "pairingCode") {
      pairingCode = String(event.code || "")
      actionStatus = "Pairing code: " + pairingCode
      return
    }
    if (event.type === "advertising") {
      advertising = true
      actionStatus = "Advertising as \"" + String(event.name || advertiseName) + "\""
      return
    }
    if (event.type === "error") {
      lastError = String(event.message || "Unknown error")
      return
    }
  }

  function handleAmsLine(line) {
    var event = Model.parseLine(line)
    if (!event) return
    if (event.type === "status") {
      amsAvailable = event.available === true
      return
    }
    if (event.type === "nowplaying") {
      amsAvailable = true
      npTitle = String(event.title || "")
      npArtist = String(event.artist || "")
      npAlbum = String(event.album || "")
      npPlayer = String(event.player || "")
      npPlayback = String(event.playback || "")
    }
  }

  // Transport control straight to the phone, no audio link required.
  function mediaCommand(name) {
    amsCommandProcess.command = [amsPath, "command", name]
    amsCommandProcess.running = true
  }

  function receive(entry) {
    var known = false
    for (var i = 0; i < items.length; i++) {
      if (items[i].id === entry.id) { known = true; break }
    }
    items = Model.upsert(items, entry, historyLimit)
    // An ANCS "modified" resend of a notification already on screen should
    // not bump the badge a second time.
    if (!known) unread = unread + 1

    // Login codes are worth acting on even in focus mode: you only ever see
    // one because you just asked for it.
    var code = Model.extractOtp(entry)
    if (autoCopyCodes && code !== "" && code !== lastCode) {
      lastCode = code
      copyCode(code, Model.displayAppName(entry))
      return
    }

    if (!showToasts) return
    if (Model.isMuted(entry, mutedApps)) return
    // iOS asked for this one to be delivered quietly. Honour it.
    if (entry.silent === true) return
    // Replayed from the phone's backlog on reconnect: worth showing in the
    // panel, not worth a burst of popups for things that already happened.
    if (entry.preexisting === true) return
    // In focus mode only urgent notifications get through: calls, voicemail,
    // anything iOS flagged important, plus the user's own VIP list.
    if (focusMode && !Model.isUrgent(entry) && !Model.isVip(entry, vipApps)) return
    raiseToast(entry)
  }

  // Codes are digits only, so this is safe to hand to a shell.
  function copyCode(code, appName) {
    copyProcess.command = ["sh", "-c", "printf %s '" + code + "' | wl-copy"]
    copyProcess.running = true
    codeToastProcess.command = [
      "notify-send", "-a", appName + " · iPhone", "-u", "critical",
      "--", "Code " + code + " copied", "Paste it with Ctrl+V"
    ]
    codeToastProcess.running = true
  }

  function setFocus(on) {
    focusMode = on === true
    focusToastProcess.command = [
      "notify-send", "-a", "iPhone",
      focusMode ? "Focus on" : "Focus off",
      focusMode
        ? (vipApps.length > 0 ? "Only VIPs will interrupt" : "All iPhone popups silenced")
        : "iPhone popups restored"
    ]
    focusToastProcess.running = true
  }

  function toggleFocus() { setFocus(!focusMode) }

  // Toasts go through the ordinary freedesktop path, so Omarchy's own
  // notification service handles Do Not Disturb, styling, and history.
  function raiseToast(entry) {
    var appName = Model.displayAppName(entry)
    var title = String(entry.title || "").trim()
    var body = String(entry.body || "").trim()
    var label = Model.categoryLabel(entry)
    if (title === "" && body === "") {
      // A call with no text still matters, so fall back to the category.
      if (label === "") return
      title = label
    }
    toastProcess.command = [
      "notify-send",
      "-a", appName + " · iPhone",
      "-u", Model.isUrgent(entry) ? "critical" : "normal",
      "--",
      title !== "" ? title : appName,
      body
    ]
    toastProcess.running = true
  }

  // --- outgoing actions -------------------------------------------------
  function invoke(entry, kind) {
    if (!entry || !entry.deviceHandle) return
    actionProcess.command = [
      bridgePath, "invoke",
      "--handle", String(entry.deviceHandle),
      "--id", String(entry.id),
      "--kind", kind
    ]
    actionProcess.running = true
  }

  // Dismissing here clears it on the phone too — that is the whole point of
  // not having to pick the phone up.
  function dismiss(entry) {
    if (!entry) return
    items = Model.removeById(items, entry.id)
    invoke(entry, "negative")
  }

  function accept(entry) {
    if (!entry) return
    items = Model.removeById(items, entry.id)
    invoke(entry, "positive")
  }

  function clearAll() {
    for (var i = 0; i < items.length; i++) invoke(items[i], "negative")
    items = []
    unread = 0
    clearProcess.command = [bridgePath, "clear"]
    clearProcess.running = true
  }

  function markRead() {
    unread = 0
  }

  function startPairing() {
    actionStatus = "Starting Bluetooth advertising…"
    pairProcess.command = [bridgePath, "pair", "--name", advertiseName]
    pairProcess.running = true
  }

  // --- processes --------------------------------------------------------

  // The bridge is long-lived: it streams history first, then live events.
  // Quickshell restarts it if it dies, via the retry timer below.
  Process {
    id: bridge
    running: false
    command: [root.bridgePath, "listen", "--limit", String(root.historyLimit)]
    stdout: SplitParser { onRead: function (line) { root.handleLine(line) } }
    stderr: SplitParser {
      onRead: function (line) {
        var text = String(line || "").trim()
        if (text !== "") root.lastError = text
      }
    }
    onExited: function (exitCode) {
      root.observerUp = false
      root.connected = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "iPhone bridge stopped unexpectedly"
      retryTimer.restart()
    }
  }

  Timer {
    id: retryTimer
    interval: 5000
    repeat: false
    onTriggered: if (!bridge.running && root.pluginDir !== "") bridge.running = true
  }

  // AMS exits immediately when the phone is away, so this is retried rather
  // than kept running; the retry timer below owns restarting it.
  Process {
    id: amsProcess
    running: false
    command: [root.amsPath, "listen"]
    stdout: SplitParser { onRead: function (line) { root.handleAmsLine(line) } }
    onExited: function () {
      root.amsAvailable = false
      amsRetry.restart()
    }
  }

  Timer {
    id: amsRetry
    interval: 10000
    repeat: false
    onTriggered: if (!amsProcess.running && root.pluginDir !== "") amsProcess.running = true
  }

  Process { id: amsCommandProcess; running: false; command: [] }
  Process { id: copyProcess; running: false; command: [] }
  Process { id: codeToastProcess; running: false; command: [] }
  Process { id: focusToastProcess; running: false; command: [] }
  Process { id: toastProcess; running: false; command: [] }
  Process { id: clearProcess; running: false; command: [] }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function (line) { root.handleLine(line) } }
  }

  Process {
    id: pairProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function (line) { root.handleLine(line) } }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.actionStatus = ""
    }
  }

  // Start once the panel has told us where the plugin lives.
  function startAll() {
    if (pluginDir === "") return
    if (!bridge.running) bridge.running = true
    if (!amsProcess.running) amsProcess.running = true
  }

  onPluginDirChanged: startAll()
  Component.onCompleted: startAll()
}
