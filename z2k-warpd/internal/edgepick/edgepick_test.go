package edgepick

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

func TestCacheIsAtomicAndScopedToCurrentWAN(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "edge-cache.json")
	old := Result{Step: account.Step{Transport: "wg", Host: "188.114.96.17", Port: 2408}, Country: "DE", Colo: "FRA", RTT: 28 * time.Millisecond, CheckedAt: now}
	if err := SaveCache(context.Background(), path, "wan0|192.0.2.2", []Result{old}); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(path); err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("cache permission: %v %v", st, err)
	}
	got := LoadCache(path, "wan0|192.0.2.2", now.Add(time.Hour))
	if len(got) != 1 || got[0].Step != old.Step || got[0].Country != "DE" {
		t.Fatalf("cache hit: %+v", got)
	}
	if got := LoadCache(path, "wan1|192.0.2.3", now); len(got) != 0 {
		t.Fatalf("cross-WAN cache: %+v", got)
	}
	if got := LoadCache(path, "wan0|192.0.2.2", now.Add(25*time.Hour)); len(got) != 0 {
		t.Fatalf("stale cache: %+v", got)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := SaveCache(cancelled, path, "wan0|192.0.2.2", []Result{{Step: old.Step, Country: "RU", CheckedAt: now}}); err == nil {
		t.Fatal("cancelled save succeeded")
	}
	if got := LoadCache(path, "wan0|192.0.2.2", now); len(got) != 1 || got[0].Country != "DE" {
		t.Fatalf("cancelled save replaced old cache: %+v", got)
	}
}

func TestCacheIgnoresCorruptionAndMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "edge-cache.json")
	if got := LoadCache(path, "wan0|192.0.2.2", time.Now()); len(got) != 0 {
		t.Fatalf("missing cache: %+v", got)
	}
	if err := os.WriteFile(path, []byte("{broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := LoadCache(path, "wan0|192.0.2.2", time.Now()); len(got) != 0 {
		t.Fatalf("corrupt cache: %+v", got)
	}
}

func TestWANIdentityMatchesSelectedSourceInterface(t *testing.T) {
	ifaces := map[string][]string{"usb0": {"192.0.2.2"}, "wifi0": {"198.51.100.5"}}
	if got := identityForIP("192.0.2.2", ifaces); got != "usb0|192.0.2.2" {
		t.Fatalf("WAN identity = %q", got)
	}
	if got := identityForIP("198.51.100.5", ifaces); got != "wifi0|198.51.100.5" {
		t.Fatalf("WAN identity = %q", got)
	}
}

func TestLookupDoHWithClientUsesOnlyARecords(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dns-query" || r.URL.Query().Get("name") != metaHost || r.URL.Query().Get("type") != "A" || r.Header.Get("Accept") != "application/dns-json" {
			t.Errorf("unexpected DoH request: %s", r.URL.String())
		}
		_, _ = w.Write([]byte(`{"Status":0,"Answer":[{"type":28,"data":"2606:4700::1"},{"type":1,"data":"162.159.140.220"}]}`))
	}))
	defer srv.Close()
	got, err := lookupDoHWithClient(context.Background(), srv.Client(), srv.URL+"/dns-query?name=speed.cloudflare.com&type=A")
	if err != nil || got != "162.159.140.220:443" {
		t.Fatalf("target=%q err=%v", got, err)
	}
}

func TestLookupDoHWithClientRejectsBadAnswers(t *testing.T) {
	for _, body := range []string{`{"Status":2}`, `{"Status":0,"Answer":[{"type":1,"data":"127.0.0.1"}]}`, `{"Status":0,"Answer":[{"type":1,"data":"nonsense"}]}`, `bad-json`} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		_, err := lookupDoHWithClient(context.Background(), srv.Client(), srv.URL)
		srv.Close()
		if err == nil {
			t.Fatalf("accepted DoH response %q", body)
		}
	}
}

func TestParseMetaUsesEdgeCountryNotExitCountry(t *testing.T) {
	meta, err := parseMeta([]byte(`{"country":"RU","colo":{"iata":"FRA","cca2":"DE"}}`))
	if err != nil || meta.Colo != "FRA" || meta.Country != "DE" {
		t.Fatalf("meta=%+v err=%v", meta, err)
	}
	if _, err := parseMeta([]byte(`{"country":"RU","colo":{"iata":"DME"}}`)); err == nil {
		t.Fatal("missing edge country was accepted")
	}
}

func TestProbeWithClientSendsRefererAndCountsLoss(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Referer") != "https://speed.cloudflare.com" {
			t.Errorf("Referer=%q", r.Header.Get("Referer"))
		}
		if calls == 1 {
			http.Error(w, "try again", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"country":"RU","colo":{"iata":"HEL","cca2":"FI"}}`))
	}))
	defer srv.Close()
	meta, rtt, loss, err := probeWithClient(context.Background(), srv.Client(), srv.URL)
	if err != nil || meta.Country != "FI" || meta.Colo != "HEL" || loss != 33 || rtt <= 0 || calls != 3 {
		t.Fatalf("meta=%+v rtt=%s loss=%d calls=%d err=%v", meta, rtt, loss, calls, err)
	}
}

func TestProbeWithClientRejectsOversizedAndInvalidResponses(t *testing.T) {
	for _, body := range []string{strings.Repeat("x", 5000), `{"colo":{"iata":"FRA"}}`, `bad-json`} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		_, _, _, err := probeWithClient(context.Background(), srv.Client(), srv.URL)
		srv.Close()
		if err == nil {
			t.Fatalf("accepted response %q", body[:min(len(body), 20)])
		}
	}
}

func TestProbeWithClientStopsAfterCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, _, _, err := probeWithClient(ctx, srv.Client(), srv.URL)
	if err == nil || time.Since(start) > time.Second {
		t.Fatalf("probe did not stop promptly: err=%v elapsed=%s", err, time.Since(start))
	}
}

func TestRankPrefersReliableForeignEdgeOverFasterDomestic(t *testing.T) {
	got := Rank([]Result{
		{Step: account.Step{Host: "1.1.1.1"}, Country: "RU", RTT: 5 * time.Millisecond},
		{Step: account.Step{Host: "2.2.2.2"}, Country: "FI", RTT: 40 * time.Millisecond},
		{Step: account.Step{Host: "3.3.3.3"}, Country: "DE", RTT: 25 * time.Millisecond},
		{Step: account.Step{Host: "4.4.4.4"}, Country: "SE", RTT: 12 * time.Millisecond, LossPct: 20},
		{Step: account.Step{Host: "5.5.5.5"}, RTT: 3 * time.Millisecond},
	})
	want := []string{"3.3.3.3", "2.2.2.2", "4.4.4.4", "1.1.1.1", "5.5.5.5"}
	for i, host := range want {
		if got[i].Step.Host != host {
			t.Fatalf("rank[%d]=%s, want %s", i, got[i].Step.Host, host)
		}
	}
}

func TestCandidatesAreBoundedDiverseAndDeduplicated(t *testing.T) {
	ep := account.Endpoint{V4: "8.6.112.1", Ports: []int{2408, 4500}}
	pools := []netip.Prefix{netip.MustParsePrefix("8.6.112.0/24"), netip.MustParsePrefix("188.114.96.0/24")}
	got := Candidates(ep, []string{"8.6.112.1", "8.47.69.1"}, pools, 6, 42)
	if len(got) != 6 || got[0].Host != "8.6.112.1" || got[1].Host != "8.47.69.1" {
		t.Fatalf("candidate priority: %+v", got)
	}
	seen := map[string]bool{}
	diverse := false
	for _, step := range got {
		if seen[step.Host] || step.Port != 2408 || step.Transport != "wg" {
			t.Fatalf("duplicate or bad step: %+v", step)
		}
		seen[step.Host] = true
		if netip.MustParsePrefix("188.114.96.0/24").Contains(netip.MustParseAddr(step.Host)) {
			diverse = true
		}
	}
	if !diverse {
		t.Fatalf("no second network in %+v", got)
	}
	again := Candidates(ep, []string{"8.6.112.1", "8.47.69.1"}, pools, 6, 42)
	for i := range got {
		if got[i] != again[i] {
			t.Fatalf("sampling changed for same seed: %+v != %+v", got, again)
		}
	}
}

func TestReadPoolsSkipsUnapprovedAndBadLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pools.txt")
	data := "# WARP\n8.6.112.0/24\n188.114.96.0/24\n8.6.112.0/24\n192.0.2.0/24\n10.0.0.0/24\n8.6.112.0/16\ninvalid\n"
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	got := ReadPools(path)
	if len(got) != 2 || got[0].String() != "8.6.112.0/24" || got[1].String() != "188.114.96.0/24" {
		t.Fatalf("pools: %+v", got)
	}
}
