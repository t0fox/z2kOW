package domainroute

import (
	"encoding/binary"
	"golang.org/x/net/dns/dnsmessage"
	"net/netip"
	"testing"
	"time"
)

func ipv4Packet(proto byte, src, dst [4]byte, transport []byte) []byte {
	b := make([]byte, 20+len(transport))
	b[0] = 0x45
	b[9] = proto
	binary.BigEndian.PutUint16(b[2:4], uint16(len(b)))
	copy(b[12:16], src[:])
	copy(b[16:20], dst[:])
	copy(b[20:], transport)
	return b
}
func udpDNS(payload []byte) []byte {
	b := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint16(b[0:2], 53)
	binary.BigEndian.PutUint16(b[2:4], 50000)
	binary.BigEndian.PutUint16(b[4:6], uint16(len(b)))
	copy(b[8:], payload)
	return b
}
func tcpDNS(seq uint32, payload []byte) []byte {
	b := make([]byte, 20+len(payload))
	binary.BigEndian.PutUint16(b[0:2], 53)
	binary.BigEndian.PutUint16(b[2:4], 50000)
	binary.BigEndian.PutUint32(b[4:8], seq)
	b[12] = 0x50
	copy(b[20:], payload)
	return b
}

func TestPacketDecoderScopesUDPReplyToLANClient(t *testing.T) {
	d := NewPacketDecoder()
	dns := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 8, 8}, 30)}, nil)
	frame := ipv4Packet(17, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, udpDNS(dns))
	client, got, transport := d.Push(frame, time.Unix(100, 0))
	if client != netip.MustParseAddr("192.168.1.10") || transport != TransportUDP || string(got) != string(dns) {
		t.Fatalf("client=%v transport=%v bytes=%d", client, transport, len(got))
	}
	frame[20] = 0
	frame[21] = 1
	if _, got, _ := d.Push(frame, time.Unix(100, 0)); got != nil {
		t.Fatal("accepted non-DNS source port")
	}
}

func TestPacketDecoderReassemblesBoundedTCPDNS(t *testing.T) {
	d := NewPacketDecoder()
	dns := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 8, 8}, 30)}, nil)
	framed := make([]byte, 2+len(dns))
	binary.BigEndian.PutUint16(framed, uint16(len(dns)))
	copy(framed[2:], dns)
	first := ipv4Packet(6, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, tcpDNS(100, framed[:10]))
	second := ipv4Packet(6, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, tcpDNS(110, framed[10:]))
	if _, got, _ := d.Push(first, time.Unix(100, 0)); got != nil {
		t.Fatal("partial TCP frame emitted")
	}
	client, got, transport := d.Push(second, time.Unix(100, 0))
	if client != netip.MustParseAddr("192.168.1.10") || transport != TransportTCP || string(got) != string(framed) {
		t.Fatalf("bad TCP reassembly: %v %v %d", client, transport, len(got))
	}
}
