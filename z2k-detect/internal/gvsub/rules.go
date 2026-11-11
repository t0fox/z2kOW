package gvsub

// Правила подмены принадлежат отдельной nftables-таблице; fw4 её не меняет.
import (
	"fmt"
	"net/netip"
	"os/exec"
	"strings"
	"time"
)

const (
	Table       = "z2k_gvsub"
	ExcludeMark = "0x10000000"
	DNSQueue    = 210
	EngineQueue = 200
)

// Rules управляет только таблицей, принадлежащей службе подмены.
type Rules interface {
	Add(bad, good netip.Addr) error
	Del(bad, good netip.Addr) error
	RejectQUIC(addr netip.Addr) error
	AllowQUIC(addr netip.Addr) error
	Ensure() (bool, error)
	Teardown()
}

// NFTables — адаптер для fw4; команды nft -f применяются транзакционно.
type NFTables struct {
	Queue       uint16
	EngineQueue uint16
	NoV6        bool
	Run         func(args []string, input string) ([]byte, error)
}

func (r NFTables) run(args []string, input string) ([]byte, error) {
	if r.Run != nil {
		return r.Run(args, input)
	}
	cmd := exec.Command("nft", args...)
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("nft %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func (r NFTables) queues() (int, int) {
	dns, engine := int(r.Queue), int(r.EngineQueue)
	if dns == 0 {
		dns = DNSQueue
	}
	if engine == 0 {
		engine = EngineQueue
	}
	return dns, engine
}

func (r NFTables) script() string {
	dns, engine := r.queues()
	lines := []string{
		"add table inet " + Table,
		"add map inet " + Table + " map4 { type ipv4_addr : ipv4_addr; }",
		"add set inet " + Table + " quic4 { type ipv4_addr; }",
		"add set inet " + Table + " reset4 { type ipv4_addr . inet_service . ipv4_addr . inet_service; flags timeout; timeout 15s; }",
		"add chain inet " + Table + " dns { type filter hook output priority mangle; policy accept; }",
		"add chain inet " + Table + " prerouting { type filter hook prerouting priority mangle - 1; policy accept; }",
		"add chain inet " + Table + " nat_prerouting { type nat hook prerouting priority dstnat - 1; policy accept; }",
		"add chain inet " + Table + " forward { type filter hook forward priority filter - 1; policy accept; }",
		fmt.Sprintf("add rule inet %s dns udp sport 53 queue num %d bypass", Table, dns),
		fmt.Sprintf("add rule inet %s prerouting ip daddr @map4 tcp dport 443 ct state new ct mark set ct mark | %s", Table, ExcludeMark),
		fmt.Sprintf("add rule inet %s prerouting ip daddr @map4 udp dport 443 ct state new ct mark set ct mark | %s", Table, ExcludeMark),
		fmt.Sprintf("add rule inet %s prerouting ip daddr @map4 tcp dport 443 ct mark & %s == %s ct original packets 0-20 queue num %d bypass", Table, ExcludeMark, ExcludeMark, engine),
		fmt.Sprintf("add rule inet %s prerouting ip daddr @map4 udp dport 443 ct mark & %s == %s ct original packets 0-20 queue num %d bypass", Table, ExcludeMark, ExcludeMark, engine),
		fmt.Sprintf("add rule inet %s nat_prerouting ip daddr map @map4 tcp dport 443 dnat ip to ip daddr map @map4", Table),
		fmt.Sprintf("add rule inet %s nat_prerouting ip daddr map @map4 udp dport 443 dnat ip to ip daddr map @map4", Table),
		fmt.Sprintf("add rule inet %s forward ip daddr @quic4 udp dport 443 reject with icmp type port-unreachable", Table),
		fmt.Sprintf("add rule inet %s forward ip saddr . tcp sport . ip daddr . tcp dport @reset4 reject with tcp reset", Table),
	}
	if !r.NoV6 {
		lines = append(lines,
			"add map inet "+Table+" map6 { type ipv6_addr : ipv6_addr; }",
			"add set inet "+Table+" quic6 { type ipv6_addr; }",
			"add set inet "+Table+" reset6 { type ipv6_addr . inet_service . ipv6_addr . inet_service; flags timeout; timeout 15s; }",
			fmt.Sprintf("add rule inet %s prerouting ip6 daddr @map6 tcp dport 443 ct state new ct mark set ct mark | %s", Table, ExcludeMark),
			fmt.Sprintf("add rule inet %s prerouting ip6 daddr @map6 udp dport 443 ct state new ct mark set ct mark | %s", Table, ExcludeMark),
			fmt.Sprintf("add rule inet %s prerouting ip6 daddr @map6 tcp dport 443 ct mark & %s == %s ct original packets 0-20 queue num %d bypass", Table, ExcludeMark, ExcludeMark, engine),
			fmt.Sprintf("add rule inet %s prerouting ip6 daddr @map6 udp dport 443 ct mark & %s == %s ct original packets 0-20 queue num %d bypass", Table, ExcludeMark, ExcludeMark, engine),
			fmt.Sprintf("add rule inet %s nat_prerouting ip6 daddr map @map6 tcp dport 443 dnat ip6 to ip6 daddr map @map6", Table),
			fmt.Sprintf("add rule inet %s nat_prerouting ip6 daddr map @map6 udp dport 443 dnat ip6 to ip6 daddr map @map6", Table),
			fmt.Sprintf("add rule inet %s forward ip6 daddr @quic6 udp dport 443 reject with icmpv6 type port-unreachable", Table),
			fmt.Sprintf("add rule inet %s forward ip6 saddr . tcp sport . ip6 daddr . tcp dport @reset6 reject with tcp reset", Table),
		)
	}
	return strings.Join(lines, "\n") + "\n"
}

func (r NFTables) Ensure() (bool, error) {
	out, err := r.run([]string{"list", "tables"}, "")
	if err != nil {
		return false, err
	}
	if strings.Contains(string(out), "table inet "+Table) {
		return false, nil
	}
	if _, err := r.run([]string{"-f", "-"}, r.script()); err != nil {
		return false, err
	}
	return true, nil
}

func (r NFTables) Teardown() { _, _ = r.run([]string{"delete", "table", "inet", Table}, "") }

func (r NFTables) apply(op string, bad, good netip.Addr) error {
	if !bad.IsValid() || !good.IsValid() || bad.Is4In6() || good.Is4In6() || bad.IsUnspecified() || good.IsUnspecified() || bad == good || bad.Is6() != good.Is6() {
		return fmt.Errorf("некорректная пара адресов %s → %s", bad, good)
	}
	if bad.Is6() && r.NoV6 {
		return nil
	}
	mapName := "map4"
	if bad.Is6() {
		mapName = "map6"
	}
	_, err := r.run([]string{"-f", "-"}, fmt.Sprintf("%s element inet %s %s { %s : %s }\n", op, Table, mapName, bad, good))
	return err
}

func (r NFTables) Add(bad, good netip.Addr) error { return r.apply("add", bad, good) }
func (r NFTables) Del(bad, good netip.Addr) error { return r.apply("delete", bad, good) }

func (r NFTables) quic(op string, addr netip.Addr) error {
	if !addr.IsValid() || addr.Is4In6() || addr.IsUnspecified() {
		return fmt.Errorf("некорректный адрес QUIC %s", addr)
	}
	if addr.Is6() && r.NoV6 {
		return nil
	}
	setName := "quic4"
	if addr.Is6() {
		setName = "quic6"
	}
	_, err := r.run([]string{"-f", "-"}, fmt.Sprintf("%s element inet %s %s { %s }\n", op, Table, setName, addr))
	return err
}

func (r NFTables) RejectQUIC(addr netip.Addr) error { return r.quic("add", addr) }
func (r NFTables) AllowQUIC(addr netip.Addr) error  { return r.quic("delete", addr) }

const ResetHold = 15 * time.Second

func (r NFTables) Reset(f Flow) error {
	if f.Proto != "tcp" || f.Dst.Is6() && r.NoV6 {
		return nil
	}
	if !f.Src.IsValid() || !f.Dst.IsValid() || f.Src.Is6() != f.Dst.Is6() || f.Sport == 0 || f.Dport == 0 {
		return fmt.Errorf("некорректный поток для сброса")
	}
	setName := "reset4"
	if f.Dst.Is6() {
		setName = "reset6"
	}
	entry := fmt.Sprintf("%s . %d . %s . %d", f.Src, f.Sport, f.Dst, f.Dport)
	if _, err := r.run([]string{"-f", "-"}, fmt.Sprintf("add element inet %s %s { %s timeout %s }\n", Table, setName, entry, ResetHold)); err != nil {
		return err
	}
	time.AfterFunc(ResetHold, func() {
		_, _ = r.run([]string{"-f", "-"}, fmt.Sprintf("delete element inet %s %s { %s }\n", Table, setName, entry))
	})
	return nil
}
