package wg

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/device"
)

// Буфер под пакет обязан быть маленьким: 64 КБ на пакет при MTU 1280 давали
// 70–90 МБ RSS после одного скачанного файла и OOM-kill на роутере с 512 МБ.
// Константа живёт в копии third_party/wireguard; уйдёт replace из go.mod —
// упадёт этот тест, а не роутер.
func TestSegmentBufferIsSmall(t *testing.T) {
	if device.MaxSegmentSize != 2048 {
		t.Fatalf("device.MaxSegmentSize = %d, want 2048; see third_party/wireguard/Z2K-PATCHES.md", device.MaxSegmentSize)
	}
}

// Keep the local WireGuard copy tied to its documented upstream revision and
// memory patch. This is a CI source guard: local package builds are not needed.
func TestVendoredWireGuardMemoryPatchContract(t *testing.T) {
	_, testFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller could not locate this test")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(testFile), "..", "..", ".."))
	read := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		return string(data)
	}

	const module = "golang.zx2c4.com/wireguard"
	const revision = "v0.0.0-20260522210424-ecfc5a8d5446"
	goMod := read("go.mod")
	if !strings.Contains(goMod, module+" "+revision) {
		t.Fatalf("go.mod no longer pins %s at %s", module, revision)
	}
	if !strings.Contains(goMod, "replace "+module+" => ./third_party/wireguard") {
		t.Fatalf("go.mod no longer replaces %s with the audited local copy", module)
	}

	patchNotes := read("third_party/wireguard/Z2K-PATCHES.md")
	if !strings.Contains(patchNotes, "Источник: "+module+"@"+revision) {
		t.Fatalf("vendor patch notes do not identify pinned source %s@%s", module, revision)
	}
	if !strings.Contains(patchNotes, "MaxSegmentSize = 2048") ||
		!strings.Contains(patchNotes, "false, false") ||
		!strings.Contains(patchNotes, "для v4 и v6") {
		t.Fatal("vendor patch notes no longer describe both required memory patches")
	}

	queue := read("third_party/wireguard/device/queueconstants_default.go")
	if !regexp.MustCompile(`MaxSegmentSize\s*=\s*2048\b`).MatchString(queue) {
		t.Fatal("vendored MaxSegmentSize is no longer 2048")
	}

	bind := read("third_party/wireguard/conn/bind_std.go")
	for _, assignment := range []string{
		"s.ipv4TxOffload, s.ipv4RxOffload = false, false",
		"s.ipv6TxOffload, s.ipv6RxOffload = false, false",
	} {
		if !strings.Contains(bind, assignment) {
			t.Errorf("UDP GSO/GRO guard missing assignment %q", assignment)
		}
	}
}
