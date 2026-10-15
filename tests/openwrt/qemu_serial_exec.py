#!/usr/bin/env python3
"""Выполнить ограниченную команду в консоли гостевого OpenWrt QEMU."""

import argparse
import re
import secrets
import socket
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="*", help="команды; \\n можно передать как \\\\n")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4567)
    parser.add_argument("--timeout", type=int, default=300, help="тайм-аут команды в секундах")
    parser.add_argument("--interrupt", action="store_true")
    args = parser.parse_args()

    if args.interrupt:
        with socket.create_connection((args.host, args.port), timeout=5) as serial:
            serial.sendall(b"\x03")
        return 0
    if args.timeout <= 0:
        parser.error("тайм-аут должен быть больше нуля")
    if not args.command:
        parser.error("укажите хотя бы одну команду")

    command = " ".join(args.command).replace(r"\n", "\n")
    lines = command.splitlines()
    if not lines or any(len(line) > 70 for line in lines):
        print("каждая команда должна занимать не более 70 символов", file=sys.stderr)
        return 2

    marker = f"__Z2K_{secrets.token_hex(8)}__"
    with socket.create_connection((args.host, args.port), timeout=5) as serial:
        serial.settimeout(0.15)
        serial.sendall(b"\r\n")
        quiet_since = time.monotonic()
        while time.monotonic() - quiet_since < 0.5:
            try:
                if serial.recv(8192):
                    quiet_since = time.monotonic()
            except TimeoutError:
                pass

        serial.settimeout(0.5)
        serial.sendall(("\r\n".join(lines) + f"\r\necho {marker}:$?\r\n").encode())
        output = bytearray()
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            try:
                data = serial.recv(8192)
            except TimeoutError:
                continue
            if not data:
                break
            output.extend(data)
            if re.search(re.escape(marker.encode()) + rb":\d+", output):
                break

    decoded = output.decode("utf-8", "replace")
    print(decoded[-16000:])
    result = re.search(rf"{re.escape(marker)}:(\d+)", decoded)
    if result is None:
        return 1
    return int(result.group(1))


if __name__ == "__main__":
    raise SystemExit(main())
