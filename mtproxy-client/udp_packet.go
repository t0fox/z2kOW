package main

import (
	"encoding/binary"
	"net/netip"
)

const udpData = 0x20
const udpMaxPayload = 1472

type udpTuple struct{ src, dst netip.AddrPort }

func internetSum(b []byte) uint32 {
	var s uint32
	for len(b) >= 2 {
		s += uint32(binary.BigEndian.Uint16(b))
		b = b[2:]
	}
	if len(b) > 0 {
		s += uint32(b[0]) << 8
	}
	return s
}
func foldSum(s uint32) uint16 {
	for s>>16 != 0 {
		s = (s & 65535) + (s >> 16)
	}
	return ^uint16(s)
}
func udpChecksum(src, dst netip.Addr, u []byte) uint16 {
	s := internetSum(src.AsSlice()) + internetSum(dst.AsSlice()) + uint32(len(u)) + 17
	return foldSum(s + internetSum(u))
}

// No fragments or extension headers: selected voice datagrams must fit the
// 1500-byte TUN MTU. Reject inconsistent lengths and corrupt packets.
func parseUDPPacket(b []byte) (udpTuple, []byte, bool) {
	var src, dst netip.Addr
	off := 0
	if len(b) < 20 {
		return udpTuple{}, nil, false
	}
	switch b[0] >> 4 {
	case 4:
		off = int(b[0]&15) * 4
		if off < 20 || len(b) < off+8 || int(binary.BigEndian.Uint16(b[2:4])) != len(b) || b[9] != 17 || binary.BigEndian.Uint16(b[6:8])&0x3fff != 0 || foldSum(internetSum(b[:off])) != 0 {
			return udpTuple{}, nil, false
		}
		src, _ = netip.AddrFromSlice(b[12:16])
		dst, _ = netip.AddrFromSlice(b[16:20])
	case 6:
		off = 40
		if len(b) < 48 || len(b) > 1500 || b[6] != 17 || int(binary.BigEndian.Uint16(b[4:6]))+40 != len(b) {
			return udpTuple{}, nil, false
		}
		src, _ = netip.AddrFromSlice(b[8:24])
		dst, _ = netip.AddrFromSlice(b[24:40])
	default:
		return udpTuple{}, nil, false
	}
	u := b[off:]
	if len(u) > udpMaxPayload+8 || int(binary.BigEndian.Uint16(u[4:6])) != len(u) {
		return udpTuple{}, nil, false
	}
	if binary.BigEndian.Uint16(u[6:8]) != 0 {
		if udpChecksum(src, dst, u) != 0 {
			return udpTuple{}, nil, false
		}
	} else if src.Is6() {
		return udpTuple{}, nil, false
	}
	sp, dp := binary.BigEndian.Uint16(u), binary.BigEndian.Uint16(u[2:])
	if sp == 0 || dp == 0 || !src.IsGlobalUnicast() || src.Is4In6() || dst.Is4In6() {
		return udpTuple{}, nil, false
	}
	return udpTuple{netip.AddrPortFrom(src, sp), netip.AddrPortFrom(dst, dp)}, u[8:], true
}
func makeUDPPacket(t udpTuple, data []byte) []byte {
	off := 20
	if t.src.Addr().Is6() {
		off = 40
	}
	b := make([]byte, off+8+len(data))
	u := b[off:]
	binary.BigEndian.PutUint16(u, t.src.Port())
	binary.BigEndian.PutUint16(u[2:], t.dst.Port())
	binary.BigEndian.PutUint16(u[4:], uint16(len(u)))
	copy(u[8:], data)
	sum := udpChecksum(t.src.Addr(), t.dst.Addr(), u)
	if sum == 0 {
		sum = 65535
	}
	binary.BigEndian.PutUint16(u[6:], sum)
	if off == 20 {
		b[0] = 0x45
		b[8] = 64
		b[9] = 17
		binary.BigEndian.PutUint16(b[2:], uint16(len(b)))
		copy(b[12:16], t.src.Addr().AsSlice())
		copy(b[16:20], t.dst.Addr().AsSlice())
		binary.BigEndian.PutUint16(b[10:], foldSum(internetSum(b[:20])))
	} else {
		b[0] = 0x60
		b[6] = 17
		b[7] = 64
		binary.BigEndian.PutUint16(b[4:], uint16(len(u)))
		copy(b[8:24], t.src.Addr().AsSlice())
		copy(b[24:40], t.dst.Addr().AsSlice())
	}
	return b
}
func udpEndpoint(a netip.AddrPort) []byte {
	n := 4
	typ := byte(1)
	if a.Addr().Is6() {
		n = 16
		typ = 4
	}
	b := make([]byte, n+3)
	b[0] = typ
	copy(b[1:], a.Addr().AsSlice())
	binary.BigEndian.PutUint16(b[1+n:], a.Port())
	return b
}
func readUDPEndpoint(b []byte) (netip.AddrPort, []byte, bool) {
	if len(b) < 1 {
		return netip.AddrPort{}, nil, false
	}
	n := 0
	switch b[0] {
	case 1:
		n = 4
	case 4:
		n = 16
	default:
		return netip.AddrPort{}, nil, false
	}
	if len(b) < n+3 || len(b) > n+3+udpMaxPayload {
		return netip.AddrPort{}, nil, false
	}
	a, _ := netip.AddrFromSlice(b[1 : 1+n])
	p := binary.BigEndian.Uint16(b[1+n:])
	if p == 0 {
		return netip.AddrPort{}, nil, false
	}
	return netip.AddrPortFrom(a, p), b[n+3:], true
}
