package gvsub

import (
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestQUICVerdicts(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, next := range []Verdict{Good, Dead} {
			t.Run(fmt.Sprintf("neighbor=%v/next=%v", neighbor, next), func(t *testing.T) {
				s, n, r, c := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				n.mu.Lock()
				n.state[bad.String()] = next
				n.mu.Unlock()
				c.add(SearchPause)
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if r.rejects(bad) {
					t.Fatal("Good/Dead сохранил отказ QUIC")
				}
			})
		}
	}
}

func TestQUICCleanup(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, shutdown := range []bool{false, true} {
			t.Run(fmt.Sprintf("neighbor=%v/shutdown=%v", neighbor, shutdown), func(t *testing.T) {
				s, _, r, c := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				if shutdown {
					s.Shutdown()
				} else {
					c.add(IdleDrop + 1)
					s.Tick()
				}
				if r.rejects(bad) {
					t.Fatal("после уборки остался отказ QUIC")
				}
			})
		}
	}
}

func TestQUICReapply(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, tick := range []bool{false, true} {
			t.Run(fmt.Sprintf("neighbor=%v/tick=%v", neighbor, tick), func(t *testing.T) {
				s, _, r, _ := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				good := netip.MustParseAddr("74.125.110.38")
				wait(t, s.OnDNS(gvName, []netip.Addr{good}))
				r.mu.Lock()
				r.rejected = nil
				r.recreate = tick
				r.mu.Unlock()
				if tick {
					s.Tick()
				} else {
					s.Reapply()
				}
				if !r.rejects(bad) {
					t.Fatal("отказ QUIC не восстановлен")
				}
				if r.rejects(good) {
					t.Fatal("Reapply запретил QUIC для Good")
				}
				s.Shutdown()
				s.Reapply()
				if r.rejects(bad) {
					t.Fatal("Reapply вернул отказ после Shutdown")
				}
			})
		}
	}
}

func TestQUICNoLateVerdict(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprint(shutdown), func(t *testing.T) {
			s, n, r, c := newSvc()
			s.Resolver = nil
			wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
			if !r.rejects(bad) {
				t.Fatal("Bad не получил отказ QUIC")
			}
			gate := make(chan struct{})
			s.Checker = gatedNet{inner: n, gate: gate}
			c.add(SearchPause)
			done := s.OnDNS(gvName, []netip.Addr{bad})
			if shutdown {
				s.Shutdown()
			} else {
				c.add(IdleDrop + 1)
				s.Tick()
			}
			close(gate)
			wait(t, done)
			if r.rejects(bad) {
				t.Fatal("запоздалая проверка вернула отказ QUIC")
			}
		})
	}
}

func TestQUICRuleCommands(t *testing.T) {
	for _, tc := range []struct{ addr, set string }{
		{"74.125.110.70", "quic4"},
		{"2a00:1450::7", "quic6"},
	} {
		t.Run(tc.set, func(t *testing.T) {
			var calls []string
			r := NFTables{Run: func(args []string, input string) ([]byte, error) {
				calls = append(calls, strings.Join(args, " ")+"\n"+input)
				return nil, nil
			}}
			a := netip.MustParseAddr(tc.addr)
			if err := r.RejectQUIC(a); err != nil {
				t.Fatal(err)
			}
			if err := r.AllowQUIC(a); err != nil {
				t.Fatal(err)
			}
			if len(calls) != 2 || !strings.Contains(calls[0], "add element inet z2k_gvsub "+tc.set+" { "+tc.addr+" }") ||
				!strings.Contains(calls[1], "delete element inet z2k_gvsub "+tc.set+" { "+tc.addr+" }") {
				t.Fatalf("неверные команды набора QUIC: %v", calls)
			}
		})
	}
}

func TestQUICFramework(t *testing.T) {
	for _, noV6 := range []bool{false, true} {
		r := NFTables{NoV6: noV6}
		s := r.script()
		if !strings.Contains(s, "forward ip daddr @quic4 udp dport 443 reject") {
			t.Fatal("нет отказа QUIC/IPv4")
		}
		if strings.Contains(s, "iptables") || strings.Contains(s, "ip6tables") {
			t.Fatal("nft-адаптер вызывает iptables")
		}
		if strings.Contains(s, "quic6") == noV6 {
			t.Fatalf("NoV6=%v, но состояние IPv6 неверное", noV6)
		}
	}
}

// nft-команды выполняются вне общей блокировки: под ней служба принимает ответы
// DNS, и восстановление правил по сигналу хука держало бы DNS секундами.
type slowRules struct{ *fakeRules }

func (r slowRules) RejectQUIC(a netip.Addr) error {
	time.Sleep(200 * time.Millisecond)
	return r.fakeRules.RejectQUIC(a)
}

func TestQUICRulesOutsideLock(t *testing.T) {
	s, _, r, _ := newSvc()
	s.Resolver = nil
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	s.Rules = slowRules{r}
	go s.Reapply()
	time.Sleep(20 * time.Millisecond)
	start := time.Now()
	s.OnDNS("rr2---sn-test.googlevideo.com", []netip.Addr{netip.MustParseAddr("74.125.110.38")})
	if d := time.Since(start); d > 100*time.Millisecond {
		t.Fatalf("приём ответа DNS ждал nft-команду %v", d)
	}
}
