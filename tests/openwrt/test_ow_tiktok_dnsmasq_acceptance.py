#!/usr/bin/env python3
"""Exercise TikTok's native dnsmasq address override against real dnsmasq."""

from __future__ import annotations

import ipaddress
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


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


def query_a(server_port: int) -> list[str]:
    identifier = int(time.time_ns()) & 0xFFFF
    question = dns_name(HOST) + struct.pack("!HH", 1, 1)
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


class DnsmasqAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dnsmasq = os.environ.get("DNSMASQ_BIN") or shutil.which("dnsmasq")
        if not cls.dnsmasq:
            raise unittest.SkipTest("dnsmasq binary is not installed")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="z2k-tiktok-dnsmasq-")
        self.root = Path(self.temp.name)
        self.port = free_udp_port()
        self.upstream = UpstreamDns()
        self.upstream.start()
        self.config = self.root / "dnsmasq.conf"
        self.log = (self.root / "dnsmasq.log").open("wb")
        self.process: subprocess.Popen[bytes] | None = None

    def tearDown(self) -> None:
        self.stop_dnsmasq()
        self.upstream.close()
        self.log.close()
        self.temp.cleanup()

    def write_config(self, address: str = "") -> None:
        contents = [
            "listen-address=127.0.0.1",
            f"port={self.port}",
            "bind-interfaces",
            "no-resolv",
            "no-hosts",
            f"server=127.0.0.1#{self.upstream.port}",
        ]
        if address:
            contents.append(address)
        self.config.write_text("\n".join(contents) + "\n", encoding="ascii")

    def start_dnsmasq(self) -> None:
        self.process = subprocess.Popen(
            [self.dnsmasq, "--no-daemon", f"--conf-file={self.config}"],
            stdout=self.log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.flush()
                raise AssertionError(self.log_path_text())
            try:
                query_a(self.port)
                return
            except (OSError, AssertionError):
                time.sleep(0.05)
        raise AssertionError("dnsmasq did not start listening")

    def stop_dnsmasq(self) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
            self.process = None

    def restart_dnsmasq(self, address: str = "") -> None:
        self.stop_dnsmasq()
        self.write_config(address)
        self.start_dnsmasq()

    def log_path_text(self) -> str:
        self.log.flush()
        return (self.root / "dnsmasq.log").read_text(encoding="utf-8", errors="replace")

    def test_selected_ip_failover_restart_and_disable_are_visible_to_dns_clients(self) -> None:
        first = "87.245.200.8"
        second = "87.245.200.35"

        self.write_config(f"address=/{HOST}/{first}")
        self.start_dnsmasq()
        self.assertIn(first, query_a(self.port), "effective address override must reach a DNS client")

        # A new runtime instance must consume the failover address immediately.
        self.restart_dnsmasq(f"address=/{HOST}/{second}")
        self.assertIn(second, query_a(self.port), "DNS answer must follow a failover, not a stale cache")
        self.assertNotIn(first, query_a(self.port))

        # Removing the owned override restores ordinary upstream resolution.
        self.restart_dnsmasq()
        self.assertEqual([FALLBACK_IP], query_a(self.port))


if __name__ == "__main__":
    unittest.main(verbosity=2)
