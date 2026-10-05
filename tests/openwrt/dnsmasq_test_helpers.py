#!/usr/bin/env python3
"""Small DNS wire helpers shared by OpenWrt acceptance tests."""

from __future__ import annotations

import ipaddress
import socket
import struct
import threading
import time


HOST = "v77.tiktokcdn.com"
FALLBACK_IP = "198.51.100.44"


def free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def dns_name(name: str) -> bytes:
    return b"".join(bytes((len(label),)) + label.encode("ascii") for label in name.split(".")) + b"\0"


def skip_name(packet: bytes, offset: int) -> int:
    while offset < len(packet):
        size = packet[offset]
        if size & 0xC0 == 0xC0:
            return offset + 2
        offset += 1
        if size == 0:
            return offset
        offset += size
    raise AssertionError("truncated DNS name")


def query_a(server_port: int, host: str = HOST) -> list[str]:
    identifier = int(time.time_ns()) & 0xFFFF
    question = dns_name(host) + struct.pack("!HH", 1, 1)
    request = struct.pack("!HHHHHH", identifier, 0x0100, 1, 0, 0, 0) + question
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.35)
        sock.sendto(request, ("127.0.0.1", server_port))
        response, _ = sock.recvfrom(2048)
    response_id, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", response[:12])
    if response_id != identifier or flags & 0x8000 == 0 or questions != 1:
        raise AssertionError("invalid DNS response")
    offset = skip_name(response, 12) + 4
    result: list[str] = []
    for _ in range(answers):
        offset = skip_name(response, offset)
        record_type, record_class, _, length = struct.unpack("!HHIH", response[offset : offset + 10])
        offset += 10
        payload = response[offset : offset + length]
        offset += length
        if record_type == 1 and record_class == 1 and length == 4:
            result.append(str(ipaddress.IPv4Address(payload)))
    return result


class UpstreamDns:
    def __init__(self) -> None:
        self.port = free_udp_port()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.settimeout(0.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stop.set()
        self.thread.join(timeout=1)
        self.sock.close()

    def _serve(self) -> None:
        while not self.stop.is_set():
            try:
                packet, peer = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            question_end = skip_name(packet, 12) + 4
            question = packet[12:question_end]
            header = struct.pack("!HHHHHH", struct.unpack("!H", packet[:2])[0], 0x8180, 1, 1, 0, 0)
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + ipaddress.IPv4Address(FALLBACK_IP).packed
            self.sock.sendto(header + question + answer, peer)
