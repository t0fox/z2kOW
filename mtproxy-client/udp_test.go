package main

import (
	"bytes"
	"encoding/binary"
	"net/netip"
	"testing"
	"time"
)

func TestUDPPackets(t *testing.T) {
	for _, a := range [][2]string{{"192.168.1.12:45000", "149.154.167.50:599"}, {"[fd00::12]:45000", "[2001:b28:f23d::1]:599"}} {
		tuple := udpTuple{netip.MustParseAddrPort(a[0]), netip.MustParseAddrPort(a[1])}
		for _, n := range []int{0, 1, 20, 1200, 1452} {
			data := bytes.Repeat([]byte{0xa5}, n)
			p := makeUDPPacket(tuple, data)
			got, b, ok := parseUDPPacket(p)
			if !ok || got != tuple || !bytes.Equal(data, b) {
				t.Fatalf("roundtrip %s/%d", a[0], n)
			}
			p[len(p)-1] ^= 1
			if _, _, ok := parseUDPPacket(p); ok {
				t.Fatal("corrupt packet accepted")
			}
		}
	}
}
func TestUDPFragmentAndLengthRejected(t *testing.T) {
	tuple := udpTuple{netip.MustParseAddrPort("192.168.1.1:5"), netip.MustParseAddrPort("149.154.167.50:599")}
	b := makeUDPPacket(tuple, []byte("hi"))
	b[6] = 0x20
	b[10] = 0
	b[11] = 0
	binary.BigEndian.PutUint16(b[10:], foldSum(internetSum(b[:20])))
	if _, _, ok := parseUDPPacket(b); ok {
		t.Fatal("fragment accepted")
	}
	for n := 0; n < len(b); n++ {
		if _, _, ok := parseUDPPacket(b[:n]); ok {
			t.Fatal("truncation accepted")
		}
	}
}
func TestUDPClientFlowIsolationAndExpiry(t *testing.T) {
	s := newUDPClientSession()
	dst := netip.MustParseAddrPort("149.154.167.50:599")
	one := udpTuple{netip.MustParseAddrPort("192.168.1.10:4000"), dst}
	two := udpTuple{netip.MustParseAddrPort("192.168.1.11:4000"), dst}
	s.packet(one, []byte("first"))
	s.packet(two, []byte("second"))
	for _, want := range []udpTuple{one, two} {
		d := <-s.queue
		p, e := s.reply(d.b)
		if e != nil {
			t.Fatal(e)
		}
		got, _, ok := parseUDPPacket(p)
		if !ok || got.src != want.dst || got.dst != want.src {
			t.Fatal("reply crossed client flows")
		}
	}
	id := s.ids[one]
	s.flows[id] = udpClientFlow{one, time.Now().Add(-91 * time.Second)}
	s.packet(one, nil)
	if s.ids[one] == id {
		t.Fatal("expired id reused")
	}
	bad := encodeMuxFrame(s.ids[two], udpData, udpEndpoint(netip.MustParseAddrPort("127.0.0.1:9")))
	if _, e := s.reply(bad); e == nil {
		t.Fatal("retarget accepted")
	}
	if len(s.flows) != 2 {
		t.Fatal("expiry leak")
	}
}
func FuzzUDPPacket(f *testing.F) {
	f.Add([]byte{0x45})
	f.Add(makeUDPPacket(udpTuple{netip.MustParseAddrPort("192.168.1.2:5000"), netip.MustParseAddrPort("149.154.167.50:599")}, []byte("voice")))
	f.Add(makeUDPPacket(udpTuple{netip.MustParseAddrPort("[fd00::2]:5000"), netip.MustParseAddrPort("[2001:b28:f23d::1]:599")}, []byte("voice")))
	f.Fuzz(func(t *testing.T, b []byte) {
		tuple, p, ok := parseUDPPacket(b)
		if ok {
			out := makeUDPPacket(tuple, p)
			got, pp, valid := parseUDPPacket(out)
			if !valid || got != tuple || !bytes.Equal(pp, p) {
				t.Fatal("packet roundtrip")
			}
		}
	})
}
