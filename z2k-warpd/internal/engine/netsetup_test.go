package engine

import (
	"context"
	"strings"
	"testing"
)

// TestSkipNetSetupCallsNoIptables — OpenWrt/external backend:
// TUN/create/address/transport/health/status работают как раньше,
// iptables НЕ вызывается вовсе (ни Ensure, ни Remove).
//
// Keenetic-дефолт (без флага) покрыт TestFirstFailsSecondWorksAndRemembersLastGood,
// который ассёртит iptables -A/-D — поведение оттуда меняться не должно.
//
// NOTE: выполняется в CI; здесь — рядом с harness, зеркально существующему тесту.
func TestSkipNetSetupCallsNoIptables(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:854": true})
	cfg := h.config()
	cfg.SkipNetSetup = true
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()
	waitFor(t, "ready", func() bool { s := readStatus(h); return s != nil && s.Ready })
	cancel()
	<-done
	joined := strings.Join(h.cmds, "\n")
	if strings.Contains(joined, "iptables") {
		t.Fatalf("external backend must not call iptables, got:\n%s", joined)
	}
	if !strings.Contains(joined, "ip addr add 172.16.0.2/32 dev z2ktun0") {
		t.Fatalf("TUN setup must still run with SkipNetSetup, got:\n%s", joined)
	}
}
