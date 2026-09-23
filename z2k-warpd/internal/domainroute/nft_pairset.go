//go:build openwrt

package domainroute

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

var nftIdentifier = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

const nftPairSetOwner = `comment "z2k WARP DNS pairs"`

type nftPairSet struct {
	binary, family, table, set string
	lazy                       bool
	check                      func() error
	run                        func(string) error
}

var nftPairStates = struct {
	sync.Mutex
	sets map[string]map[pair]time.Time
}{sets: make(map[string]map[pair]time.Time)}

func openWrtNFTFromEnv() (*nftPairSet, bool, error) {
	if os.Getenv("Z2K_WARP_DOMAIN_DISABLED") == "1" {
		return nil, true, nil
	}
	family := os.Getenv("Z2K_WARP_DOMAIN_NFT_FAMILY")
	table := os.Getenv("Z2K_WARP_DOMAIN_NFT_TABLE")
	set := os.Getenv("Z2K_WARP_DOMAIN_NFT_SET")
	binary := os.Getenv("Z2K_WARP_DOMAIN_NFT")
	configured := family != "" || table != "" || set != "" || binary != ""
	if !configured {
		if os.Getenv("Z2K_WARP_OPENWRT") == "1" {
			return nil, true, errors.New("OpenWrt WARP nft backend is not configured")
		}
		return nil, false, nil
	}
	if family != "inet" || table != "zapret2" || set != "z2k_warp_domain4" ||
		!nftIdentifier.MatchString(family) || !nftIdentifier.MatchString(table) || !nftIdentifier.MatchString(set) {
		return nil, true, errors.New("invalid OpenWrt WARP nft backend configuration")
	}
	return &nftPairSet{
		binary: binary, family: family, table: table, set: set,
		lazy: os.Getenv("Z2K_WARP_DOMAIN_NFT_LAZY") == "1",
	}, true, nil
}

func (s *nftPairSet) key() string { return s.family + "/" + s.table + "/" + s.set }

func (s *nftPairSet) Apply(changes []Change, now time.Time) error {
	return s.update(changes, now, false)
}

func (s *nftPairSet) ReplaceAll(changes []Change, now time.Time) error {
	return s.update(changes, now, true)
}

func (s *nftPairSet) update(changes []Change, now time.Time, replace bool) error {
	if s == nil || !nftIdentifier.MatchString(s.family) || !nftIdentifier.MatchString(s.table) || !nftIdentifier.MatchString(s.set) {
		return errors.New("invalid OpenWrt WARP nft set configuration")
	}
	nftPairStates.Lock()
	defer nftPairStates.Unlock()
	current := nftPairStates.sets[s.key()]
	next := make(map[pair]time.Time, len(current)+len(changes))
	if !replace {
		for key, expiry := range current {
			if expiry.After(now) {
				next[key] = expiry
			}
		}
	}
	type operation struct {
		expiry time.Time
		delete bool
	}
	operations := make(map[pair]operation, len(changes)+len(current))
	if !replace {
		for key, expiry := range current {
			if !expiry.After(now) {
				operations[key] = operation{delete: true}
			}
		}
	}
	for _, change := range changes {
		if _, err := clientSet(change.Client); err != nil || !EligibleDestination(change.Dest) {
			return errors.New("invalid WARP DNS pair")
		}
		key := pair{client: change.Client, dest: change.Dest}
		if change.Delete || !change.Expiry.After(now) {
			delete(next, key)
			operations[key] = operation{delete: true}
			continue
		}
		next[key] = change.Expiry
		operations[key] = operation{expiry: change.Expiry}
	}
	if len(next) > MaxPairs {
		return errors.New("OpenWrt WARP nft pair limit exceeded")
	}
	clients := make(map[netip.Addr]struct{})
	for key := range next {
		clients[key.client] = struct{}{}
	}
	if len(clients) > MaxClients {
		return errors.New("OpenWrt WARP nft client limit exceeded")
	}
	if s.lazy {
		hasAdd := false
		for _, op := range operations {
			if !op.delete {
				hasAdd = true
				break
			}
		}
		if !hasAdd {
			nftPairStates.sets[s.key()] = next
			return nil
		}
	}
	if len(operations) == 0 && !replace {
		nftPairStates.sets[s.key()] = next
		return nil
	}
	if err := s.ensureOwned(); err != nil {
		return err
	}
	keys := make([]pair, 0, len(operations))
	for key := range operations {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].client != keys[j].client {
			return keys[i].client.Less(keys[j].client)
		}
		return keys[i].dest.Less(keys[j].dest)
	})
	var script strings.Builder
	if replace {
		fmt.Fprintf(&script, "flush set %s %s %s\n", s.family, s.table, s.set)
	}
	for _, key := range keys {
		op := operations[key]
		if !replace || op.delete {
			fmt.Fprintf(&script, "destroy element %s %s %s { %s . %s }\n", s.family, s.table, s.set, key.client, key.dest)
		}
		if op.delete {
			continue
		}
		remaining := op.expiry.Sub(now)
		seconds := int(remaining / time.Second)
		if time.Duration(seconds)*time.Second < remaining {
			seconds++
		}
		if seconds < 1 {
			seconds = 1
		}
		if seconds > 3600 {
			seconds = 3600
		}
		fmt.Fprintf(&script, "add element %s %s %s { %s . %s timeout %ds }\n", s.family, s.table, s.set, key.client, key.dest, seconds)
	}
	if s.run != nil {
		if err := s.run(script.String()); err != nil {
			return err
		}
	} else {
		binary := s.binary
		if binary == "" {
			binary = "nft"
		}
		cmd := exec.Command(binary, "-f", "-")
		cmd.Stdin = strings.NewReader(script.String())
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("apply OpenWrt WARP nft pairs: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	nftPairStates.sets[s.key()] = next
	return nil
}

func (s *nftPairSet) ensureOwned() error {
	if s.check != nil {
		return s.check()
	}
	binary := s.binary
	if binary == "" {
		binary = "nft"
	}
	output, err := exec.Command(binary, "list", "set", s.family, s.table, s.set).CombinedOutput()
	if err != nil {
		return fmt.Errorf("inspect OpenWrt WARP nft set ownership: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), nftPairSetOwner) {
		return errors.New("OpenWrt WARP nft pair set owner conflict")
	}
	return nil
}
