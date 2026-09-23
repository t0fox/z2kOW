package domainroute

import (
	"encoding/binary"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func dnsName(s string) dnsmessage.Name { return dnsmessage.MustNewName(s + ".") }

func aRecord(name string, ip [4]byte, ttl uint32) dnsmessage.Resource {
	return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsName(name), Class: dnsmessage.ClassINET, TTL: ttl}, Body: &dnsmessage.AResource{A: ip}}
}

func cnameRecord(name, target string, ttl uint32) dnsmessage.Resource {
	return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsName(name), Class: dnsmessage.ClassINET, TTL: ttl}, Body: &dnsmessage.CNAMEResource{CNAME: dnsName(target)}}
}

func reply(t *testing.T, answers, extras []dnsmessage.Resource) []byte {
	t.Helper()
	m := dnsmessage.Message{Header: dnsmessage.Header{Response: true}, Questions: []dnsmessage.Question{{Name: dnsName("selected.example"), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}, Answers: answers, Additionals: extras}
	b, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParseReplyCNAMEChainIgnoresUnrelatedAdditional(t *testing.T) {
	b := reply(t, []dnsmessage.Resource{cnameRecord("selected.example", "cdn.example", 20), aRecord("cdn.example", [4]byte{8, 8, 8, 8}, 40)}, []dnsmessage.Resource{aRecord("unrelated.example", [4]byte{1, 1, 1, 1}, 60)})
	name, got, err := ParseReply(b, TransportUDP)
	if err != nil {
		t.Fatal(err)
	}
	if name != "selected.example" || len(got) != 1 || got[0].IP != netip.MustParseAddr("8.8.8.8") || got[0].TTL != 20*time.Second {
		t.Fatalf("name=%q answers=%+v", name, got)
	}
}

func TestParseReplyTCPAndMalformed(t *testing.T) {
	b := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 4, 4}, 30)}, nil)
	framed := make([]byte, 2+len(b))
	binary.BigEndian.PutUint16(framed, uint16(len(b)))
	copy(framed[2:], b)
	_, got, err := ParseReply(framed, TransportTCP)
	if err != nil || len(got) != 1 {
		t.Fatalf("tcp: %v %+v", err, got)
	}
	if _, _, err = ParseReply(framed[:len(framed)-1], TransportTCP); err == nil {
		t.Fatal("accepted truncated TCP DNS")
	}
	if _, _, err = ParseReply([]byte{1, 2, 3}, TransportUDP); err == nil {
		t.Fatal("accepted malformed DNS")
	}
}

func TestParseReplyRejectsPrivateAndZeroTTL(t *testing.T) {
	b := reply(t, []dnsmessage.Resource{
		aRecord("selected.example", [4]byte{10, 0, 0, 1}, 10),
		aRecord("selected.example", [4]byte{100, 64, 0, 1}, 10),
		aRecord("selected.example", [4]byte{192, 0, 2, 1}, 10),
		aRecord("selected.example", [4]byte{224, 0, 0, 1}, 10),
		aRecord("selected.example", [4]byte{8, 8, 8, 8}, 0),
	}, nil)
	_, got, err := ParseReply(b, TransportUDP)
	if err != nil || len(got) != 0 {
		t.Fatalf("private/zero TTL accepted: %v %+v", err, got)
	}
}
