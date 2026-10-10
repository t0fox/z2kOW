package quicprobe

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadBlobUsesZ2KFakeDir(t *testing.T) {
	dir := t.TempDir()
	want := bytes.Repeat([]byte{0x5a}, 80)
	if err := os.WriteFile(filepath.Join(dir, "quic_5.bin"), want, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("Z2K_FAKE_DIR", dir)

	if got := loadBlob("quic_5.bin"); !bytes.Equal(got, want) {
		t.Fatalf("блоб не прочитан из Z2K_FAKE_DIR: получено %d байт, ожидалось %d", len(got), len(want))
	}
}
