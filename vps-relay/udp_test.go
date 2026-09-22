package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestUDPAllowlist(t *testing.T) {
	for _, a := range []string{"149.154.167.50", "91.108.4.1", "2001:b28:f23c::1", "2a0a:f280::1"} {
		if !allowedUDP(netip.MustParseAddr(a)) {
			t.Fatal(a)
		}
	}
	for _, a := range []string{"127.0.0.1", "192.168.1.1", "8.8.8.8", "224.0.0.1", "149.154.160.0", "149.154.175.255", "::ffff:149.154.167.50", "::1", "fe80::1", "168.119.95.238"} {
		if allowedUDP(netip.MustParseAddr(a)) {
			t.Fatal(a)
		}
	}
}
func udpTestConnection(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	id, key := testInstall(t)
	d := *websocket.DefaultDialer
	d.Subprotocols = []string{"z2k-udp-v1"}
	ws, _, err := d.Dial(url+"?transport=udp-v1", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	if ws.Subprotocol() != "z2k-udp-v1" {
		t.Fatal("capability")
	}
	handshakeV2Over(t, ws, id, key, "udp-test")
	return ws
}
func TestUDPRelayDatagramIsolationAndForbidden(t *testing.T) {
	ln, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		b := make([]byte, 2048)
		for {
			n, a, e := ln.ReadFrom(b)
			if e != nil {
				return
			}
			ln.WriteTo(b[:n], a)
		}
	}()
	var dials atomic.Int32
	old := udpDial
	udpDial = func(a netip.AddrPort) (net.Conn, error) {
		dials.Add(1)
		return net.Dial("udp4", ln.LocalAddr().String())
	}
	defer func() { udpDial = old }()
	ws := udpTestConnection(t, startRelay(t))
	for i := 1; i <= 3; i++ {
		for _, n := range []int{0, 1, 1200, 1472} {
			p := append(connectPayload(tgTarget, 599), bytes.Repeat([]byte{byte(i)}, n)...)
			sendFrame(t, ws, uint16(i), udpData, p)
			got := expectFrame(t, ws, uint16(i), udpData, time.Second)
			if !bytes.Equal(got, p) {
				t.Fatalf("boundary %d/%d", i, n)
			}
		}
	}
	if dials.Load() != 3 {
		t.Fatal("flow mapping", dials.Load())
	}
	sendFrame(t, ws, 4, udpData, connectPayload("127.0.0.1", 9))
	ws.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, e := ws.ReadMessage(); e == nil {
		t.Fatal("forbidden accepted")
	}
	if dials.Load() != 3 {
		t.Fatal("forbidden dial")
	}
}
func TestUDPRateAndFrameBounds(t *testing.T) {
	var r udpRate
	now := time.Now()
	for i := 0; i < 200; i++ {
		if !r.allow(now, 1) {
			t.Fatal("burst")
		}
	}
	if r.allow(now, 1) {
		t.Fatal("unbounded packets")
	}
	if !r.allow(now.Add(time.Second), 100) {
		t.Fatal("no refill")
	}
	p := connectPayload(tgTarget, 599)
	if _, _, ok := decodeUDP(append(p, make([]byte, udpMaxPayload+1)...)); ok {
		t.Fatal("oversize")
	}
	for i := 0; i < len(p); i++ {
		if _, _, ok := decodeUDP(p[:i]); ok {
			t.Fatal("short endpoint")
		}
	}
}

func TestUDPInstallLimit(t *testing.T) {
	a := &session{relayID: "udp-quota-test"}
	b := &session{relayID: a.relayID}
	if !acquireUDPInstall(a) {
		t.Fatal("first channel rejected")
	}
	defer releaseUDPInstall(a)
	if acquireUDPInstall(b) {
		releaseUDPInstall(b)
		t.Fatal("second channel bypassed per-install quota")
	}
	releaseUDPInstall(b) // unrelated session must not release a's slot
	if acquireUDPInstall(b) {
		releaseUDPInstall(b)
		t.Fatal("non-owner released slot")
	}
	releaseUDPInstall(a)
	if !acquireUDPInstall(b) {
		t.Fatal("slot leaked after disconnect")
	}
	releaseUDPInstall(b)
}
func TestUDPWriterDropsStaleMedia(t *testing.T) {
	s, client, cleanup := newTestSession(t)
	defer cleanup()
	s.writer.datagrams = make(chan udpQueued, 64)
	s.writer.datagrams <- udpQueued{[]byte("stale"), time.Now().Add(-time.Second)}
	s.writer.datagrams <- udpQueued{[]byte("fresh"), time.Now()}
	go s.writer.run()
	client.SetReadDeadline(time.Now().Add(time.Second))
	_, b, e := client.ReadMessage()
	if e != nil || string(b) != "fresh" {
		t.Fatalf("queued old media: %q %v", b, e)
	}
}

func TestUDPAllowlistRouterAndFirewallParity(t *testing.T) {
	b, e := os.ReadFile("../files/z2k-tg-redirect.sh")
	if e != nil {
		t.Fatal(e)
	}
	re := regexp.MustCompile(`(?m)^Z2K_TG_CIDRS="([^"]+)"`)
	m := re.FindStringSubmatch(string(b))
	if len(m) != 2 {
		t.Fatal("router IPv4 ranges missing")
	}
	cidrs := strings.Fields(m[1])
	if len(cidrs) != len(telegramV4) {
		t.Fatal("router/server range count drift")
	}
	for _, s := range cidrs {
		p := netip.MustParsePrefix(s)
		ip := p.Addr().As4()
		r := netRange{net: binary.BigEndian.Uint32(ip[:]), mask: ^uint32(0) << (32 - p.Bits())}
		found := false
		for _, got := range telegramV4 {
			if got == r {
				found = true
			}
		}
		if !found {
			t.Fatalf("server missing %s", s)
		}
	}
	fw, e := os.ReadFile("../vps/config/z2k/telegram-udp-cidrs.txt")
	if e != nil {
		t.Fatal(e)
	}
	if strings.Join(strings.Fields(string(fw)), " ") != strings.Join(cidrs, " ") {
		t.Fatal("firewall/router allowlists drifted")
	}
	m = regexp.MustCompile(`(?m)^Z2K_TG_CIDRS6="([^"]+)"`).FindStringSubmatch(string(b))
	if len(m) != 2 {
		t.Fatal("router IPv6 ranges missing")
	}
	six := strings.Fields(m[1])
	if len(six) != len(udpV6) {
		t.Fatal("IPv6 count drift")
	}
	for _, s := range six {
		p := netip.MustParsePrefix(s)
		found := false
		for _, got := range udpV6 {
			if p == got {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing IPv6 range %s", s)
		}
	}
}
