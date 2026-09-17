package h2

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

const peerPEM = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG\n7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w==\n-----END PUBLIC KEY-----\n"

func TestPinnedKeyParsesPEM(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: peerPEM}}}
	if tr.pinnedKey() == nil {
		t.Fatal("PEM peer key not parsed")
	}
}

func TestPinnedKeyParsesBase64DER(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w=="}}}
	if tr.pinnedKey() == nil {
		t.Fatal("DER peer key not parsed")
	}
}

func TestPinnedKeyGarbage(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: "nope"}}}
	if tr.pinnedKey() != nil {
		t.Fatal("garbage must not pin")
	}
}

func testECKey(t *testing.T) (*ecdsa.PrivateKey, string, string) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	priv, err := x509.MarshalECPrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return k, base64.StdEncoding.EncodeToString(priv), base64.StdEncoding.EncodeToString(pub)
}

func TestTLSConfigRejectsMissingOrInvalidPin(t *testing.T) {
	_, priv, _ := testECKey(t)
	for _, pin := range []string{"", "not-base64", base64.StdEncoding.EncodeToString([]byte("not a public key"))} {
		t.Run(pin, func(t *testing.T) {
			tr := &Transport{d: &account.Device{H2: &account.H2Key{PrivateKey: priv, PeerKey: pin}}, logf: t.Logf}
			if cfg, err := tr.tlsConfig(); err == nil || cfg != nil {
				t.Fatal("missing or invalid peer key must fail before dialing")
			}
		})
	}
}

// Exercise the TLS stack, not only the callback: self-signed/wrong-name
// certificates are valid for this protocol only when their key is pinned.
func TestTLSHandshakeRequiresRegisteredPeer(t *testing.T) {
	serverKey, _, serverPin := testECKey(t)
	_, clientPriv, otherPin := testECKey(t)
	pubDER, _ := base64.StdEncoding.DecodeString(serverPin)
	serverPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}))
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"different.invalid"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	cert, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &serverKey.PublicKey, serverKey)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, pin string
		wantOK    bool
	}{{"registered DER", serverPin, true}, {"registered PEM", serverPEM, true}, {"impostor", otherPin, false}} {
		t.Run(tc.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			done := make(chan error, 1)
			go func() {
				raw, err := listener.Accept()
				if err != nil {
					done <- err
					return
				}
				defer raw.Close()
				_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
				s := tls.Server(raw, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{cert}, PrivateKey: serverKey}}, NextProtos: []string{"h2"}})
				done <- s.Handshake()
			}()
			tr := &Transport{d: &account.Device{H2: &account.H2Key{PrivateKey: clientPriv, PeerKey: tc.pin}}, logf: t.Logf}
			cfg, err := tr.tlsConfig()
			if err != nil {
				t.Fatal(err)
			}
			conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp", listener.Addr().String(), cfg)
			if conn != nil {
				conn.Close()
			}
			if (err == nil) != tc.wantOK {
				t.Fatalf("handshake error = %v, want success %v", err, tc.wantOK)
			}
			if serverErr := <-done; tc.wantOK && serverErr != nil {
				t.Fatalf("server handshake: %v", serverErr)
			}
		})
	}
}
