# The TV browser's own remote protocol (port 8335) — VERIFIED 2026-08-22

A **second, unrelated protocol** to Android TV Remote v2. It belongs to the TV
browser app (`com.internet.tvbrowser`, Play Store, v2.16.0) and it is the only
way found so far to move a real 2D cursor on this TV.

**Why it matters:** the Remote v2 protocol provably cannot do this. Its uinput
device (`virtual-remote`) declares `KEY` events only — no `REL`, no `ABS`, no
mouse buttons — so no message over that channel can move a pointer. This one
takes arbitrary float deltas.

## Discovery

The phone app *BROWSER with TV remote* (App Store id6670316885) moves the
cursor freely. Captured while it did so:

- **Zero** events on every `/dev/input` device — the motion never touches the
  TV's input layer
- Three sockets from the phone: two to `:6466` (Remote v2, for buttons) and one
  to **`:8335`**

`dumpsys activity services com.internet.tvbrowser` names the owner:
`com.common.services.RemoteServerService`. The port carries no literal in the
APK, so it is computed — do not grep for it; identify the service instead.

## Endpoints

Ktor server, routes recovered from the decompiled APK (`nb/i.java`):

| Route | Method | Notes |
|---|---|---|
| `/ws` | WebSocket | binary frames — the command channel |
| `/ping` | GET | returns `pong` |
| `/info` | GET | JSON identity |
| `/upload` | POST | not investigated |

**No authentication on any of them.** `/info` answers a bare curl:

```json
{"app_id":"com.internet.tvbrowser","app_version":471,
 "device_name":"desktop","is_premium":false,"remote_version":2}
```

## Wire format

Protobuf over WebSocket **binary** frames. Top-level `RemoteEvent` is a oneof
(`qb/d0.java` field numbers):

```
cursor_move=1  cursor_scroll=2  cursor_drag=3   cursor_click=4
key_event=5    keyboard_input=6 keyboard_action=7 raw_command=8
simple_key_event=9 pinch_gesture=10 search=11   player_command=12
sync_request=13 log=14 event=15 open_video_player=16
start_download=17 tab_action=18 set_incognito_mode=19 ping=20 pong=21
```

`CursorMove`, `CursorScroll` and `CursorDrag` share a shape (`qb/s,t,r.java`):

```protobuf
message CursorMove {
  MotionAction action = 1;   // enum, see below
  float dx = 2;              // RELATIVE delta
  float dy = 3;
}
enum MotionAction { DOWN=0 UP=1 MOVE=2 CANCEL=3 OUTSIDE=4
                    POINTER_DOWN=5 POINTER_UP=6 }
```

Deltas are **relative floats**, so any vector works — diagonals, curves, any
path. This is a real mouse, unlike the 4-way key glide.

A move of (dx, dy) encodes to:

```
0A <len> 08 <action> 15 <dx float32 LE> 1D <dy float32 LE>
```

e.g. `CURSOR_MOVE(action=MOVE, dx=-6, dy=-4)` =
`0a0c0802150000c0c01d000080c0`

## Verified

`Scripts/tvbrowser-cursor.py` (throwaway spike, no dependencies — hand-rolled
WebSocket + protobuf) sent 200 frames of `(-6, -4)`. The cursor tracked a clean
3:2 diagonal to (757, 325) and hovered the link beneath it. Screenshots via
`adb shell screencap` before/after; the cursor appears in captures, so this is
machine-verifiable without watching the TV.

```bash
python3 Scripts/tvbrowser-cursor.py <dx> <dy> [steps]
```

## Caveats

- **Private and undocumented.** No stability contract; a browser update can
  change the format and break any client without warning.
- Only works while that browser app is running and foregrounded.
- **Click VERIFIED:** `CursorClick` (oneof field 4) is an empty message —
  wire bytes `22 00`. Sent while hovering a result link, the browser navigated
  to it. Click happens at the cursor's current position.
- **Deltas are 1:1 TV pixels** on this TV (no acceleration): 20 × (7.1, 14.05)
  moved the cursor exactly (+142, +281). `dy > 0` is down.
- Discovery: the server advertises **`_zeusremote._tcp`** over Bonjour
  (instance name = TV name, e.g. `desktop`); the port comes from the SRV record,
  which is why no `8335` literal exists in the APK.
- Untested: drag, scroll, pinch, keyboard, tab actions — the schema for each is
  in `qb/*.java` field numbers, same pattern as above.
- The cursor appears to hide when idle and clamps at screen edges.

## TV→phone state channel — VERIFIED 2026-08-22

The server does not only accept commands on `/ws`; it also pushes state
frames to the phone, unprompted, on the same binary channel. This section
documents that push channel and the availability rule `BrowserCursorClient`
derives from it.

**The trap this section exists to name:** the server keeps accepting
connections — and keeps the WebSocket open — while the browser app is
BACKGROUNDED, and also while it sits on its own start screen with no page
loaded. So **a WebSocket being open is not a usable availability signal.**
Anything that treats "socket open" as "cursor works" will show a cursor tab
that appears and does nothing in both of those states. The only reliable
signal is the `app_state` push described below.

### Push-on-connect — VERIFIED 2026-08-22

The whole availability feature depends on the server volunteering an
`app_state` frame as soon as the socket opens, without the client asking for
one. That assumption is verified, not inferred: connected fresh three
separate times on 2026-08-22, sent nothing on any of the three connections,
and the server pushed a burst immediately every time. Most recent capture,
with a page open in the browser:

```
handshake: HTTP/1.1 101 Switching Protocols
listening…            (client sends nothing)
  [  4B] f1  = 0801
  [  4B] f2  = 4801
  [ 13B] f5  = 0801120762726f77736572      ← app_state: foreground=true, screen="browser"
  [  2B] f6  = (empty)
  [  2B] f11 = (empty)
  [ 20B] f3  = 0a0d3139322e3136382e302e313038108f41   ← udp_server_info "192.168.0.108", port 8335
```

Confirmed three times, not once: the same push-on-connect burst was observed
on all three fresh connections made today. Consequence: a client does **not**
need to send `sync_request` (envelope field 13) to obtain initial state —
push-on-connect alone is sufficient, and `BrowserCursorClient` relies on
exactly that. This closes the gap a reviewer would otherwise hit reading only
the repo: nothing short of this capture distinguishes "the server pushes
state on connect" from "the server only pushes state on change," and that
distinction decides whether gating `isAvailable` on `app_state` can ever
leave `false` before the user does anything.

### Envelope

Every frame on the TV→phone channel is a top-level protobuf message whose
fields observed so far are:

| Field | Contents | Notes |
|---|---|---|
| 1 | `control_mode` | not implemented — out of scope here |
| 2 | `keyboard_state` | not implemented — out of scope here |
| 3 | `udp_server_info` | not implemented — out of scope here |
| **5** | **`app_state`** | **the one this client decodes** |
| 6 | `media_playback_state` | not implemented — out of scope here |
| 11 | `incognito_mode` | not implemented — out of scope here |

Several of these fields arrive in one burst, so a single frame often carries
only some of them — a frame with no field 5 must be treated as "no new
information" and must leave the last known `app_state` unchanged, not as
"browser closed."

### `app_state` (field 5)

```protobuf
message AppState {
  bool foreground = 1;   // proto3 default false when the field is absent
  string screen = 2;
}
```

### Fixtures (device `desktop`, captured 2026-08-22)

Field 5's payload bytes, and the envelope built around each (`0x2A` = field 5,
wire type 2, followed by the payload's length):

| State | `app_state` payload (field 5 contents) | Decoded |
|---|---|---|
| Page open (BrowserActivity) | `08 01 12 07 62 72 6f 77 73 65 72` | `foreground=true, screen="browser"` |
| Start screen (MainActivity) | `08 01 12 04 68 6f 6d 65` | `foreground=true, screen="home"` |
| Browser backgrounded (on Home) | `12 04 68 6f 6d 65` | `foreground` ABSENT (proto3 default `false`), `screen="home"` |

Full envelopes (as pinned in `AppStateFixtures` in
`BrowserCursorClientTests.swift`):

```
page open:              2A 0B 08 01 12 07 62 72 6f 77 73 65 72
start screen:            2A 08 08 01 12 04 68 6f 6d 65
browser backgrounded:    2A 06 12 04 68 6f 6d 65
```

### Derived availability rule

```
isAvailable = (socket open) && (app_state.foreground == true) && (app_state.screen == "browser")
```

- Before any `app_state` frame has arrived, `isAvailable` is `false` — never
  optimistic. A tab that appears before the server has confirmed a page is
  loaded is the exact "present but inert" bug this rule removes.
- `screen == "home"` (the app's own start screen) is NOT available, even
  though `foreground` can be `true` there — nothing on that screen for the
  cursor to move.
- Any `screen` value other than `"browser"` — including one never observed —
  is treated as NOT available. Conservative on purpose.
- A frame with no field 5 leaves the last known state unchanged (see
  "Envelope" above); a truncated or malformed field 5 does the same rather
  than crashing or flipping availability.
- The socket closing clears the remembered `app_state`, so a reconnect that
  hasn't yet received a fresh `app_state` frame is correctly NOT available,
  rather than inheriting the previous connection's last-known screen.

## Hardware verification of the cursor feature (2026-08-22)

Verified end to end against `desktop` with the app running in the simulator:

- **Free 2D movement** — a drag moves the cursor along the path of the finger,
  not in four directions. This is the capability Remote v2 cannot provide at
  all.
- **Availability gating** — the pointer tab appears only while the browser
  reports `foreground` AND `screen == "browser"`. Confirmed disappearing on the
  browser's own start screen and when the browser is backgrounded, and
  reappearing when a page is opened again.
- **Discovery** — `_zeusremote._tcp` is found and connected by Bonjour instance
  name.

Two defects found ONLY by testing at the TV, neither visible to a green suite:

1. **Matching by IP silently killed the feature.** The client matched the
   discovered service against `PairedDevice.host`. That host is a DHCP lease:
   the TV had moved from `.103` to `.108`, so the match never succeeded and the
   cursor never became available, with no error anywhere. Fixed by matching on
   the Bonjour instance name, which is what `AndroidTVController` already does
   for the same reason.
2. **A tap moved the cursor before clicking.** `TrackpadEngine` sent the first
   delta before the tap threshold was evaluated, so a tap could drag up to
   `tapDistance * sensitivity` = 24px and then click — enough to miss a small
   link. Fixed by withholding sends until the threshold is crossed.

**Still unmeasured:** the trackpad sensitivity (2.0) is reasoned from screen
geometry, not measured against a hand. It is the one tuning value with no
empirical basis.
