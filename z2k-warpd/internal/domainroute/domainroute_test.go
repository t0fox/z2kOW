package domainroute

import (
	"context"
	"encoding/binary"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestCacheScopesPairsToClientAndKeepsSharedJustification(t *testing.T) {
	r, err := ParseRules([]byte("v1\na.example\nb.example\n"))
	if err != nil {
		t.Fatal(err)
	}
	c := NewCache(r)
	now := time.Unix(100, 0)
	a := netip.MustParseAddr("192.168.1.10")
	b := netip.MustParseAddr("192.168.1.11")
	ip := netip.MustParseAddr("8.8.8.8")
	if got := c.Observe(a, "a.example", []Answer{{ip, 20 * time.Second}}, now); len(got) != 1 || got[0].Delete {
		t.Fatalf("first pair: %+v", got)
	}
	if got := c.Observe(b, "a.example", []Answer{{ip, 20 * time.Second}}, now); len(got) != 1 || got[0].Client != b {
		t.Fatalf("second client: %+v", got)
	}
	if got := c.Observe(a, "b.example", []Answer{{ip, 30 * time.Second}}, now); len(got) != 1 || got[0].Delete {
		t.Fatalf("longer shared expiry: %+v", got)
	}
	r, _ = ParseRules([]byte("v1\nb.example\n"))
	changes := c.ReplaceRules(r, now)
	for _, ch := range changes {
		if ch.Client == a && ch.Delete {
			t.Fatal("removed shared pair")
		}
	}
	if c.Len() != 1 {
		t.Fatalf("wanted one retained pair, got %d", c.Len())
	}
	r, _ = ParseRules([]byte("v1\n"))
	changes = c.ReplaceRules(r, now)
	if len(changes) != 1 || !changes[0].Delete || c.Len() != 0 {
		t.Fatalf("not deleted after both names removed: %+v", changes)
	}
}

func TestCacheJustificationCapDoesNotLeaveEmptyRoute(t *testing.T) {
	r, _ := ParseRules([]byte("v1\n*.example.com\n"))
	c := NewCache(r)
	k := pair{netip.MustParseAddr("192.168.1.10"), netip.MustParseAddr("8.8.8.8")}
	c.pairs[k] = make(map[string]time.Time)
	for i := 0; i < maxJustifications; i++ {
		c.pairs[k][fmt.Sprintf("n%d.example.com", i)] = time.Unix(200, 0)
	}
	got := c.Observe(netip.MustParseAddr("192.168.1.11"), "new.example.com", []Answer{{netip.MustParseAddr("1.1.1.1"), 10 * time.Second}}, time.Unix(100, 0))
	if len(got) != 0 || c.Len() != 1 {
		t.Fatalf("cap left empty pair: changes=%+v pairs=%d", got, c.Len())
	}
}

func TestCacheCapsDistinctClientsToBoundFirewallRules(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	c := NewCache(r)
	now := time.Unix(100, 0)
	ip := netip.MustParseAddr("8.8.8.8")
	for i := 1; i <= 128; i++ {
		client := netip.AddrFrom4([4]byte{10, 0, 0, byte(i)})
		if got := c.Observe(client, "selected.example", []Answer{{ip, 10 * time.Second}}, now); len(got) != 1 {
			t.Fatalf("client %d rejected", i)
		}
	}
	if got := c.Observe(netip.MustParseAddr("10.0.0.129"), "selected.example", []Answer{{ip, 10 * time.Second}}, now); len(got) != 0 || c.Len() != 128 {
		t.Fatalf("129th client admitted: %+v pairs=%d", got, c.Len())
	}
}

func TestCacheRejectsNonLANClient(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	c := NewCache(r)
	got := c.Observe(netip.MustParseAddr("8.8.4.4"), "selected.example",
		[]Answer{{netip.MustParseAddr("1.1.1.1"), time.Minute}}, time.Unix(100, 0))
	if len(got) != 0 || c.Len() != 0 {
		t.Fatalf("public source admitted: %+v", got)
	}
}

func TestCacheExpiryLimitsAndZeroTTL(t *testing.T) {
	r, _ := ParseRules([]byte("v1\na.example\n"))
	c := NewCache(r)
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	ip := netip.MustParseAddr("8.8.8.8")
	if got := c.Observe(client, "a.example", []Answer{{ip, 0}}, now); len(got) != 0 {
		t.Fatalf("zero TTL: %+v", got)
	}
	got := c.Observe(client, "a.example", []Answer{{ip, 2 * time.Hour}}, now)
	if len(got) != 1 || !got[0].Expiry.Equal(now.Add(time.Hour)) {
		t.Fatalf("TTL cap: %+v", got)
	}
	if got := c.Expire(now.Add(59 * time.Minute)); len(got) != 0 {
		t.Fatalf("expired early: %+v", got)
	}
	if got := c.Expire(now.Add(time.Hour)); len(got) != 1 || !got[0].Delete {
		t.Fatalf("not expired: %+v", got)
	}
}

func TestSnapshotRestoresOnlyCurrentlySelectedAndUnexpiredNames(t *testing.T) {
	r, _ := ParseRules([]byte("v1\na.example\nb.example\n"))
	c := NewCache(r)
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	c.Observe(client, "a.example", []Answer{{netip.MustParseAddr("8.8.8.8"), 20 * time.Second}}, now)
	c.Observe(client, "b.example", []Answer{{netip.MustParseAddr("1.1.1.1"), 10 * time.Second}}, now)
	path := t.TempDir() + "/pairs.v1"
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	r, _ = ParseRules([]byte("v1\na.example\n"))
	restored := NewCache(r)
	if err := restored.Load(path, now.Add(11*time.Second)); err != nil {
		t.Fatal(err)
	}
	if restored.Len() != 1 {
		t.Fatalf("restored %d pairs, wanted one", restored.Len())
	}
	if err := restored.Load(path, now.Add(21*time.Second)); err != nil {
		t.Fatal(err)
	}
	if restored.Len() != 0 {
		t.Fatalf("restored expired pair: %d", restored.Len())
	}
}

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

func pairSetStubs(t *testing.T, stale string) (PairSet, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "commands")
	ipset := filepath.Join(dir, "ipset")
	iptables := filepath.Join(dir, "iptables")
	ipsetScript := "#!/bin/sh\necho \"ipset $*\" >> \"$Z2K_PAIR_LOG\"\n" +
		"if [ \"$1 $2\" = 'list -n' ]; then printf '%s\\n' \"$Z2K_STALE_SET\"; fi\n" +
		"if [ \"$1 $2\" = 'save z2kd_192.168.1.10' ]; then :; fi\n"
	iptablesScript := "#!/bin/sh\necho \"iptables $*\" >> \"$Z2K_PAIR_LOG\"\ncase \"$*\" in *' -C '*) exit 1;; esac\n"
	if err := os.WriteFile(ipset, []byte(ipsetScript), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(iptables, []byte(iptablesScript), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("Z2K_PAIR_LOG", log)
	t.Setenv("Z2K_STALE_SET", stale)
	return PairSet{Binary: ipset, IPTablesBinary: iptables}, log
}

func TestPairSetWritesClientScopedDestinationAndTimeout(t *testing.T) {
	s, log := pairSetStubs(t, "")
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	dest := netip.MustParseAddr("8.8.8.8")
	if err := s.Apply([]Change{{Client: client, Dest: dest, Expiry: now.Add(20 * time.Second)}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	for _, part := range []string{
		"ipset create z2kd_192.168.1.10 hash:ip family inet timeout 3600 maxelem 8192 -exist",
		"ipset add z2kd_192.168.1.10 8.8.8.8 timeout 20 -exist",
		"iptables -w -t mangle -A PREROUTING -s 192.168.1.10/32 -m set --match-set z2kd_192.168.1.10 dst -j MARK --set-xmark 0x989/0x989",
	} {
		if !strings.Contains(string(b), part) {
			t.Fatalf("missing %q in %s", part, b)
		}
	}
	if err := s.Apply([]Change{{Client: client, Dest: dest, Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(log)
	if !strings.Contains(string(b), "ipset del z2kd_192.168.1.10 8.8.8.8 -exist") {
		t.Fatalf("missing deletion: %s", b)
	}
}

func TestPairSetReplacesStaleClientSets(t *testing.T) {
	s, log := pairSetStubs(t, "z2kd_192.168.1.99")
	if err := s.ReplaceAll(nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	for _, part := range []string{
		"iptables -w -t mangle -D PREROUTING -s 192.168.1.99/32 -m set --match-set z2kd_192.168.1.99 dst -j MARK --set-xmark 0x989/0x989",
		"ipset destroy z2kd_192.168.1.99",
	} {
		if !strings.Contains(got, part) {
			t.Fatalf("missing %q in %s", part, got)
		}
	}
}

func TestObserverLearnsOnlySelectedAnswerForReceivingClient(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	o := NewObserver(r)
	dns := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 8, 8}, 30)}, nil)
	frame := ipv4Packet(17, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, udpDNS(dns))
	changes := o.Process(frame, time.Unix(100, 0))
	if len(changes) != 1 || changes[0].Client != netip.MustParseAddr("192.168.1.10") || changes[0].Dest != netip.MustParseAddr("8.8.8.8") {
		t.Fatalf("wrong learned route: %+v", changes)
	}
	r, _ = ParseRules([]byte("v1\n"))
	changes = o.ReplaceRules(r, time.Unix(101, 0))
	if len(changes) != 1 || !changes[0].Delete {
		t.Fatalf("rule removal left route: %+v", changes)
	}
}

func TestObserverNeverRoutesRouterOwnedPublicAddress(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	o := NewObserver(r)
	o.SetLocalAddresses([]netip.Addr{netip.MustParseAddr("8.8.8.8")})
	dns := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 8, 8}, 30)}, nil)
	frame := ipv4Packet(17, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, udpDNS(dns))
	if got := o.Process(frame, time.Unix(100, 0)); len(got) != 0 {
		t.Fatalf("router address routed: %+v", got)
	}
}

func TestObserverWithdrawsPairWhenAddressBecomesRouterOwned(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	o := NewObserver(r)
	dns := reply(t, []dnsmessage.Resource{aRecord("selected.example", [4]byte{8, 8, 8, 8}, 30)}, nil)
	frame := ipv4Packet(17, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, udpDNS(dns))
	if got := o.Process(frame, time.Unix(100, 0)); len(got) != 1 {
		t.Fatalf("first observation: %+v", got)
	}
	changes := o.SetLocalAddresses([]netip.Addr{netip.MustParseAddr("8.8.8.8")})
	if len(changes) != 1 || !changes[0].Delete {
		t.Fatalf("local address route remained: %+v", changes)
	}
}

func TestObserverDuplicateDoesNotOverwriteActiveStatus(t *testing.T) {
	dir := t.TempDir()
	lock := filepath.Join(dir, "observer.lock")
	f, err := os.OpenFile(lock, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	status := filepath.Join(dir, "status.json")
	if err := os.WriteFile(status, []byte(`{"active":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	r, _ := ParseRules([]byte("v1\n"))
	o := NewObserver(r)
	err = o.Run(context.Background(), Options{DomainPath: filepath.Join(dir, "domains.v1"), SnapshotPath: filepath.Join(dir, "pairs.v1"), StatusPath: status, PairSet: PairSet{}})
	if err != ErrObserverAlreadyRunning {
		t.Fatalf("duplicate error = %v", err)
	}
	b, _ := os.ReadFile(status)
	if string(b) != `{"active":true}` {
		t.Fatalf("duplicate overwrote active status: %s", b)
	}
}

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

func TestRulesWildcardExcludesApexAndNormalizesCase(t *testing.T) {
	r, err := ParseRules([]byte("v1\n*.Example.COM\nexact.example\n"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.example.com", "a.b.example.com", "EXACT.EXAMPLE"} {
		if !r.Match(name) {
			t.Errorf("should match %s", name)
		}
	}
	for _, name := range []string{"example.com", "notexample.com", "a.example.net"} {
		if r.Match(name) {
			t.Errorf("unexpected match %s", name)
		}
	}
}

func TestRulesRejectWrongVersion(t *testing.T) {
	if _, err := ParseRules([]byte("v2\nexample.com\n")); err == nil {
		t.Fatal("accepted unknown snapshot version")
	}
}
