//go:build openwrt

package domainroute

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testNFTSet(name string, check func() error, run func(string) error) *nftPairSet {
	s := &nftPairSet{family: "inet", table: "zapret2", set: name, check: check, run: run}
	nftPairStates.Lock()
	delete(nftPairStates.sets, s.key())
	nftPairStates.Unlock()
	return s
}

func TestOpenWrtNFTPairSetReconcileAndTTL(t *testing.T) {
	now := time.Unix(1_000, 0)
	var got string
	set := testNFTSet("pairs_reconcile", func() error { return nil }, func(script string) error { got = script; return nil })
	client := netip.MustParseAddr("192.168.1.20")
	dest := netip.MustParseAddr("104.21.45.34")
	if err := set.ReplaceAll([]Change{{Client: client, Dest: dest, Expiry: now.Add(90 * time.Second)}}, now); err != nil {
		t.Fatal(err)
	}
	want := "flush set inet zapret2 pairs_reconcile\nadd element inet zapret2 pairs_reconcile { 192.168.1.20 . 104.21.45.34 timeout 90s }\n"
	if got != want {
		t.Fatalf("nft transaction:\n%s\nwant:\n%s", got, want)
	}
	if err := set.ReplaceAll([]Change{{Client: client, Dest: dest, Expiry: now.Add(48 * time.Hour)}}, now); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "timeout 3600s") {
		t.Fatalf("TTL was not capped to one hour: %s", got)
	}
}

func TestOpenWrtNFTPairSetIncrementalAndClientScoped(t *testing.T) {
	now := time.Unix(2_000, 0)
	var tx []string
	set := testNFTSet("pairs_incremental", func() error { return nil }, func(script string) error { tx = append(tx, script); return nil })
	a := Change{Client: netip.MustParseAddr("192.168.1.20"), Dest: netip.MustParseAddr("104.21.45.34"), Expiry: now.Add(time.Minute)}
	b := Change{Client: netip.MustParseAddr("192.168.1.21"), Dest: a.Dest, Expiry: now.Add(2 * time.Minute)}
	if err := set.ReplaceAll([]Change{a}, now); err != nil {
		t.Fatal(err)
	}
	if err := set.Apply([]Change{b}, now); err != nil {
		t.Fatal(err)
	}
	if err := set.Apply([]Change{b}, now); err != nil {
		t.Fatal(err)
	}
	if len(tx) != 2 || strings.Contains(tx[1], "192.168.1.20 . 104.21.45.34") ||
		!strings.Contains(tx[1], "destroy element inet zapret2 pairs_incremental { 192.168.1.21 . 104.21.45.34 }") ||
		!strings.Contains(tx[1], "add element inet zapret2 pairs_incremental { 192.168.1.21 . 104.21.45.34 timeout 120s }") {
		t.Fatalf("incremental update rewrote or lost an unrelated client pair: %#v", tx)
	}
	if err := set.Apply([]Change{{Client: a.Client, Dest: a.Dest, Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(tx[2], "destroy element inet zapret2 pairs_incremental { 192.168.1.20 . 104.21.45.34 }") ||
		strings.Contains(tx[2], "192.168.1.21 . 104.21.45.34") {
		t.Fatalf("delete removed the wrong client-scoped pair: %s", tx[2])
	}
}

func TestOpenWrtNFTPairSetRejectsInvalidPairAndForeignOwner(t *testing.T) {
	mutated := false
	foreign := errors.New("foreign set owner")
	set := testNFTSet("pairs_foreign", func() error { return foreign }, func(string) error { mutated = true; return nil })
	now := time.Unix(3_000, 0)
	err := set.ReplaceAll(nil, now)
	if !errors.Is(err, foreign) || mutated {
		t.Fatalf("foreign set was mutated: err=%v mutated=%v", err, mutated)
	}
	set = testNFTSet("pairs_invalid", func() error { return nil }, func(string) error { mutated = true; return nil })
	err = set.Apply([]Change{{Client: netip.MustParseAddr("192.168.1.20"), Dest: netip.MustParseAddr("10.0.0.1"), Expiry: now.Add(time.Minute)}}, now)
	if err == nil || !strings.Contains(err.Error(), "invalid WARP DNS pair") || mutated {
		t.Fatalf("private destination was not rejected before nft mutation: err=%v mutated=%v", err, mutated)
	}
}

func TestOpenWrtNFTPairSetEmptyLazyBackendAndActivation(t *testing.T) {
	checked, mutations := false, 0
	set := testNFTSet("pairs_lazy", func() error { checked = true; return nil }, func(string) error { mutations++; return nil })
	set.lazy = true
	now := time.Unix(4_000, 0)
	if err := set.ReplaceAll(nil, now); err != nil {
		t.Fatal(err)
	}
	if err := set.Apply([]Change{{Client: netip.MustParseAddr("192.168.1.20"), Dest: netip.MustParseAddr("104.21.45.34"), Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	if checked || mutations != 0 {
		t.Fatalf("lazy empty configuration touched an absent set: checked=%v mutations=%d", checked, mutations)
	}
	if err := set.Apply([]Change{{Client: netip.MustParseAddr("192.168.1.20"), Dest: netip.MustParseAddr("104.21.45.34"), Expiry: now.Add(time.Minute)}}, now); err != nil {
		t.Fatal(err)
	}
	if !checked || mutations != 1 {
		t.Fatalf("first observed selected DNS pair did not activate nft backend: checked=%v mutations=%d", checked, mutations)
	}
}

func TestOpenWrtNFTPairSetEnvironmentFailsClosedAndDispatches(t *testing.T) {
	t.Setenv("Z2K_WARP_OPENWRT", "1")
	t.Setenv("Z2K_WARP_DOMAIN_DISABLED", "")
	for _, key := range []string{"Z2K_WARP_DOMAIN_NFT", "Z2K_WARP_DOMAIN_NFT_FAMILY", "Z2K_WARP_DOMAIN_NFT_TABLE", "Z2K_WARP_DOMAIN_NFT_SET", "Z2K_WARP_DOMAIN_NFT_LAZY"} {
		t.Setenv(key, "")
	}
	if err := (PairSet{Binary: "missing-ipset-for-fail-closed-test"}).Apply(nil, time.Now()); err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Fatalf("missing OpenWrt backend silently fell back to ipset: %v", err)
	}
	t.Setenv("Z2K_WARP_DOMAIN_DISABLED", "1")
	if err := (PairSet{Binary: "missing-ipset-for-disabled-test"}).Apply(nil, time.Now()); err != nil {
		t.Fatalf("intentional disabled state fell back to ipset: %v", err)
	}
	t.Setenv("Z2K_WARP_DOMAIN_DISABLED", "")
	t.Setenv("Z2K_WARP_DOMAIN_NFT", filepath.Join(t.TempDir(), "nft-stub"))
	t.Setenv("Z2K_WARP_DOMAIN_NFT_FAMILY", "inet")
	t.Setenv("Z2K_WARP_DOMAIN_NFT_TABLE", "zapret2")
	t.Setenv("Z2K_WARP_DOMAIN_NFT_SET", "z2k_warp_domain4")
	log := filepath.Join(t.TempDir(), "nft-input.log")
	stub := "#!/bin/sh\nif [ \"$1\" = list ]; then printf 'set z2k_warp_domain4 comment \"z2k WARP DNS pairs\"\\n'; exit 0; fi\ncat >> \"$NFT_CAPTURE\"\n"
	if err := os.WriteFile(os.Getenv("Z2K_WARP_DOMAIN_NFT"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NFT_CAPTURE", log)
	now := time.Unix(5_000, 0)
	change := Change{Client: netip.MustParseAddr("192.168.1.24"), Dest: netip.MustParseAddr("104.21.45.34"), Expiry: now.Add(75 * time.Second)}
	if err := (PairSet{}).ReplaceAll([]Change{change}, now); err != nil {
		t.Fatalf("PairSet did not dispatch through the OpenWrt nft overlay: %v", err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "flush set inet zapret2 z2k_warp_domain4") || !strings.Contains(string(data), "192.168.1.24 . 104.21.45.34 timeout 75s") {
		t.Fatalf("nft dispatch did not produce client-scoped timed pair: %s", data)
	}
}
