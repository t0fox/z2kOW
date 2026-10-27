package domainroute

import (
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPairSetDeduplicatesCreateAndMarkPerClientInBatch(t *testing.T) {
	s, log := pairSetStubs(t, "")
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	d1 := netip.MustParseAddr("8.8.8.8")
	d2 := netip.MustParseAddr("8.8.4.4")
	if err := s.Apply([]Change{
		{Client: client, Dest: d1, Expiry: now.Add(20 * time.Second)},
		{Client: client, Dest: d2, Expiry: now.Add(30 * time.Second)},
	}, now); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	if n := strings.Count(got, "ipset create z2kd_192.168.1.10"); n != 1 {
		t.Fatalf("expected 1 ipset create for batch, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "iptables -w -t mangle -A PREROUTING -s 192.168.1.10/32"); n != 1 {
		t.Fatalf("expected 1 iptables -A for batch, got %d:\n%s", n, got)
	}
}
