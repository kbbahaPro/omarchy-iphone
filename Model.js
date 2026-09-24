.pragma library

// Pure helpers for the iPhone plugin. Kept out of QML so the panel stays
// declarative and this logic can be reasoned about on its own.

function parseLine(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// "now", "4m", "2h", "Tue 09:15" — short enough for a dense list, precise
// enough to tell a notification from ten seconds ago from one from lunchtime.
function relativeTime(ts, nowMs) {
  var then = Number(ts) * 1000
  if (!isFinite(then) || then <= 0) return ""
  var deltaSec = Math.max(0, Math.floor((nowMs - then) / 1000))
  if (deltaSec < 45) return "now"
  if (deltaSec < 3600) return Math.floor(deltaSec / 60) + "m"
  if (deltaSec < 86400) return Math.floor(deltaSec / 3600) + "h"
  var date = new Date(then)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var hh = ("0" + date.getHours()).slice(-2)
  var mm = ("0" + date.getMinutes()).slice(-2)
  if (deltaSec < 7 * 86400) return days[date.getDay()] + " " + hh + ":" + mm
  return (date.getMonth() + 1) + "/" + date.getDate()
}

function absoluteTime(ts) {
  var then = Number(ts) * 1000
  if (!isFinite(then) || then <= 0) return ""
  var date = new Date(then)
  var hh = ("0" + date.getHours()).slice(-2)
  var mm = ("0" + date.getMinutes()).slice(-2)
  return date.toDateString() + " " + hh + ":" + mm
}

// ANCS gives a reverse-DNS bundle id. Map the ones that matter at work to a
// Nerd Font glyph; everything else falls back to a generic bell.
var APP_GLYPHS = [
  [/slack/i, ""],
  [/whatsapp/i, ""],
  [/messenger|facebook/i, ""],
  [/telegram/i, ""],
  [/discord/i, ""],
  [/mobilemail|outlook|gmail|mail/i, ""],
  [/mobilesms|messages|signal/i, ""],
  [/mobilephone|facetime/i, ""],
  [/mobilecal|calendar/i, ""],
  [/reminders|things|todoist/i, ""],
  [/zoom|teams|meet/i, ""],
  [/github/i, ""],
  [/linkedin/i, ""],
  [/spotify|music/i, ""],
  [/bank|pay|wallet|revolut|stripe/i, ""]
]

function appGlyph(appId, appName) {
  var hay = String(appId || "") + " " + String(appName || "")
  for (var i = 0; i < APP_GLYPHS.length; i++) {
    if (APP_GLYPHS[i][0].test(hay)) return APP_GLYPHS[i][1]
  }
  return ""
}

// ANCS bundle ids are ugly ("com.apple.MobileSMS"). Prefer the display name
// the phone sent; fall back to the last meaningful id segment.
function displayAppName(entry) {
  var name = String(entry.appName || "").trim()
  if (name !== "" && name.indexOf(".") === -1) return name
  var id = String(entry.appId || name || "")
  var parts = id.split(".")
  var tail = parts.length > 0 ? parts[parts.length - 1] : id
  return tail === "" ? "Unknown" : tail
}

function normalizeList(value) {
  var raw = String(value || "")
  if (raw.trim() === "") return []
  return raw.split(",").map(function (s) { return s.trim().toLowerCase() })
            .filter(function (s) { return s !== "" })
}

// A muted app still lands in the panel; it just never raises a toast.
function isMuted(entry, mutedList) {
  if (!mutedList || mutedList.length === 0) return false
  var hay = (String(entry.appId || "") + " " + String(entry.appName || "")).toLowerCase()
  for (var i = 0; i < mutedList.length; i++) {
    if (hay.indexOf(mutedList[i]) !== -1) return true
  }
  return false
}

// Insert newest-first, replacing any earlier copy of the same notification.
// ANCS re-sends an id when a notification is modified on the phone.
function upsert(items, entry, limit) {
  var next = []
  for (var i = 0; i < items.length; i++) {
    if (items[i].id !== entry.id) next.push(items[i])
  }
  next.unshift(entry)
  if (next.length > limit) next = next.slice(0, limit)
  return next
}

function removeById(items, id) {
  var next = []
  for (var i = 0; i < items.length; i++) {
    if (items[i].id !== id) next.push(items[i])
  }
  return next
}

function sortNewestFirst(items, limit) {
  var copy = (items || []).slice()
  copy.sort(function (a, b) { return Number(b.ts || 0) - Number(a.ts || 0) })
  return copy.slice(0, limit)
}

function badgeText(count) {
  if (count <= 0) return ""
  return count > 99 ? "99+" : String(count)
}

function summaryLine(entry) {
  var title = String(entry.title || "").trim()
  var body = String(entry.body || "").trim()
  if (title !== "" && body !== "") return title + " — " + body
  return title !== "" ? title : body
}

// --- One-time passcodes -------------------------------------------------
//
// Login codes arrive as ordinary notifications. Pulling them out and putting
// them on the clipboard removes the unlock-read-memorise-type loop that a
// dozen SaaS logins a day otherwise costs.

// A bare number is not a code. Requiring one of these words nearby keeps
// order totals, prices, flight numbers and years out of the clipboard.
var OTP_CONTEXT = /\b(code|otp|passcode|pass ?code|verification|verify|verifica|2fa|two[- ]factor|one[- ]time|security|auth(entication)?|token|pin)\b/i

// Codes are usually 4-8 digits, sometimes split by a space or dash (123-456).
var OTP_PATTERNS = [
  /\b(\d{3})[- ](\d{3})\b/,
  /\b(\d{4,8})\b/
]

function extractOtp(entry) {
  var hay = String(entry.title || "") + " " + String(entry.body || "")
  if (!OTP_CONTEXT.test(hay)) return ""

  for (var i = 0; i < OTP_PATTERNS.length; i++) {
    var m = hay.match(OTP_PATTERNS[i])
    if (!m) continue
    var code = m.length > 2 && m[2] !== undefined ? m[1] + m[2] : m[1]
    // A four-digit number that looks like a year is far more often prose
    // ("since 2019") than a passcode.
    if (code.length === 4 && /^(19|20)\d\d$/.test(code)) continue
    return code
  }
  return ""
}

// Does this notification come from someone who is allowed to interrupt?
function isVip(entry, vipList) {
  if (!vipList || vipList.length === 0) return false
  var hay = (String(entry.appId || "") + " " + String(entry.appName || "") + " "
             + String(entry.title || "")).toLowerCase()
  for (var i = 0; i < vipList.length; i++) {
    if (hay.indexOf(vipList[i]) !== -1) return true
  }
  return false
}
