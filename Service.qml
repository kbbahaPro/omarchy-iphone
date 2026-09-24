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
  // True once we have actually seen the phone, so a shell restart while the
  // phone is away can never trigger a lock on its own.
  // The connection the newest notification belongs to; ids from earlier
  // sessions can no longer be acted on.
  property int currentSession: 0
  property bool _everConnected: false
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
  // The call currently ringing, if any. items are newest-first, and the phone
  // removes the notification the moment the call ends, which closes the
  // dialog on its own.
  property int _handledCallId: 0
  readonly property var activeCall: {
    for (var i = 0; i < items.length; i++) {
      var e = items[i]
      if (Number(e.category || 0) === 1 && e.id !== _handledCallId) return e
    }
    return null
  }

  readonly property var threads: Model.threadItems(items)
  readonly property int phonePending: Model.phonePending(items)
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

  // Lock the desktop when the phone walks away. Off by default: it is a big
  // behavioural change, and getting it wrong locks you out repeatedly.
  readonly property bool proximityLock: setting("proximityLock", false) === true
  readonly property int proximityLockDelay: {
    var n = parseInt(String(setting("proximityLockDelay", 60)), 10)
    if (!isFinite(n)) n = 60
    return Math.max(10, Math.min(900, n))
  }

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
      var wasConnected = connected
      connected = event.connected === true
      if (connected) _everConnected = true
      deviceName = String(event.deviceName || "")
      if (wasConnected !== connected) onPresenceChanged(connected)
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

  // ANCS category 1. A call is the one notification you cannot deal with later.
  function handleIncomingCall(entry) {
    mediaPauseProcess.command = [pluginDir + "bin/omarchy-iphone-media", "pause-all"]
    mediaPauseProcess.running = true

    var who = String(entry.title || "").trim()
    callToastProcess.command = [
      "notify-send", "-a", "iPhone", "-u", "critical", "--",
      "Incoming call" + (who !== "" ? " — " + who : ""),
      String(entry.body || "Answer or decline from the panel")
    ]
    callToastProcess.running = true
  }

  function receive(entry) {
    var known = false
    for (var i = 0; i < items.length; i++) {
      if (items[i].id === entry.id) { known = true; break }
    }
    var session = Number(entry.session || 0)
    if (session !== 0 && session !== currentSession) currentSession = session
    items = Model.upsert(items, entry, historyLimit)
    // An ANCS "modified" resend of a notification already on screen should
    // not bump the badge a second time.
    if (!known) unread = unread + 1

    // Calls bypass every other rule, including focus mode and the silent flag.
    if (Number(entry.category || 0) === 1 && entry.preexisting !== true) {
      handleIncomingCall(entry)
      return
    }

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

  // --- proximity lock ---------------------------------------------------

  function onPresenceChanged(nowConnected) {
    if (!proximityLock || !_everConnected) return

    if (nowConnected) {
      if (proximityTimer.running) {
        proximityTimer.stop()
        notify("iPhone back in range", "Lock cancelled")
      }
      return
    }

    // A brief BLE drop is common, so warn and wait rather than locking at once.
    proximityTimer.interval = proximityLockDelay * 1000
    proximityTimer.restart()
    notify("iPhone out of range",
           "Locking in " + proximityLockDelay + "s unless it comes back")
  }

  function notify(title, body) {
    notifyProcess.command = ["notify-send", "-a", "iPhone", "--", title, body]
    notifyProcess.running = true
  }

  Timer {
    id: proximityTimer
    repeat: false
    onTriggered: {
      // Re-check: the phone may have returned between the last signal and now.
      if (!root.proximityLock || root.connected) return
      lockProcess.command = ["omarchy", "system", "lock"]
      lockProcess.running = true
    }
  }

  // Answering and declining hide the dialog at once rather than waiting for
  // the phone to confirm: the action is irreversible either way, and a card
  // that lingers after the click feels broken.
  // Preview the call dialog without waiting for someone to ring you. The
  // entry carries the current session so the buttons behave exactly as they
  // would for a real call; acting on it is a harmless no-op on the phone.
  function simulateCall(name) {
    var fake = {
      id: -1,
      appId: "com.apple.mobilephone",
      appName: "Phone",
      title: String(name || "Test Caller"),
      subtitle: "",
      body: "mobile",
      deviceName: deviceName,
      deviceHandle: "",
      positiveAction: "Answer",
      negativeAction: "Decline",
      category: 1,
      categoryCount: 1,
      silent: false,
      important: true,
      preexisting: false,
      session: currentSession,
      ts: Date.now() / 1000
    }
    _handledCallId = 0
    items = Model.upsert(items, fake, historyLimit)
  }

  function clearSimulatedCall() {
    items = Model.removeById(items, -1)
  }

  function answerCall() {
    var c = activeCall
    if (!c) return
    _handledCallId = c.id
    invoke(c, "positive")
  }

  function declineCall() {
    var c = activeCall
    if (!c) return
    _handledCallId = c.id
    items = Model.removeById(items, c.id)
    invoke(c, "negative")
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
  // Actions are queued rather than fired straight at the Process: assigning
  // `command` and re-setting `running` on a Process that is already running
  // is a no-op, so dismissing a thread used to send one action and silently
  // drop the rest.
  property var _actionQueue: []

  function invoke(entry, kind) {
    if (!entry || !entry.deviceHandle) return
    if (!Model.isActionable(entry, currentSession)) {
      // Fail loudly: the write would otherwise succeed and do nothing.
      lastError = "Too old to act on — the phone reconnected since this arrived"
      return
    }
    var queue = _actionQueue.slice()
    queue.push([
      bridgePath, "invoke",
      "--handle", String(entry.deviceHandle),
      "--id", String(entry.id),
      "--kind", kind
    ])
    _actionQueue = queue
    pumpActions()
  }

  // Exercised from IPC to prove whether the panel's action path reaches the
  // phone, without needing a live call to click on.
  function actOnNewest(kind) {
    if (items.length === 0) return "no notifications"
    var e = items[0]
    if (!e.deviceHandle) return "entry has no deviceHandle"
    lastError = ""
    invoke(e, kind)
    return "invoked " + kind + " on id=" + e.id + " app=" + e.appName
           + " queue=" + _actionQueue.length + " running=" + actionProcess.running
  }

  function pumpActions() {
    if (actionProcess.running || _actionQueue.length === 0) return
    var queue = _actionQueue.slice()
    var next = queue.shift()
    _actionQueue = queue
    actionProcess.command = next
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

  // Dismissing a thread clears every message in it, here and on the phone.
  function dismissThread(group) {
    if (!group) return
    var ids = group.ids || []
    var remaining = []
    for (var i = 0; i < items.length; i++) {
      if (ids.indexOf(items[i].id) === -1) remaining.push(items[i])
      else invoke(items[i], "negative")
    }
    items = remaining
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
  Process { id: notifyProcess; running: false; command: [] }
  Process { id: mediaPauseProcess; running: false; command: [] }
  Process { id: callToastProcess; running: false; command: [] }
  Process { id: lockProcess; running: false; command: [] }
  Process { id: codeToastProcess; running: false; command: [] }
  Process { id: focusToastProcess; running: false; command: [] }
  Process { id: toastProcess; running: false; command: [] }
  Process { id: clearProcess; running: false; command: [] }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function (line) { root.handleLine(line) } }
    stderr: SplitParser {
      onRead: function (line) {
        var text = String(line || "").trim()
        // Surface failures instead of swallowing them: the daemon silently
        // ignores an action whose device handle it does not recognise.
        if (text !== "") root.lastError = text
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "Notification action failed"
      root.pumpActions()
    }
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
