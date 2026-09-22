package main

import (
	"bytes"
	"flag"
	"strings"
	"testing"
)

func TestBuildInjectedTunnelSecretIsNotPrintedInHelp(t *testing.T) {
	if defaultTunnelSecret == "" {
		t.Skip("requires the CI build-secret sentinel")
	}
	var out bytes.Buffer
	old := flag.CommandLine.Output()
	flag.CommandLine.SetOutput(&out)
	flag.CommandLine.PrintDefaults()
	flag.CommandLine.SetOutput(old)
	if strings.Contains(out.String(), defaultTunnelSecret) {
		t.Fatal("command-line help exposes the build-injected tunnel secret")
	}
}

func TestResolvedTunnelSecretPrefersExplicitOverride(t *testing.T) {
	if got := resolvedTunnelSecret("user-value", "build-value"); got != "user-value" {
		t.Fatalf("explicit override lost: got %q", got)
	}
}

func TestResolvedTunnelSecretFallsBackToBuildValue(t *testing.T) {
	if got := resolvedTunnelSecret("", "build-value"); got != "build-value" {
		t.Fatalf("build-time fallback lost: got %q", got)
	}
}
