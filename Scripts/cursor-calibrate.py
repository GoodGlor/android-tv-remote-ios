#!/usr/bin/env python3
"""Measures how many TV pixels one unit of CursorMove delta actually moves.

This is what turns `TrackpadEngine.sensitivity` from a guess into a number:
the TV's own contribution is measured here, so the constant is the only
remaining variable.

Method: pin the cursor in a corner, park it far away to capture a baseline,
then diff each frame against that baseline. The only thing that changes
between frames is the cursor, so the centroid of the changed pixels IS the
cursor position — no template matching, no guessing.

Needs: the TV browser open on a page (a plain one — example.com is ideal),
adb reachable, and numpy + Pillow. Measure in the page BODY, never the
toolbar: its buttons highlight on hover and swamp the diff.

    python3 Scripts/cursor-calibrate.py

Result on TV `desktop` (2026-08-23): ratio 1.000, i.e. exactly 1:1.
"""
import socket, os, base64, hashlib, struct, subprocess, time, sys
import numpy as np
from PIL import Image

HOST, PORT, PATH = "192.168.0.108", 8335, "/ws"
SP = os.path.dirname(os.path.abspath(__file__))

def handshake(sock):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {PATH} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    if b"101" not in resp.split(b"\r\n")[0]:
        raise RuntimeError("handshake refused")

def ws_send(sock, payload):
    header = bytearray([0x82])
    n = len(payload)
    assert n < 126
    header.append(0x80 | n)
    mask = os.urandom(4)
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def move_msg(dx, dy):
    """RemoteEvent{cursor_move=1} / CursorMove{action=2 MOVE, dx=2, dy=3}."""
    body = bytes([0x08, 0x02])
    body += bytes([0x15]) + struct.pack("<f", float(dx))
    body += bytes([0x1d]) + struct.pack("<f", float(dy))
    return bytes([0x0a, len(body)]) + body

def send(sock, dx, dy, steps=1):
    """Sent in steps so a huge delta is not clamped as one giant jump."""
    for _ in range(steps):
        ws_send(sock, move_msg(dx / steps, dy / steps))
        time.sleep(0.02)
    time.sleep(0.7)

def grab(name):
    subprocess.run(["adb", "shell", "screencap", "-p", "/sdcard/m.png"],
                   capture_output=True)
    subprocess.run(["adb", "pull", "/sdcard/m.png", f"{SP}/{name}.png"],
                   capture_output=True)
    return np.asarray(Image.open(f"{SP}/{name}.png").convert("L"), dtype=np.int16)

def centroid(frame, baseline):
    diff = np.abs(frame - baseline)
    ys, xs = np.where(diff > 40)
    if len(xs) == 0:
        return None
    # Ignore the parked corner and the static mute badge. The toolbar is NOT
    # excluded by y any more — it was, and it hid the cursor entirely when
    # pinned to the top-left corner.
    keep = (xs < 1150) & (ys < 640)
    xs, ys = xs[keep], ys[keep]
    if len(xs) == 0:
        return None
    return float(xs.mean()), float(ys.mean())

sock = socket.create_connection((HOST, PORT), timeout=6)
handshake(sock)

# Park bottom-right, out of the measurement area, and use that as baseline.
send(sock, 4000, 4000, steps=20)
base = grab("base")

results = []
for delta in (100, 200, 300):
    send(sock, -4000, -4000, steps=20)      # pin to top-left corner
    # Move into the empty page body before measuring: at the corner the
    # cursor sits over the toolbar, whose buttons highlight on hover and
    # swamp the diff with pixels that are not the cursor.
    send(sock, 300, 450, steps=10)
    a = centroid(grab("a"), base)
    send(sock, delta, 0, steps=10)
    b = centroid(grab("b"), base)
    if a is None or b is None:
        print(f"delta {delta}: cursor not found (a={a} b={b})")
        continue
    moved = b[0] - a[0]
    results.append((delta, moved, moved / delta))
    print(f"delta {delta:4d} -> moved {moved:7.1f}px   ratio {moved/delta:.3f}")

if results:
    ratios = [r for _, _, r in results]
    print(f"\nmean ratio: {sum(ratios)/len(ratios):.3f} TV px per delta unit")
sock.close()
