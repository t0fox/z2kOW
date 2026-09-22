package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var telegramUDP = flag.Bool("telegram-udp", false, "Telegram server UDP through a separate authenticated WSS/TUN (Linux)")
const udpReadyPath = "/tmp/z2k-log/tg-udp.ready"

type udpClientFlow struct {
	tuple udpTuple
	last  time.Time
}
type udpClientSession struct {
	mu    sync.Mutex
	flows map[uint16]udpClientFlow
	ids   map[udpTuple]uint16
	next  uint16
	queue chan udpClientQueued
}
type udpClientQueued struct {
	b  []byte
	at time.Time
}

func newUDPClientSession() *udpClientSession {
	return &udpClientSession{flows: make(map[uint16]udpClientFlow), ids: make(map[udpTuple]uint16), queue: make(chan udpClientQueued, 64)}
}
func (s *udpClientSession) packet(t udpTuple, b []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for id, f := range s.flows {
		if now.Sub(f.last) > 90*time.Second {
			delete(s.flows, id)
			delete(s.ids, f.tuple)
		}
	}
	id := s.ids[t]
	if id == 0 {
		if len(s.flows) >= 64 {
			return
		}
		for {
			s.next++
			if s.next != 0 {
				if _, ok := s.flows[s.next]; !ok {
					break
				}
			}
		}
		id = s.next
		s.ids[t] = id
	}
	s.flows[id] = udpClientFlow{t, now}
	p := append(udpEndpoint(t.dst), b...)
	select {
	case s.queue <- udpClientQueued{encodeMuxFrame(id, udpData, p), now}:
	default:
	}
}
func (s *udpClientSession) reply(msg []byte) ([]byte, error) {
	f, e := decodeMuxFrame(msg)
	if e != nil {
		return nil, e
	}
	if f.StreamID == 0 && f.MsgType == muxINFO {
		return nil, nil
	}
	dst, data, ok := readUDPEndpoint(f.Payload)
	if f.MsgType != udpData || !ok {
		return nil, fmt.Errorf("bad UDP reply")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	flow, exists := s.flows[f.StreamID]
	if !exists {
		return nil, nil
	}
	if dst != flow.tuple.dst {
		return nil, fmt.Errorf("UDP reply endpoint changed")
	}
	flow.last = time.Now()
	s.flows[f.StreamID] = flow
	return makeUDPPacket(udpTuple{flow.tuple.dst, flow.tuple.src}, data), nil
}
func (tc *tunnelClient) dialUDP() (*websocket.Conn, error) {
	id := tc.identity.Load()
	if id == nil || !tc.useID.Load() {
		return nil, errNotRegistered
	}
	u, e := url.Parse(tc.tunnelURL)
	if e != nil {
		return nil, e
	}
	q := u.Query()
	q.Set("transport", "udp-v1")
	u.RawQuery = q.Encode()
	d := websocket.Dialer{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, HandshakeTimeout: 10 * time.Second, Subprotocols: []string{"z2k-udp-v1"}, NetDial: func(network, addr string) (net.Conn, error) {
		return net.DialTimeout("tcp4", relayDialAddr(addr), 10*time.Second)
	}}
	ws, _, e := d.DialContext(tc.ctx, u.String(), nil)
	if e != nil {
		return nil, e
	}
	if ws.Subprotocol() != "z2k-udp-v1" {
		ws.Close()
		return nil, fmt.Errorf("relay does not support UDP-v1")
	}
	configureWSKeepalive(ws)
	// Separate handshake state; never change the TCP connection's window/version.
	h := &tunnelClient{}
	if e = h.handshakeV2(ws, id); e != nil {
		ws.Close()
		return nil, e
	}
	ws.SetReadLimit(3 + 19 + udpMaxPayload)
	return ws, nil
}
func udpRoute(ctx context.Context, action string) error {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if helper := os.Getenv("Z2K_TG_UDP_ROUTE_HELPER"); helper != "" {
		return exec.CommandContext(cctx, helper, action).Run()
	}
	// Keep the original Keenetic helper ABI when no platform override exists.
	return exec.CommandContext(cctx, "/opt/bin/sh", "-c", `. /opt/zapret2/z2k-tg-redirect.sh; "z2k_tg_udp_$1"`, "sh", action).Run()
}
func (tc *tunnelClient) runUDP() {
	_ = os.Remove(udpReadyPath)
	tun, e := openUDPTun("z2ktg0")
	if e != nil {
		log.Printf("[udp] disabled: %v", e)
		return
	}
	defer tun.Close()
	tc.runUDPTransport(tun, udpReadyPath, udpRoute, tc.dialUDP)
}

// The transport owns readiness and routing; privileged operations stay at its boundary.
func (tc *tunnelClient) runUDPTransport(tun *os.File, readyPath string, route func(context.Context, string) error, dial func() (*websocket.Conn, error)) {
	withdraw := func() {
		// Revoke capability first: watchdog must not reinstall a dead route.
		_ = os.Remove(readyPath)
		if err := route(context.Background(), "down"); err != nil {
			log.Printf("[udp] route cleanup: %v", err)
		}
	}
	defer withdraw()
	var mu sync.Mutex
	var active *udpClientSession
	go func() { <-tc.ctx.Done(); tun.Close() }()
	go func() {
		b := make([]byte, 65536)
		for {
			n, err := tun.Read(b)
			if err != nil {
				return
			}
			t, data, ok := parseUDPPacket(b[:n])
			if !ok {
				continue
			}
			mu.Lock()
			s := active
			mu.Unlock()
			if s != nil {
				s.packet(t, data)
			}
		}
	}()
	failures := 0
	for tc.ctx.Err() == nil {
		started := time.Now()
		ws, err := dial()
		if err == nil {
			s := newUDPClientSession()
			mu.Lock()
			active = s
			mu.Unlock()
			if err = os.WriteFile(readyPath, []byte("udp-v1\n"), 0600); err == nil {
				err = route(tc.ctx, "ensure")
			}
			if err != nil {
				log.Printf("[udp] route setup: %v", err)
				ws.Close()
			} else {
				log.Printf("[udp] connected; Telegram UDP via separate WSS")
				tc.serveUDP(ws, tun, s)
			}
			mu.Lock()
			active = nil
			mu.Unlock()
			ws.Close()
			withdraw()
		} else if err != errNotRegistered {
			log.Printf("[udp] connect: %v", err)
		}
		if err == errNotRegistered || time.Since(started) >= time.Minute {
			failures = 0
		} else {
			failures++
		}
		select {
		case <-tc.ctx.Done():
			return
		case <-time.After(jitter(backoffFor(failures))):
		}
	}
}
func (tc *tunnelClient) serveUDP(ws *websocket.Conn, tun *os.File, s *udpClientSession) {
	ctx, cancel := context.WithCancel(tc.ctx)
	defer cancel()
	defer ws.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer ws.Close()
		ping := time.NewTicker(wsPingInterval)
		defer ping.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ping.C:
				if ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(time.Second)) != nil {
					return
				}
			case d := <-s.queue:
				if time.Since(d.at) > 200*time.Millisecond {
					continue
				}
				ws.SetWriteDeadline(time.Now().Add(time.Second))
				if ws.WriteMessage(websocket.BinaryMessage, d.b) != nil {
					return
				}
			}
		}
	}()
	defer func() { cancel(); ws.Close(); <-done }()
	for {
		kind, b, e := ws.ReadMessage()
		if e != nil {
			return
		}
		ws.SetReadDeadline(time.Now().Add(wsReadTimeout))
		if kind != websocket.BinaryMessage {
			return
		}
		p, e := s.reply(b)
		if e != nil {
			return
		}
		if p != nil {
			if _, e = tun.Write(p); e != nil {
				return
			}
		}
	}
}
