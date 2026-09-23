package domainroute

import (
	"context"
	"golang.org/x/net/dns/dnsmessage"
	"net/netip"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

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
