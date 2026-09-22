package main

// UDP-v1 runs on its own authenticated WSS connection. No stream credit or
// TCP fallback: each 0x20 frame is one opaque datagram, including its endpoint.
import (
	"encoding/binary"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const udpData = 0x20
const udpMaxPayload = 1472
const udpMaxFlows = 64
const udpIdle = 90 * time.Second

var udpInstalls = struct {
	sync.Mutex
	sessions map[string]*session
}{sessions: make(map[string]*session)}

func acquireUDPInstall(s *session) bool {
	udpInstalls.Lock()
	defer udpInstalls.Unlock()
	if old := udpInstalls.sessions[s.relayID]; old != nil || len(udpInstalls.sessions) >= 2048 {
		return false
	}
	udpInstalls.sessions[s.relayID] = s
	return true
}
func releaseUDPInstall(s *session) {
	udpInstalls.Lock()
	defer udpInstalls.Unlock()
	if udpInstalls.sessions[s.relayID] == s {
		delete(udpInstalls.sessions, s.relayID)
	}
}

// Intentionally excludes --extra-cidrs, mapped IPv6, network/broadcast v4,
// and every local or multicast address. Numeric IP only; no DNS rebinding.
func allowedUDP(a netip.Addr) bool {
	if !a.IsGlobalUnicast() || a.IsPrivate() || a.Is4In6() {
		return false
	}
	if a.Is4() {
		v := a.As4()
		n := binary.BigEndian.Uint32(v[:])
		for _, r := range telegramV4 {
			if n&r.mask == r.net && n != r.net && n != r.net|^r.mask {
				return true
			}
		}
		return false
	}
	for _, p := range udpV6 {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

var udpV6 = []netip.Prefix{
	netip.MustParsePrefix("2001:67c:4e8::/48"), netip.MustParsePrefix("2001:b28:f23c::/47"),
	netip.MustParsePrefix("2001:b28:f23f::/48"), netip.MustParsePrefix("2a0a:f280::/32"),
}

func decodeUDP(p []byte) (netip.AddrPort, []byte, bool) {
	if len(p) < 1 {
		return netip.AddrPort{}, nil, false
	}
	n := 0
	switch p[0] {
	case 1:
		n = 4
	case 4:
		n = 16
	default:
		return netip.AddrPort{}, nil, false
	}
	if len(p) < n+3 || len(p) > n+3+udpMaxPayload || (n == 16 && len(p) > 19+1452) {
		return netip.AddrPort{}, nil, false
	}
	a, ok := netip.AddrFromSlice(p[1 : 1+n])
	port := binary.BigEndian.Uint16(p[1+n : 3+n])
	if !ok || port == 0 {
		return netip.AddrPort{}, nil, false
	}
	return netip.AddrPortFrom(a, port), p[n+3:], true
}

var udpLiveFlows atomic.Int64

type udpFlow struct {
	closed atomic.Bool
	conn   net.Conn
	dst    netip.AddrPort
	header []byte
	last   time.Time
}

// The reader owns the flow table. Connected UDP sockets accept replies only
// from the original endpoint; returning a claimed endpoint never opens a socket.
var udpDial = func(a netip.AddrPort) (net.Conn, error) { return net.DialUDP("udp", nil, net.UDPAddrFromAddrPort(a)) }

type udpRate struct {
	at             time.Time
	packets, bytes float64
}

func (r *udpRate) allow(now time.Time, n int) bool {
	if r.at.IsZero() {
		r.at = now
		r.packets = 200
		r.bytes = 256 * 1024
	}
	elapsed := now.Sub(r.at).Seconds()
	r.at = now
	r.packets = min(200, r.packets+elapsed*500)
	r.bytes = min(256*1024, r.bytes+elapsed*512*1024)
	if r.packets < 1 || r.bytes < float64(n) {
		return false
	}
	r.packets--
	r.bytes -= float64(n)
	return true
}
func (s *session) readUDPLoop() {
	s.ws.SetReadLimit(3 + 19 + udpMaxPayload)
	flows := map[uint16]*udpFlow{}
	var readers sync.WaitGroup
	var replyMu sync.Mutex
	var replyRate udpRate
	defer func() {
		for _, f := range flows {
			f.conn.Close()
		}
		readers.Wait()
	}()
	// Socket read deadlines bound idle lifetime even without new client packets.
	var inbound udpRate
	for {
		kind, msg, err := s.ws.ReadMessage()
		if err != nil {
			return
		}
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		id, mt, p, err := decodeFrame(msg)
		dst, data, ok := decodeUDP(p)
		if err != nil || kind != websocket.BinaryMessage || id == 0 || mt != udpData || !ok || !allowedUDP(dst.Addr()) {
			s.killWith("udp_protocol")
			return
		}
		now := time.Now()
		for k, f := range flows {
			if now.Sub(f.last) > udpIdle {
				f.conn.Close()
				delete(flows, k)
			}
		}
		if !inbound.allow(now, len(data)) {
			metrics.inc("relay_udp_drop_total", `reason="rate"`)
			continue
		}
		f := flows[id]
		if f != nil && f.closed.Load() {
			delete(flows, id)
			f = nil
		}
		if f != nil && f.dst != dst {
			s.killWith("udp_retarget")
			return
		}
		if f == nil {
			if len(flows) >= udpMaxFlows {
				metrics.inc("relay_udp_drop_total", `reason="flows"`)
				continue
			}
			if udpLiveFlows.Add(1) > 4096 {
				udpLiveFlows.Add(-1)
				continue
			}
			c, e := udpDial(dst)
			if e != nil {
				udpLiveFlows.Add(-1)
				continue
			}
			f = &udpFlow{conn: c, dst: dst, header: append([]byte(nil), p[:len(p)-len(data)]...), last: now}
			flows[id] = f
			_ = c.SetReadDeadline(now.Add(udpIdle))
			readers.Add(1)
			go func(id uint16, f *udpFlow) { defer readers.Done(); s.udpReplies(id, f, &replyMu, &replyRate) }(id, f)
		}
		f.last = now
		_ = f.conn.SetReadDeadline(now.Add(udpIdle))
		_ = f.conn.SetWriteDeadline(now.Add(200 * time.Millisecond))
		if _, e := f.conn.Write(data); e != nil {
			f.conn.Close()
			delete(flows, id)
			continue
		}
		s.rxBytes.Add(int64(len(data)))
		metrics.inc("relay_udp_datagrams_total", `direction="up"`)
	}
}
func (s *session) udpReplies(id uint16, f *udpFlow, rateMu *sync.Mutex, rate *udpRate) {
	defer udpLiveFlows.Add(-1)
	defer f.closed.Store(true)
	defer f.conn.Close()
	b := make([]byte, udpMaxPayload+1)
	for {
		n, err := f.conn.Read(b)
		if err != nil {
			return
		}
		rateMu.Lock()
		allowed := rate.allow(time.Now(), n)
		rateMu.Unlock()
		if n > udpMaxPayload || (f.dst.Addr().Is6() && n > 1452) || !allowed {
			continue
		}
		payload := make([]byte, len(f.header)+n)
		copy(payload, f.header)
		copy(payload[len(f.header):], b[:n])
		frame := encodeFrame(id, udpData, payload)
		select {
		case s.writer.datagrams <- udpQueued{frame, time.Now()}:
			s.txBytes.Add(int64(n))
			metrics.inc("relay_udp_datagrams_total", `direction="down"`)
		case <-s.done:
			return
		default:
			metrics.inc("relay_udp_drop_total", `reason="queue"`)
		}
	}
}
