//go:build linux

package prober

import (
	"net"
	"testing"
)

func init() {
	// Integration tests verify the probe/TLS behavior, not CAP_NET_ADMIN. The
	// production dialer remains checked separately and is unchanged.
	newProbeDialer = func(int) *net.Dialer { return &net.Dialer{} }
}

func TestMarkedDialerInstallsSocketControl(t *testing.T) {
	if markedDialer(0).Control == nil {
		t.Fatal("Linux probe dialer must configure SO_MARK socket control")
	}
}
