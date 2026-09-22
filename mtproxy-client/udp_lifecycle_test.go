package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// A dead WSS must stop owning router routes even though the daemon stays alive.
func TestUDPDisconnectWithdrawsRoutes(t *testing.T) {
	for _, setupFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "disconnect", true: "partial_setup"}[setupFails], func(t *testing.T) {
			peer := make(chan *websocket.Conn, 1)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, e := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if e == nil {
					peer <- ws
				}
			}))
			defer srv.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			tc := &tunnelClient{ctx: ctx}
			tun, writer, e := os.Pipe()
			if e != nil {
				t.Fatal(e)
			}
			defer tun.Close()
			defer writer.Close()
			ready := filepath.Join(t.TempDir(), "ready")
			cleaned := make(chan struct{}, 1)
			installed := false
			route := func(_ context.Context, action string) error {
				switch action {
				case "ensure":
					if _, e := os.Stat(ready); e != nil {
						t.Error("routes activated without readiness")
					}
					installed = true
					ws := <-peer
					ws.Close()
					if setupFails {
						return errors.New("partial route setup")
					}
				case "down":
					if _, e := os.Stat(ready); !os.IsNotExist(e) {
						t.Error("watchdog can restore routes during cleanup")
					}
					if installed {
						installed = false
						cleaned <- struct{}{}
						cancel()
					}
				}
				return nil
			}
			dial := func() (*websocket.Conn, error) {
				ws, _, e := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
				return ws, e
			}
			done := make(chan struct{})
			go func() { defer close(done); tc.runUDPTransport(tun, ready, route, dial) }()
			select {
			case <-cleaned:
			case <-time.After(2 * time.Second):
				cancel()
				t.Error("disconnected UDP still owns routes")
			}
			cancel()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("UDP worker did not stop")
			}
		})
	}
}
