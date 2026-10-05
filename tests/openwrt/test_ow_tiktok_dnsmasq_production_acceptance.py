#!/usr/bin/env python3
"""Exercise the production TikTok UCI adapter against a real dnsmasq process."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from dnsmasq_test_helpers import FALLBACK_IP, HOST, UpstreamDns, free_udp_port, query_a

EU_HOST = "v77.tiktokcdn-eu.com"


class TikTokProductionDnsmasqAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import shutil
        cls.dnsmasq = os.environ.get("DNSMASQ_BIN") or shutil.which("dnsmasq")
        if not cls.dnsmasq:
            raise unittest.SkipTest("dnsmasq binary is not installed")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="z2k-tiktok-production-")
        self.root = Path(self.temp.name)
        self.port = free_udp_port()
        self.upstream = UpstreamDns()
        self.upstream.start()

    def tearDown(self) -> None:
        pid = self.root / "dnsmasq.pid"
        if pid.exists():
            subprocess.run(["kill", pid.read_text(encoding="ascii").strip()], check=False)
        self.upstream.close()
        self.temp.cleanup()

    def executable(self, path: Path, content: str) -> Path:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_selection_apply_failover_restart_disable_and_external_override(self) -> None:
        """Production selection and apply flows update a running dnsmasq daemon."""
        ip_a, ip_b, external_ip = "87.245.200.8", "87.245.200.35", "203.0.113.99"
        state = self.root / "state"
        state.mkdir()
        resolver_file = self.root / "resolv.conf"
        resolver_file.write_text("nameserver 192.0.2.53\n", encoding="ascii")
        uci_db = self.root / "uci.db"
        uci_db.write_text("dhcp.@dnsmasq[0]='dnsmasq'\n", encoding="ascii")
        config = self.root / "dnsmasq.conf"
        query_py = self.root / "dns_query.py"
        query_py.write_text(r'''#!/usr/bin/env python3
import ipaddress, socket, struct, sys
host, port = sys.argv[1], int(sys.argv[2])
qname = b''.join(bytes([len(x)]) + x.encode() for x in host.split('.')) + b'\0'
question = qname + struct.pack('!HH', 1, 1)
ident = 0x5a2c
packet = struct.pack('!HHHHHH', ident, 0x0100, 1, 0, 0, 0) + question
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.settimeout(1); s.sendto(packet, ('127.0.0.1', port)); data, _ = s.recvfrom(2048)
_, flags, qd, answers, _, _ = struct.unpack('!HHHHHH', data[:12])
if not (flags & 0x8000) or qd != 1: raise SystemExit('invalid DNS response')
off = 12
while data[off]: off += data[off] + 1
off += 5
for _ in range(answers):
    if data[off] & 0xc0 == 0xc0: off += 2
    else:
        while data[off]: off += data[off] + 1
        off += 1
    typ, cls, _, size = struct.unpack('!HHIH', data[off:off+10]); off += 10
    value = data[off:off+size]; off += size
    if typ == 1 and cls == 1 and size == 4: print(ipaddress.IPv4Address(value))
''', encoding="utf-8")
        nslookup = self.executable(self.root / "nslookup", '''#!/bin/sh
_host=$1; _resolver=$2
if [ "$_resolver" = 127.0.0.1 ]; then
  _answers=$(python3 "$DNS_QUERY_HELPER" "$_host" "$DNSMASQ_PORT") || exit 1
else
  _answers=${DISCOVERY_IP:-}
fi
printf 'Server: %s\\nAddress: %s\\n\\nNon-authoritative answer:\\nName: %s\\n' "$_resolver" "$_resolver" "$_host"
printf '%s\\n' "$_answers" | while IFS= read -r _ip; do [ -n "$_ip" ] && printf 'Address: %s\\n' "$_ip"; done
''')
        curl = self.executable(self.root / "curl", '''#!/bin/sh
_endpoint=""; _url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve) _endpoint=$2; shift ;;
    https://*) _url=$1 ;;
  esac
  shift
done
_host=${_endpoint%%:*}; _ip=${_endpoint##*:}
case "$_url" in "https://$_host/") ;; *) exit 2 ;; esac
case "$_host" in v77.tiktokcdn.com|v77.tiktokcdn-eu.com) ;; *) exit 2 ;; esac
case "$_ip" in
  87.245.200.8) _total=0.131 ;;
  87.245.200.35) _total=0.072 ;;
  *) exit 7 ;;
esac
printf 'HTTP/1.1 400 Bad Request\\r\\nX-77-Pop: acceptance-pop\\r\\nServer: acceptance-cdn\\r\\n\\r\\n'
printf '\\nZ2M_TIKTOK_METRICS:400|0.020|0.050|%s' "$_total"
''')
        uci = self.executable(self.root / "uci", '''#!/bin/sh
[ "${1:-}" = -q ] && shift
_cmd=$1; shift
case $_cmd in
  show) if [ "${1:-}" = dhcp.@dnsmasq[0] ]; then grep -q "^dhcp.@dnsmasq\\[0\\]=" "$UCI_TEST_DB"; else cat "$UCI_TEST_DB"; fi ;;
  commit) exit 0 ;;
  add_list) _path=${1%%=*}; _value=${1#*=}; printf "%s='%s'\\n" "$_path" "$_value" >> "$UCI_TEST_DB" ;;
  del_list) _path=${1%%=*}; _value=${1#*=}; awk -v p="$_path" -v v="'$_value'" 'index($0,p"="v)==0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new" && mv "$UCI_TEST_DB.new" "$UCI_TEST_DB" ;;
  *) exit 2 ;;
esac
''')
        init = self.executable(self.root / "dnsmasq-init", '''#!/bin/sh
[ "${1:-}" = restart ] || exit 1
if [ -r "$DNSMASQ_PID_FILE" ]; then kill "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null || true; sleep 0.12; fi
{
  printf 'listen-address=127.0.0.1\\nport=%s\\nbind-interfaces\\nno-resolv\\nno-hosts\\ncache-size=0\\nserver=127.0.0.1#%s\\n' "$DNSMASQ_PORT" "$UPSTREAM_PORT"
  while IFS= read -r _line; do case $_line in *.address=*) _value=${_line#*=}; _value=${_value#\\\'}; _value=${_value%\\\'}; printf 'address=%s\\n' "$_value" ;; esac; done < "$UCI_TEST_DB"
} > "$DNSMASQ_CONFIG"
"$DNSMASQ_BIN" --no-daemon --conf-file="$DNSMASQ_CONFIG" >> "$DNSMASQ_LOG" 2>&1 & echo $! > "$DNSMASQ_PID_FILE"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do python3 "$DNS_QUERY_HELPER" "$TIKTOK_HOST" "$DNSMASQ_PORT" >/dev/null 2>&1 && exit 0; sleep 0.05; done
exit 1
''')
        (state / "config").write_text("Z2K_TIKTOK_FEED_ENABLED=1\n", encoding="ascii")
        env = os.environ.copy()
        env.update({
            "Z2K_TIKTOK_HOSTS_FILE": str(state / "hosts"),
            "Z2K_TIKTOK_UCI_MARKER": str(state / ".addnhosts-owned"),
            "Z2K_TIKTOK_CONTENT_MARKER": str(state / ".hosts-owned"),
            "Z2K_TIKTOK_ADDRESS_MARKER": str(state / ".address-owned"),
            "Z2K_TIKTOK_STATE_FILE": str(state / "tiktok.state"),
            "Z2K_TIKTOK_CONFIG": str(state / "config"),
            "Z2K_TIKTOK_APPLY_LOCK": str(state / "apply.lock"),
            "Z2K_TIKTOK_EFFECTIVE_CONFIG": str(config),
            "Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES": "1",
            "Z2K_TIKTOK_UCI_BIN": str(uci),
            "Z2K_TIKTOK_DNSMASQ_INIT": str(init),
            "Z2K_TIKTOK_NSLOOKUP_BIN": str(nslookup),
            "Z2K_TIKTOK_CURL_BIN": str(curl),
            "Z2K_TIKTOK_CHECKHOST_ENABLED": "0",
            "Z2K_TIKTOK_RESOLVER_STATE": str(resolver_file),
            "Z2K_TIKTOK_RESOLVER_FALLBACK": str(resolver_file),
            "DISCOVERY_IP": ip_a,
            "UCI_TEST_DB": str(uci_db), "DNSMASQ_CONFIG": str(config),
            "DNSMASQ_PID_FILE": str(self.root / "dnsmasq.pid"),
            "DNSMASQ_LOG": str(self.root / "dnsmasq.log"),
            "DNSMASQ_PORT": str(self.port), "UPSTREAM_PORT": str(self.upstream.port),
            "DNSMASQ_BIN": self.dnsmasq, "DNS_QUERY_HELPER": str(query_py),
            "TIKTOK_HOST": HOST,
        })
        tiktok_sh = Path(__file__).resolve().parents[2] / "platform/openwrt/tiktok.sh"

        def call_adapter(function: str, *args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
            result = subprocess.run(
                ["sh", "-c", f'. "{tiktok_sh}"; {function} "$@"', "adapter", *args],
                env=env, text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode == 0, expect_success, result.stderr + result.stdout)
            return result

        # Auto selection discovers A and reaches the production apply helper itself.
        call_adapter("z2k_ow_tiktok_check", "explicit")
        self.assertEqual([ip_a], query_a(self.port))
        self.assertEqual([ip_a], query_a(self.port, EU_HOST))
        self.assertIn(f"selected_ip={ip_a}", (state / "tiktok.state").read_text(encoding="ascii"))
        self.assertIn(f"address=/{HOST}/{ip_a}", config.read_text(encoding="ascii"))
        self.assertIn(f"address=/{EU_HOST}/{ip_a}", config.read_text(encoding="ascii"))

        # A manual selection changes to B through tiktok.sh and takes effect in real dnsmasq.
        call_adapter("z2k_ow_tiktok_manual_select", ip_b)
        self.assertEqual([ip_b], query_a(self.port))
        self.assertEqual([ip_b], query_a(self.port, EU_HOST))
        self.assertIn(f"Z2K_TIKTOK_MANUAL_IP={ip_b}", (state / "config").read_text(encoding="ascii"))
        self.assertNotIn(ip_a, query_a(self.port))

        # A dnsmasq restart consumes the persisted UCI record and keeps B live.
        subprocess.run([str(init), "restart"], env=env, check=True, capture_output=True, text=True)
        self.assertEqual([ip_b], query_a(self.port))
        self.assertEqual([ip_b], query_a(self.port, EU_HOST))

        # Disable removes the owned UCI entry; the actual daemon returns upstream DNS again.
        call_adapter("z2k_ow_tiktok_disable")
        self.assertNotIn(f"/{HOST}/{ip_b}", uci_db.read_text(encoding="ascii"))
        self.assertNotIn(f"/{EU_HOST}/{ip_b}", uci_db.read_text(encoding="ascii"))
        self.assertEqual([FALLBACK_IP], query_a(self.port))
        self.assertEqual([FALLBACK_IP], query_a(self.port, EU_HOST))

        # A user-owned entry blocks z2kOW apply and stays effective.
        subprocess.run([str(uci), "add_list", f"dhcp.@dnsmasq[0].address=/{HOST}/{external_ip}"], env=env, check=True)
        subprocess.run([str(init), "restart"], env=env, check=True, capture_output=True, text=True)
        call_adapter("_z2k_ow_tiktok_set_host", ip_a, expect_success=False)
        self.assertIn(f"/{HOST}/{external_ip}", uci_db.read_text(encoding="ascii"))
        self.assertNotIn(f"/{HOST}/{ip_a}", uci_db.read_text(encoding="ascii"))
        self.assertEqual([external_ip], query_a(self.port))
        self.assertEqual([FALLBACK_IP], query_a(self.port, EU_HOST))


if __name__ == "__main__":
    unittest.main(verbosity=2)
