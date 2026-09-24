//go:build linux

package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/necronicle/z2k/z2k-warpd/internal/domainroute"
)

func TestWarpDomainObserverUsesPlatformRuntimePaths(t *testing.T) {
	dir := t.TempDir()
	domainPath := filepath.Join(dir, "domains.v1")
	snapshotPath := filepath.Join(dir, "domain-pairs.v1")
	statusPath := filepath.Join(dir, "domain-status.json")
	if err := os.WriteFile(domainPath, []byte("v1\nselected.example\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ipsetStub := filepath.Join(dir, "ipset-stub")
	if err := os.WriteFile(ipsetStub, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("Z2K_WARP_DOMAIN_RULES", domainPath)
	t.Setenv("Z2K_WARP_DOMAIN_SNAPSHOT", snapshotPath)
	t.Setenv("Z2K_WARP_DOMAIN_STATUS", statusPath)
	t.Setenv("Z2K_WARP_OPENWRT", "1")
	t.Setenv("Z2K_WARP_DOMAIN_DISABLED", "1")

	options := warpDomainObserverOptions()
	if options.DomainPath != domainPath || options.SnapshotPath != snapshotPath || options.StatusPath != statusPath {
		t.Fatalf("observer paths ignored platform environment: got (%q, %q, %q), want (%q, %q, %q)",
			options.DomainPath, options.SnapshotPath, options.StatusPath,
			domainPath, snapshotPath, statusPath)
	}

	// Run the real observer against the same environment that procd supplies.
	// The canceled context makes the packet listener short-lived; Rules=1 proves
	// the observer read this runtime's file rather than its Keenetic default.
	options.PairSet = domainroute.PairSet{Binary: ipsetStub, IPTablesBinary: ipsetStub}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := domainroute.NewObserver(domainroute.Rules{}).Run(ctx, options)
	t.Logf("short-lived NFLOG listener result: %v", err)
	data, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("observer did not publish status at the OpenWrt runtime path: %v", err)
	}
	var status domainroute.Status
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("invalid observer status: %v", err)
	}
	if status.Rules != 1 {
		t.Fatalf("observer loaded %d rules from OpenWrt runtime path, want 1 (status: %s)", status.Rules, data)
	}
}

func TestWarpDomainObserverKeepsKeeneticDefaults(t *testing.T) {
	for _, key := range []string{"Z2K_WARP_DOMAIN_RULES", "Z2K_WARP_DOMAIN_SNAPSHOT", "Z2K_WARP_DOMAIN_STATUS"} {
		t.Setenv(key, "")
	}
	options := warpDomainObserverOptions()
	if options.DomainPath != "/tmp/z2k-warp/domains.v1" ||
		options.SnapshotPath != "/tmp/z2k-warp/domain-pairs.v1" ||
		options.StatusPath != "/tmp/z2k-warp/domain-status.json" {
		t.Fatalf("Keenetic defaults changed: got (%q, %q, %q)", options.DomainPath, options.SnapshotPath, options.StatusPath)
	}
}
