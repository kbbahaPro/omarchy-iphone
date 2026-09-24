# iPhone Bridge

Your iPhone's notifications, music and battery in the Omarchy bar, so you can
work without picking the phone up.

Dismiss a notification here and it clears on the phone. Skip a track without
routing audio through the desktop. Login codes land on your clipboard by
themselves. Focus mode silences everything except the people you choose.

It uses **ANCS** (Apple Notification Center Service) — the same Bluetooth LE
protocol an Apple Watch or a Garmin uses. No jailbreak, no app on the phone,
no cloud account, nothing leaves the machine.

## What you get

- An iPhone glyph in the bar with an unread badge, dimmed while the phone is
  out of range.
- A panel listing recent notifications: app, title, body, relative time.
- **Dismiss from the desktop** — clearing a notification here clears it on the
  phone too, and clearing it on the phone clears it here.
- Positive actions where iOS offers one (answer a call, accept an invite).
- Desktop toasts through the normal notification path, so Omarchy's Do Not
  Disturb and styling apply.
- History kept across restarts, capped (200 by default).

## Install

```bash
omarchy plugin add https://github.com/kbbahaPro/omarchy-iphone.git --enable
```

The widget appears immediately, but it needs a system daemon to talk to the
phone. **Read `install-ancs4linux.sh` before running it** — it installs
system services as root:

```bash
sudo ~/.config/omarchy/plugins/io.github.kbbahapro.iphone/install-ancs4linux.sh
```

It installs `python-dasbus` and `python-typer` from the official repos, puts
[ancs4linux](https://github.com/pzmarzly/ancs4linux) in `/opt`, writes a D-Bus
policy and two systemd units, and starts them. Nothing runs automatically —
until you run it, the panel simply says "Setup needed" and shows the command.

Then pair the phone (see [Pairing](#pairing)).

## Uninstall

Remove the plugin:

```bash
omarchy plugin remove io.github.kbbahapro.iphone
```

Remove the system daemon, if you want it gone too:

```bash
sudo systemctl disable --now ancs4linux-observer ancs4linux-advertising
sudo rm -rf /opt/ancs4linux \
            /usr/local/bin/ancs4linux-observer \
            /usr/local/bin/ancs4linux-advertising \
            /usr/local/bin/ancs4linux-ctl \
            /usr/lib/systemd/system/ancs4linux-observer.service \
            /usr/lib/systemd/system/ancs4linux-advertising.service \
            /etc/dbus-1/system.d/ancs4linux-observer.conf \
            /etc/dbus-1/system.d/ancs4linux-advertising.conf \
            /etc/dbus-1/system.d/ancs4linux-omarchy-user.conf
sudo groupdel ancs4linux
sudo systemctl daemon-reload
```

Stored notification history:

```bash
rm -rf ~/.local/state/omarchy/iphone
```

`python-dasbus` and `python-typer` are ordinary repo packages and are left in
place; remove them with `pacman -Rs` if nothing else needs them. Finally,
forget the pairing on the phone: Settings → Bluetooth → ⓘ → Forget This Device.

## Architecture

```
iPhone ──BLE/ANCS──► bluetoothd ──► ancs4linux-observer   (root, system D-Bus)
                                          │  ShowNotification / DismissNotification
                                          ▼
                              bin/omarchy-iphone-bridge   (this plugin, per-user)
                                          │  JSON lines on stdout
                                          ▼
                              Service.qml ──► Panel.qml   (inside omarchy-shell)
```

`ancs4linux` speaks to the phone; everything user-facing lives here. The
plugin deliberately replaces ancs4linux's own `desktop-integration` daemon —
running both would raise every notification twice.

| File | Role |
|---|---|
| `bin/omarchy-iphone-bridge` | D-Bus ↔ JSONL bridge; owns on-disk history |
| `Service.qml` | State: notification list, unread count, actions, toasts |
| `Panel.qml` | Bar button, badge, popup panel |
| `Model.js` | Pure helpers: time formatting, app glyphs, list ops |

History lives at `~/.local/state/omarchy/iphone/history.jsonl`.

## System requirements

The ANCS daemon is a separate, privileged install (systemd units + a D-Bus
policy). From this plugin's directory:

```bash
sudo ./install-ancs4linux.sh "$USER" /path/to/ancs4linux-source
```

Check it is up with:

```bash
systemctl status ancs4linux-observer ancs4linux-advertising
```

## Pairing

1. On the iPhone: Settings → Bluetooth → forget this machine if it is listed.
2. On the desktop: middle-click the iPhone bar icon, or press `p` in the
   panel, or run `omarchy-shell io.github.kbbahapro.iphone pair`.
3. Advertising takes up to ~30 seconds. Wait for it before touching the phone.
4. On the iPhone, tap the entry named **Omarchy** (configurable) and confirm
   the pairing code.
5. iOS will ask to **Share System Notifications** — this must be allowed, or
   ANCS stays silent. If you miss the prompt: Settings → Bluetooth → the ⓘ
   next to Omarchy → Share System Notifications.

## Controls

| Where | Action |
|---|---|
| Bar, left click | Open/close the panel |
| Bar, right click | Mark all read (clears the badge) |
| Bar, middle click | Start pairing |
| Panel, `↑`/`↓` | Move through notifications |
| Panel, `Enter` | Dismiss the selected one (also on the phone) |
| Panel, `c` | Clear all |
| Panel, `p` | Start pairing |
| Row, right click | Dismiss that notification |

IPC, for keybindings or scripts:

```bash
omarchy-shell io.github.kbbahapro.iphone toggle
omarchy-shell io.github.kbbahapro.iphone status
omarchy-shell io.github.kbbahapro.iphone unread
omarchy-shell io.github.kbbahapro.iphone pair
omarchy-shell io.github.kbbahapro.iphone clear
```

## Settings

Configured per-widget in `~/.config/omarchy/shell.json`, or through the bar
widget settings UI.

| Key | Default | Meaning |
|---|---|---|
| `showToasts` | `true` | Raise a desktop popup per notification |
| `mutedApps` | `""` | Comma-separated apps that never pop a toast (still listed) |
| `historyLimit` | `200` | Notifications kept in the panel and on disk |
| `advertiseName` | `Omarchy` | Name shown on the iPhone while pairing |

Example — keep the badge but stay silent except for Slack and Mail:

```json
{ "id": "io.github.kbbahapro.iphone", "mutedApps": "news, games, spotify, photos" }
```

## Limitations

These are ANCS limits, not implementation gaps:

- **No replying.** iOS exposes only two actions per notification (positive and
  negative). Reading and dismissing, yes; typing back, no.
- **No attachments or images** — title and body text only.
- **Bluetooth range.** Out of range means no notifications; the icon dims.
- **One phone at a time.**
- Notification text is mirrored onto this machine and, with the default
  settings, written to `history.jsonl`. Set `historyLimit` low, or turn
  history off by pointing it at a small number, if that matters for your
  threat model.

## Troubleshooting

Panel says *"Bridge not running"* — the system daemon is down:

```bash
systemctl status ancs4linux-observer
journalctl -u ancs4linux-observer -n 50
```

Paired but nothing arrives — almost always the iOS notification permission.
Settings → Bluetooth → ⓘ → **Share System Notifications** must be on.

Test the bridge by hand:

```bash
~/.config/omarchy/plugins/io.github.kbbahapro.iphone/bin/omarchy-iphone-bridge listen
```

Pairing never shows up on the phone — some adapters need BlueZ experimental
mode. Set `Experimental = true` in `/etc/bluetooth/main.conf`, then
`sudo systemctl restart bluetooth`.

---

---

# Beyond notifications

What the iPhone advertises over Bluetooth, and what this setup uses:

| Service | Used for |
|---|---|
| ANCS `7905f431…` | Notifications + two-way dismiss |
| **AMS** `89d3502b…` | Now playing + transport control, over BLE |
| Battery `180f` | Phone battery % in the bar |
| AVRCP / A2DP | Phone media as an MPRIS player (`mpris-proxy`) |
| PBAP `112f` | Contacts (not yet wired up) |
| MAP `1132` | SMS read/reply (not yet wired up) |

## Apple Media Service

`bin/omarchy-iphone-ams` is a GATT client for AMS. Unlike AVRCP it rides the
same BLE link as notifications, so now-playing and transport control keep
working when the phone is *not* connected as a Bluetooth audio source.

```bash
bin/omarchy-iphone-ams listen           # stream now-playing as JSON lines
bin/omarchy-iphone-ams command toggle   # play|pause|toggle|next|prev|volup|voldown
```

The panel's NOW PLAYING section and its transport buttons are driven by this.

## Phone media as an MPRIS player

BlueZ's `mpris-proxy` bridges AVRCP to MPRIS, which Omarchy's `omarchy.media`
widget already understands. Enabled as a user service:

```bash
systemctl --user status mpris-proxy
```

This is the belt to AMS's braces: it only works while the phone is connected
for audio, but it feeds the stock media widget with no plugin code at all.

---

# Founder workflow features

The notification stream is more useful as something to *act on* than something
to look at. These three do that.

## Login codes straight to the clipboard

2FA codes arrive as ordinary notifications. `Model.extractOtp` pulls them out
and `wl-copy` puts them on the clipboard, with a `critical` toast so it shows
even in Do Not Disturb. The phone stays in your pocket.

A bare number is never treated as a code — a context word (`code`, `otp`,
`passcode`, `verification`, `2fa`, `security`, `token`, `pin`…) must appear in
the notification. Four-digit years are rejected, and `123-456` style split
codes are joined. Tested against order numbers, prices and prose.

Turn it off with `autoCopyCodes: false`.

## Focus mode

Silences iPhone popups except a VIP allowlist. Notifications still land in the
panel and the badge — they just stop interrupting.

| | |
|---|---|
| Keybinding | **SUPER+SHIFT+CTRL+F** |
| Bar | middle-click the iPhone icon |
| Panel | the bell/moon button in the hero |
| IPC | `omarchy-shell io.github.kbbahapro.iphone focus \| focusOn \| focusOff` |

Set `vipApps` to a comma-separated list of apps or sender names, e.g.
`slack, mail, acme, mom`. With it empty, focus silences everything.

Login codes still come through in focus mode — you only ever see one because
you just asked for it.

---

## What iOS tells us that ancs4linux discards

ANCS carries more than the upstream daemon exposes. `patches/ancs4linux-metadata.patch`
surfaces four things, and `install-ancs4linux.sh` applies it automatically:

| Field | Why it matters |
|---|---|
| **Category** | iOS tags every notification: `Incoming call`, `Missed call`, `Voicemail`, `Social`, `Schedule`, `Email`, `News`, `Health`, `Finance`, `Location`, `Entertainment`. Classification with no user rules. |
| **Important flag** | iOS's own urgency signal. Better than a hand-maintained VIP list, because Apple already did the work. |
| **Silent flag** | iOS asked for quiet delivery. The plugin honours it and raises no popup. |
| **Date** | The phone's timestamp rather than whenever the desktop received it. |

Upstream also drops pre-existing notifications — the ones queued while the phone
was out of range. The patch forwards them flagged as `preexisting`, so they
appear in the panel as catch-up without firing a burst of popups.

Calls, voicemail and anything iOS marked important are treated as urgent: they
raise a `critical` toast and pierce focus mode without being on the VIP list.

If the patch ever fails to apply against a newer ancs4linux, the installer says
so and continues; the plugin degrades to the fields upstream provides.

---

## Proximity lock

Locks the desktop when the iPhone leaves Bluetooth range, and cancels if it
comes back in time. **Off by default** — it is a large behavioural change, and
a short BLE dropout should not cost you your session.

| Setting | Default | Meaning |
|---|---|---|
| `proximityLock` | `false` | Enable it |
| `proximityLockDelay` | `60` | Seconds to wait before locking |

You get a warning toast when the countdown starts and another if it is
cancelled. The lock never fires unless the phone has actually been seen this
session, so restarting the shell while the phone is away cannot lock you out.

## Incoming calls

ANCS category `1` is handled specially, because a call is the one notification
you cannot deal with later:

- every MPRIS player on the desktop is paused, so you can hear it and think
- a `critical` toast names the caller
- the row is tinted in the panel

Calls bypass focus mode and the Silent flag entirely. Voicemail and missed
calls are treated as urgent too, and get their own glyph.

## Threading

Notifications are grouped by sender within each app — for Messenger and
Messages the title *is* the sender — so seven messages from one person are one
row marked `×7` rather than seven. Dismissing the row clears the whole thread,
here and on the phone.

The section header also shows how many notifications iOS says are still
queued on the device, which is a different number from what you have
collected here.

---

## Incoming-call dialog

A ringing call gets its own layer-shell surface (`omarchy-iphone-call`, on the
overlay layer) rather than a row buried in the bar panel — you should not have
to go looking for a call that is actionable for seconds.

- Caller name, detail line, and which device it came from
- **Decline** (red) and **Answer** (green), labelled with the actions iOS
  actually sent
- `Enter` answers, `Esc` declines
- The card drops in with a slight overshoot; the avatar ring pulses while it
  rings
- Closes by itself when the phone withdraws the notification, so a call
  answered on the handset dismisses it here too

Only the card takes input (`mask: Region`), so the rest of the screen stays
clickable while it is up.

Chrome follows Omarchy's theme tokens, so it matches whatever theme is set.
The two action colours are deliberately *not* themed: red and green for
decline and answer are near-universal, and a themed pair would be ambiguous
at the exact moment you need to read it fast.

Preview it without waiting for a call:

```bash
omarchy-shell io.github.kbbahapro.iphone testCall "Jane Doe"
omarchy-shell io.github.kbbahapro.iphone testCallEnd
```
