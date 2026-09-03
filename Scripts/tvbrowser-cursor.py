#!/usr/bin/env python3
"""Minimal WebSocket client that sends CURSOR_MOVE events to the TV browser.

Wire format, recovered from the APK:
  RemoteEvent { cursor_move = 1 }            -> tag 0x0A, length-delimited
  CursorMove  { action = 1 (varint enum),
                dx = 2 (float), dy = 3 (float) }
  MotionAction: DOWN=0 UP=1 MOVE=2 CANCEL=3
"""
import socket, os, base64, struct, hashlib, sys, time

HOST, PORT, PATH = "192.168.0.108", 8335, "/ws"

def handshake(sock):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {PATH} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("server closed during handshake")
        resp += chunk
    head = resp.split(b"\r\n\r\n")[0].decode(errors="replace")
    if "101" not in head.split("\r\n")[0]:
        raise RuntimeError("handshake refused:\n" + head)
    expect = base64.b64encode(hashlib.sha1(
        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    if expect.lower() not in head.lower():
        raise RuntimeError("bad Sec-WebSocket-Accept")
    return head.split("\r\n")[0]

def ws_send_binary(sock, payload):
    # FIN + opcode 2 (binary); client frames MUST be masked
    header = bytearray([0x82])
    n = len(payload)
    assert n < 126, "short frames only"
    header.append(0x80 | n)
    mask = os.urandom(4)
    header += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + masked)

def cursor_move(dx, dy, action=2):
    inner = b"\x08" + bytes([action])                 # field 1 varint = action
    inner += b"\x15" + struct.pack("<f", float(dx))   # field 2 fixed32 float
    inner += b"\x1d" + struct.pack("<f", float(dy))   # field 3 fixed32 float
    return b"\x0a" + bytes([len(inner)]) + inner      # RemoteEvent.cursor_move

if __name__ == "__main__":
    dx, dy = float(sys.argv[1]), float(sys.argv[2])
    steps  = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    s = socket.create_connection((HOST, PORT), timeout=8)
    print("handshake:", handshake(s))
    frame = cursor_move(dx, dy)
    print("frame:", frame.hex())
    for _ in range(steps):
        ws_send_binary(s, frame)
        time.sleep(0.02)
    time.sleep(0.5)
    s.close()
    print(f"sent {steps} CURSOR_MOVE({dx}, {dy})")
