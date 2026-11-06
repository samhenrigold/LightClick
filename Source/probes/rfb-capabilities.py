#!/usr/bin/env python3
"""Ask a guest's stock AppleVNCServer what it offers, without changing anything in the guest.

Findings and how to reach a clone: probes/guest-capabilities.md.

    rfb-capabilities.py 127.0.0.1:5901                                  # banner and security types, no credentials
    RFB_USER=u RFB_PASSWORD=p rfb-capabilities.py 127.0.0.1:5901 --auth ard  # command bitmap, then the rectangles sent
    RFB_PASSWORD=p rfb-capabilities.py 127.0.0.1:5901 --auth vnc             # the same with a legacy VNC password
    rfb-capabilities.py --self-test

Read-only: it sends only SetEncodings and one small FramebufferUpdateRequest. It never turns on pasteboard sharing,
never sends input, and says nothing to the guest's file copy or curtain code. Connecting does show the guest's sharing
indicator while it runs. Credentials come from the environment so they stay out of ps and shell history.
"""
import argparse
import ctypes
import hashlib
import os
import secrets
import socket
import struct
import sys
import threading

SECURITY = {
    1: "None",
    2: "VNC password (DES)",
    5: "RA2",
    30: "Apple DH name+password (ARD)",
    31: "Apple (unnamed in binaries, 31)",
    32: "Apple (unnamed in binaries, 32)",
    33: "Apple RSA",
    35: "Apple Kerberos",
    36: "Apple SRP (inferred)",
}

# Message types are read from the Mavericks 13F34 client's RFB* functions unless marked (standard) or (?).
COMMANDS = {
    0x00: "SetPixelFormat (standard)",
    0x02: "SetEncodings (standard)",
    0x03: "FramebufferUpdateRequest (standard)",
    0x04: "KeyEvent",
    0x05: "PointerEvent",
    0x06: "ClientCutText (standard)",
    0x07: "? (no client function found)",
    0x08: "SetServerScaling",
    0x09: "AutoFrameUpdate",
    0x0a: "SetMode (control/observe)",
    0x0b: "RequestClipboard",
    0x0c: "? (toggled at run time by SessionOnConsole)",
    0x0d: "SetDisplay",
    0x0e: "DragEvent",
    0x10: "StartObserve / UDP (?)",
    0x11: "? (no client function found)",
    0x12: "SetEncryptionLevel",
    0x14: "FastUserSwitch: curtain, virtual display",
    0x15: "SetSharedPasteboard (automatic clipboard)",
    0x16: "AssistCursor",
    0x17: "Gesture and scroll",
    0x1c: "StartObserve (?)",
    0x1e: "? (no client function found)",
    0x1f: "SendClipboard (all flavors, deflated)",
    0x20: "DropEvent",
    0x21: "ViewerInfo",
    0x22: "FileCopy",
}

# In the order the stock client's RFBSetViewerEncodings appends them. Names are the server's flag users, so inferred.
ENCODINGS = {
    0: "Raw",
    -239: "Cursor (standard)",
    -223: "DesktopSize (standard)",
    1100: "Apple 1100 (unknown)",
    1101: "Apple 1101 (DisplayInfo)",
    1102: "Apple 1102 (UserInfo)",
    1104: "Apple 1104 (unknown)",
    1105: "Apple 1105 (DisplayInfo2)",
}

# From the Mavericks 13F34 screensharingd __data, before its run-time changes.
MAVERICKS_STATIC_BITMAP = bytes.fromhex("bffee703e00000000000000000000000")


def crypt(algorithm, key, block):
    """CCCrypt ECB, encrypting. shortcut: macOS hosts only, which is the only place this runs."""
    library = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    out = ctypes.create_string_buffer(len(block))
    moved = ctypes.c_size_t()
    kCCOptionECBMode = 2
    status = library.CCCrypt(
        0, algorithm, kCCOptionECBMode, key, ctypes.c_size_t(len(key)), None, block,
        ctypes.c_size_t(len(block)), out, ctypes.c_size_t(len(block)), ctypes.byref(moved))
    if status:
        raise OSError(f"CCCrypt failed: {status}")
    return out.raw[:moved.value]


def aes(key, block):
    return crypt(0, key, block)


def des(key, block):
    return crypt(1, key, block)


class Connection:
    def __init__(self, sock):
        self.sock = sock

    def read(self, count):
        if count > 1 << 28:
            raise ValueError(f"implausible length {count}")
        data = bytearray()
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise EOFError(f"connection closed after {len(data)} of {count} bytes")
            data += chunk
        return bytes(data)

    def u8(self):
        return self.read(1)[0]

    def u16(self):
        return struct.unpack(">H", self.read(2))[0]

    def u32(self):
        return struct.unpack(">I", self.read(4))[0]

    def send(self, data):
        self.sock.sendall(data)


def ard_credentials(user, password):
    """64 bytes each: NUL-terminated, the rest random, as the server's 128-byte DH message expects."""
    def field(text):
        encoded = text.encode()[:63] + b"\0"
        return encoded + secrets.token_bytes(64 - len(encoded))
    return field(user) + field(password)


def ard_response(generator, prime, server_public, user, password):
    size = len(prime)
    modulus = int.from_bytes(prime, "big")
    private = secrets.randbelow(modulus - 2) + 1
    public = pow(generator, private, modulus).to_bytes(size, "big")
    shared = pow(int.from_bytes(server_public, "big"), private, modulus).to_bytes(size, "big")
    return aes(hashlib.md5(shared).digest(), ard_credentials(user, password)) + public


def authenticate_ard(conn, user, password):
    conn.send(bytes([30]))
    generator = conn.u16()
    size = conn.u16()
    if not 0 < size <= 1024:
        raise ValueError(f"implausible DH key size {size}")
    prime = conn.read(size)
    server_public = conn.read(size)
    conn.send(ard_response(generator, prime, server_public, user, password))


def authenticate_vnc(conn, password):
    conn.send(bytes([2]))
    challenge = conn.read(16)
    # VNC reverses the bits of each key byte.
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in password.encode()[:8].ljust(8, b"\0"))
    conn.send(des(key, challenge[:8]) + des(key, challenge[8:]))


def security_result(conn):
    if conn.u32() == 0:
        return
    size = conn.u32()
    reason = conn.read(min(size, 1024)).decode(errors="replace")
    raise PermissionError(f"authentication refused: {reason}")


def parse_server_extension(payload):
    """(flags, bitmap, name). Apple's name field holds u16 0, u32 flags, 16-byte bitmap, then the name."""
    if len(payload) >= 22 and payload[:2] == b"\0\0":
        return struct.unpack(">I", payload[2:6])[0], payload[6:22], payload[22:]
    return None, None, payload


def bitmap_commands(bitmap):
    # The client's RFBServerCommandSupportedCore: byte n >> 3, bit 7 - (n & 7).
    return [n for n in range(len(bitmap) * 8) if bitmap[n >> 3] >> (7 - (n & 7)) & 1]


def rectangle_size(encoding, width, height, bytes_per_pixel):
    """The bytes after a rectangle's header, or None when this probe doesn't know the layout."""
    if encoding == 0:
        return width * height * bytes_per_pixel
    if encoding == -239:
        return width * height * bytes_per_pixel + (width + 7) // 8 * height
    if encoding == -223:
        return 0
    return None


def report_updates(conn, width, height, bytes_per_pixel, encodings, seconds, emit):
    conn.send(struct.pack(">BxH", 2, len(encodings)) + b"".join(struct.pack(">i", e) for e in encodings))
    conn.send(struct.pack(">BBHHHH", 3, 0, 0, 0, min(width, 16), min(height, 16)))
    conn.sock.settimeout(seconds)
    seen = {}
    try:
        while True:
            kind = conn.u8()
            if kind == 0:
                conn.read(1)
                for _ in range(conn.u16()):
                    x, y, w, h, encoding = struct.unpack(">HHHHi", conn.read(12))
                    seen[encoding] = seen.get(encoding, 0) + 1
                    size = rectangle_size(encoding, w, h, bytes_per_pixel)
                    name = ENCODINGS.get(encoding, f"encoding {encoding}")
                    emit(f"  rectangle {name}: x={x} y={y} w={w} h={h}")
                    if size is None:
                        # Keep the layout evidence: this is how Apple's encodings get decoded next.
                        conn.sock.settimeout(1)
                        emit(f"  stopping: no parser for {encoding}; next bytes {conn.sock.recv(256).hex()}")
                        return seen
                    conn.read(size)
            elif kind == 2:
                emit("  bell")
            elif kind == 3:
                conn.read(3)
                size = conn.u32()
                conn.read(size)
                # The guest's own clipboard text: report only its length.
                emit(f"  ServerCutText, {size} bytes")
            else:
                conn.sock.settimeout(1)
                emit(f"  stopping: server message {kind}; next bytes {conn.sock.recv(256).hex()}")
                return seen
    except socket.timeout:
        return seen


def probe(sock, user, password, auth, encodings, seconds, emit):
    """Returns what was learned. Everything printed is also in here, for the self-test."""
    conn = Connection(sock)
    result = {}
    banner = conn.read(12)
    result["banner"] = banner.decode(errors="replace").strip()
    emit(f"banner: {result['banner']}")
    if not banner.startswith(b"RFB "):
        raise ValueError("not an RFB server")
    # 3.889 is what asks Apple's server for the extended ServerInit.
    conn.send(b"RFB 003.889\n" if banner == b"RFB 003.889\n" else b"RFB 003.008\n")
    count = conn.u8()
    if count == 0:
        size = conn.u32()
        raise PermissionError("server refused: " + conn.read(min(size, 1024)).decode(errors="replace"))
    result["security"] = list(conn.read(count))
    for kind in result["security"]:
        emit(f"security type {kind}: {SECURITY.get(kind, 'unknown')}")
    if not auth:
        emit("no --auth: stopping before authentication")
        return result
    wanted = {"ard": 30, "vnc": 2}[auth]
    if wanted not in result["security"]:
        raise PermissionError(f"server doesn't offer type {wanted}; it offers {result['security']}")
    if auth == "ard":
        authenticate_ard(conn, user, password)
    else:
        authenticate_vnc(conn, password)
    security_result(conn)
    emit("authenticated")

    # Shared, and bit 0x40 clear: the session chooser (virtual display) stays out of the way.
    conn.send(b"\x01")
    width, height = conn.u16(), conn.u16()
    pixel_format = conn.read(16)
    payload = conn.read(conn.u32())
    flags, bitmap, name = parse_server_extension(payload)
    bytes_per_pixel = pixel_format[0] // 8
    result.update(width=width, height=height, flags=flags, bitmap=bitmap)
    emit(f"framebuffer: {width}x{height}, {pixel_format[0]} bpp; name is {len(name)} bytes")
    if bitmap is None:
        emit("no Apple extension in ServerInit")
    else:
        emit(f"server flags: {flags:#x}")
        emit(f"command bitmap: {bitmap.hex()}")
        for command in bitmap_commands(bitmap):
            emit(f"  {command:#04x} {COMMANDS.get(command, 'unknown')}")
    emit("updates:")
    result["rectangles"] = report_updates(conn, width, height, bytes_per_pixel, encodings, seconds, emit)
    return result


def fake_server(sock, user, password):
    """A loopback stand-in with the wire shapes above, including a rectangle the probe can't parse."""
    conn = Connection(sock)
    conn.send(b"RFB 003.889\n")
    assert conn.read(12) == b"RFB 003.889\n"
    conn.send(bytes([3, 30, 2, 35]))
    assert conn.u8() == 30
    # RFC 3526's 1536-bit MODP group.
    prime = int(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
        "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA237327FFFFFFFFFFFFFFFF", 16)
    size = (prime.bit_length() + 7) // 8
    private = secrets.randbelow(prime - 2) + 1
    conn.send(struct.pack(">HH", 2, size) + prime.to_bytes(size, "big") + pow(2, private, prime).to_bytes(size, "big"))
    ciphertext = conn.read(128)
    client_public = int.from_bytes(conn.read(size), "big")
    key = hashlib.md5(pow(client_public, private, prime).to_bytes(size, "big")).digest()
    decrypt = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    plain = ctypes.create_string_buffer(128)
    moved = ctypes.c_size_t()
    assert decrypt.CCCrypt(
        1, 0, 2, key, ctypes.c_size_t(16), None, ciphertext, ctypes.c_size_t(128), plain,
        ctypes.c_size_t(128), ctypes.byref(moved)) == 0
    assert plain.raw[:64].split(b"\0")[0].decode() == user
    assert plain.raw[64:128].split(b"\0")[0].decode() == password
    conn.send(struct.pack(">I", 0))
    assert conn.read(1) == b"\x01"
    name = b"guest"
    payload = b"\0\0" + struct.pack(">I", 3) + MAVERICKS_STATIC_BITMAP + name
    pixel_format = bytes([32, 24, 0, 1]) + struct.pack(">HHH", 255, 255, 255) + bytes([16, 8, 0, 0, 0, 0])
    conn.send(struct.pack(">HH", 800, 600) + pixel_format + struct.pack(">I", len(payload)) + payload)
    assert conn.u8() == 2
    conn.read(1)
    for _ in range(conn.u16()):
        conn.read(4)
    assert conn.u8() == 3
    conn.read(9)
    cursor = struct.pack(">HHHHi", 0, 0, 2, 2, -239) + bytes(2 * 2 * 4) + bytes(2)
    resize = struct.pack(">HHHHi", 0, 0, 800, 600, -223)
    raw = struct.pack(">HHHHi", 0, 0, 1, 1, 0) + bytes(4)
    apple = struct.pack(">HHHHi", 0, 0, 0, 0, 1105) + b"\xde\xad"
    conn.send(bytes([2]))
    conn.send(bytes([3, 0, 0, 0]) + struct.pack(">I", 4) + b"text")
    conn.send(bytes([0, 0]) + struct.pack(">H", 4) + cursor + resize + raw + apple)


def self_test():
    # FIPS-197 appendix C.1 and the classic DES vector, so the CommonCrypto calls are the right ones.
    assert aes(bytes(range(16)), bytes.fromhex("00112233445566778899aabbccddeeff")).hex() == \
        "69c4e0d86a7b0430d8cdb78070b4c55a"
    assert des(bytes.fromhex("133457799bbcdff1"), bytes.fromhex("0123456789abcdef")).hex() == "85e813540f0ab405"
    # The client's support test, against the two commands the client's own code checks.
    assert 0x14 not in bitmap_commands(MAVERICKS_STATIC_BITMAP)
    assert bitmap_commands(bytes([0b00001000]) + bytes(15)) == [4]
    assert bitmap_commands(bytes([0, 0, 0b00001000]) + bytes(13)) == [0x14]
    assert parse_server_extension(b"plain") == (None, None, b"plain")
    assert rectangle_size(-239, 9, 2, 4) == 9 * 2 * 4 + 2 * 2
    assert len(ard_credentials("u" * 80, "p")) == 128

    server, client = socket.socketpair()
    failures = []

    def serve():
        try:
            fake_server(server, "user", "pass")
        except BaseException as error:
            failures.append(error)
        finally:
            server.close()

    thread = threading.Thread(target=serve)
    thread.start()
    lines = []
    result = probe(client, "user", "pass", "ard", list(ENCODINGS), 5, lines.append)
    client.close()
    thread.join()
    if failures:
        raise failures[0]
    assert result["security"] == [30, 2, 35]
    assert (result["width"], result["height"], result["flags"]) == (800, 600, 3)
    assert result["bitmap"] == MAVERICKS_STATIC_BITMAP
    assert result["rectangles"] == {-239: 1, -223: 1, 0: 1, 1105: 1}
    assert any(line.endswith("next bytes dead") for line in lines), lines
    assert not any("text" in line for line in lines), "clipboard contents must not be printed"
    print("self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", nargs="?", help="host:port")
    parser.add_argument("--auth", choices=["ard", "vnc"], help="RFB_USER and RFB_PASSWORD come from the environment")
    parser.add_argument("--encodings", help="comma-separated, default: everything the stock client sends")
    parser.add_argument("--seconds", type=float, default=5, help="how long to listen for updates")
    parser.add_argument("--self-test", action="store_true")
    options = parser.parse_args()
    if options.self_test:
        self_test()
        return 0
    if not options.target:
        parser.error("a host:port is required")
    host, _, port = options.target.rpartition(":")
    user, password = os.environ.get("RFB_USER", ""), os.environ.get("RFB_PASSWORD", "")
    if options.auth and not password:
        parser.error("set RFB_PASSWORD")
    if options.auth == "ard" and not user:
        parser.error("set RFB_USER")
    encodings = [int(e) for e in options.encodings.split(",")] if options.encodings else list(ENCODINGS)
    try:
        with socket.create_connection((host, int(port)), timeout=10) as sock:
            probe(sock, user, password, options.auth, encodings, options.seconds, print)
    except (OSError, EOFError, ValueError) as error:
        print(f"failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
