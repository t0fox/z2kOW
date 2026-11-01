package domainroute

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"time"
)

const clientSetPrefix = "z2kd_"

// PairSet uses the upstream hash:ip backend unless the OpenWrt build overlay
// receives an explicit nft tuple from procd. This file replaces ipset.go only
// for the OpenWrt runtime; the signed upstream binaries remain byte-identical.
type PairSet struct{ Binary, IPTablesBinary string }

func (s PairSet) ipset(args ...string) ([]byte, error) {
	bin := s.Binary
	if bin == "" {
		bin = "ipset"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func (s PairSet) iptables(args ...string) ([]byte, error) {
	bin := s.IPTablesBinary
	if bin == "" {
		bin = "iptables"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func clientSet(client netip.Addr) (string, error) {
	if !client.Is4() || !(client.IsPrivate() || carrierNAT.Contains(client)) {
		return "", errors.New("not a LAN client")
	}
	return clientSetPrefix + client.String(), nil
}
func setClient(name string) (netip.Addr, bool) {
	if !strings.HasPrefix(name, clientSetPrefix) {
		return netip.Addr{}, false
	}
	ip, err := netip.ParseAddr(strings.TrimPrefix(name, clientSetPrefix))
	canonical, ce := clientSet(ip)
	return ip, err == nil && ce == nil && canonical == name
}
func markArgs(action string, client netip.Addr, name string) []string {
	return []string{"-w", "-t", "mangle", action, "PREROUTING", "-s", client.String() + "/32", "-m", "set", "--match-set", name, "dst", "-j", "MARK", "--set-xmark", "0x989/0x989"}
}
func (s PairSet) ensureMark(client netip.Addr, name string) error {
	if _, err := s.iptables(markArgs("-C", client, name)...); err == nil {
		return nil
	}
	if out, err := s.iptables(markArgs("-A", client, name)...); err != nil {
		return fmt.Errorf("add WARP DNS mark: %w: %s", err, out)
	}
	return nil
}
func (s PairSet) removeMark(client netip.Addr, name string) {
	_, _ = s.iptables(markArgs("-D", client, name)...)
	for i := 0; i < 8; i++ {
		if _, err := s.iptables(markArgs("-C", client, name)...); err != nil {
			break
		}
		if _, err := s.iptables(markArgs("-D", client, name)...); err != nil {
			break
		}
	}
}
func (s PairSet) Apply(changes []Change, now time.Time) error {
	backend, selected, err := openWrtNFTFromEnv()
	if selected {
		if err != nil || backend == nil {
			return err
		}
		return backend.Apply(changes, now)
	}
	ensured := make(map[string]bool)
	for _, ch := range changes {
		name, err := clientSet(ch.Client)
		if err != nil || !EligibleDestination(ch.Dest) {
			return errors.New("invalid WARP DNS pair")
		}
		if ch.Delete {
			delete(ensured, name)
			_, _ = s.ipset("del", name, ch.Dest.String(), "-exist")
			saved, err := s.ipset("save", name)
			if err == nil && !strings.Contains(string(saved), "\nadd ") {
				s.removeMark(ch.Client, name)
				_, _ = s.ipset("destroy", name)
			}
			continue
		}
		if !ensured[name] {
			if out, err := s.ipset("create", name, "hash:ip", "family", "inet", "timeout", "3600", "maxelem", "8192", "-exist"); err != nil {
				return fmt.Errorf("create WARP DNS set: %w: %s", err, out)
			}
		}
		seconds := int(ch.Expiry.Sub(now).Seconds())
		if ch.Expiry.After(now.Add(time.Duration(seconds) * time.Second)) {
			seconds++
		}
		if seconds < 1 {
			seconds = 1
		}
		if seconds > 3600 {
			seconds = 3600
		}
		if out, err := s.ipset("add", name, ch.Dest.String(), "timeout", fmt.Sprint(seconds), "-exist"); err != nil {
			return fmt.Errorf("add WARP DNS address: %w: %s", err, out)
		}
		if !ensured[name] {
			if err := s.ensureMark(ch.Client, name); err != nil {
				return err
			}
			ensured[name] = true
		}
	}
	return nil
}
func (s PairSet) ReplaceAll(changes []Change, now time.Time) error {
	backend, selected, err := openWrtNFTFromEnv()
	if selected {
		if err != nil || backend == nil {
			return err
		}
		return backend.ReplaceAll(changes, now)
	}
	output, err := s.ipset("list", "-n")
	if err != nil {
		return fmt.Errorf("list WARP DNS sets: %w: %s", err, output)
	}
	for _, name := range strings.Fields(string(output)) {
		client, ok := setClient(name)
		if !ok {
			continue
		}
		s.removeMark(client, name)
		if out, err := s.ipset("destroy", name); err != nil {
			return fmt.Errorf("destroy stale WARP DNS set: %w: %s", err, out)
		}
	}
	return s.Apply(changes, now)
}

const nftExclusionSetOwner = "comment \"z2k WARP domain exclusions\""

// ExclSet пишет DNS-исключения в общий nft-набор, который заранее создаёт Rust.
type ExclSet struct{}

func (s ExclSet) Apply(changes []Change, now time.Time) error {
	backend, selected, err := openWrtNFTExclFromEnv()
	if selected {
		if err != nil || backend == nil {
			return err
		}
		return backend.Apply(changes, now)
	}
	return errors.New("не настроен nft-бэкенд WARP OpenWrt")
}

func (s ExclSet) ReplaceAll(changes []Change, now time.Time) error {
	backend, selected, err := openWrtNFTExclFromEnv()
	if selected {
		if err != nil || backend == nil {
			return err
		}
		return backend.ReplaceAll(changes, now)
	}
	return errors.New("не настроен nft-бэкенд WARP OpenWrt")
}

type nftExclSet struct {
	binary, family, table, set string
	lazy                       bool
	check                      func() error
	run                        func(string) error
}

var nftExclStates = struct {
	sync.Mutex
	sets map[string]map[netip.Addr]time.Time
}{sets: make(map[string]map[netip.Addr]time.Time)}

func openWrtNFTExclFromEnv() (*nftExclSet, bool, error) {
	if os.Getenv("Z2K_WARP_DOMAIN_DISABLED") == "1" {
		return nil, true, nil
	}
	family := os.Getenv("Z2K_WARP_DOMAIN_NFT_FAMILY")
	table := os.Getenv("Z2K_WARP_DOMAIN_NFT_TABLE")
	set := os.Getenv("Z2K_WARP_DOMAIN_NFT_EXCL_SET")
	binary := os.Getenv("Z2K_WARP_DOMAIN_NFT")
	configured := family != "" || table != "" || set != "" || binary != ""
	if !configured {
		if os.Getenv("Z2K_WARP_OPENWRT") == "1" {
			return nil, true, errors.New("не настроен nft-бэкенд исключений WARP OpenWrt")
		}
		return nil, false, nil
	}
	if family != "inet" || table != "zapret2" || !nftIdentifier.MatchString(set) {
		return nil, true, errors.New("неверная конфигурация nft-бэкенда исключений WARP OpenWrt")
	}
	return &nftExclSet{
		binary: binary, family: family, table: table, set: set,
		lazy: os.Getenv("Z2K_WARP_DOMAIN_NFT_LAZY") == "1",
	}, true, nil
}

func (s *nftExclSet) key() string { return s.family + "/" + s.table + "/" + s.set }

func (s *nftExclSet) Apply(changes []Change, now time.Time) error {
	return s.update(changes, now, false)
}

func (s *nftExclSet) ReplaceAll(changes []Change, now time.Time) error {
	return s.update(changes, now, true)
}

func (s *nftExclSet) update(changes []Change, now time.Time, replace bool) error {
	if s == nil || !nftIdentifier.MatchString(s.family) || !nftIdentifier.MatchString(s.table) || !nftIdentifier.MatchString(s.set) {
		return errors.New("неверная конфигурация nft-набора исключений WARP OpenWrt")
	}
	nftExclStates.Lock()
	defer nftExclStates.Unlock()
	current := nftExclStates.sets[s.key()]
	next := make(map[netip.Addr]time.Time, len(current)+len(changes))
	if !replace {
		for address, expiry := range current {
			if expiry.After(now) {
				next[address] = expiry
			}
		}
	}
	type operation struct {
		expiry time.Time
		delete bool
	}
	operations := make(map[netip.Addr]operation, len(changes)+len(current))
	if !replace {
		for address, expiry := range current {
			if !expiry.After(now) {
				operations[address] = operation{delete: true}
			}
		}
	}
	for _, change := range changes {
		if !EligibleDestination(change.Dest) {
			return errors.New("неверный адрес исключения WARP")
		}
		address := change.Dest
		if change.Delete || !change.Expiry.After(now) {
			delete(next, address)
			operations[address] = operation{delete: true}
			continue
		}
		if expiry, ok := current[address]; ok && expiry.After(now) && expiry.Equal(change.Expiry) {
			continue
		}
		next[address] = change.Expiry
		operations[address] = operation{expiry: change.Expiry}
	}
	if len(next) > MaxPairs {
		return errors.New("превышен предел исключений WARP OpenWrt")
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
			nftExclStates.sets[s.key()] = next
			return nil
		}
	}
	if len(operations) == 0 && !replace {
		nftExclStates.sets[s.key()] = next
		return nil
	}
	if err := s.ensureOwned(); err != nil {
		return err
	}
	addresses := make([]netip.Addr, 0, len(operations))
	for address := range operations {
		addresses = append(addresses, address)
	}
	sort.Slice(addresses, func(i, j int) bool { return addresses[i].Less(addresses[j]) })
	var script strings.Builder
	if replace {
		fmt.Fprintf(&script, "flush set %s %s %s\n", s.family, s.table, s.set)
	}
	for _, address := range addresses {
		op := operations[address]
		if !replace || op.delete {
			fmt.Fprintf(&script, "destroy element %s %s %s { %s }\n", s.family, s.table, s.set, address)
		}
		if op.delete {
			continue
		}
		seconds := nftExclusionTimeoutSeconds(op.expiry, now)
		fmt.Fprintf(&script, "add element %s %s %s { %s timeout %ds }\n", s.family, s.table, s.set, address, seconds)
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
			return fmt.Errorf("применение исключений WARP OpenWrt: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	nftExclStates.sets[s.key()] = next
	return nil
}

func (s *nftExclSet) ensureOwned() error {
	if s.check != nil {
		return s.check()
	}
	binary := s.binary
	if binary == "" {
		binary = "nft"
	}
	output, err := exec.Command(binary, "list", "set", s.family, s.table, s.set).CombinedOutput()
	if err != nil {
		return fmt.Errorf("проверка nft-набора исключений WARP OpenWrt: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), nftExclusionSetOwner) {
		return errors.New("nft-набор исключений WARP OpenWrt принадлежит другому компоненту")
	}
	return nil
}

func nftExclusionTimeoutSeconds(expiry, now time.Time) int {
	seconds := int(expiry.Sub(now).Seconds())
	if expiry.After(now.Add(time.Duration(seconds) * time.Second)) {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	if seconds > 3600 {
		seconds = 3600
	}
	return seconds
}
