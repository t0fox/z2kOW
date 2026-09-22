//go:build !windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUDPRouteUsesPlatformHelperOverride(t *testing.T) {
	dir := t.TempDir()
	helper := filepath.Join(dir, "route-helper")
	logPath := filepath.Join(dir, "route.log")
	body := "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$ROUTE_LOG\"\n"
	if err := os.WriteFile(helper, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("Z2K_TG_UDP_ROUTE_HELPER", helper)
	t.Setenv("ROUTE_LOG", logPath)

	if err := udpRoute(context.Background(), "ensure"); err != nil {
		t.Fatalf("udpRoute with OpenWrt helper: %v", err)
	}
	got, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(got)) != "ensure" {
		t.Fatalf("route helper argv = %q, want ensure", got)
	}
}
