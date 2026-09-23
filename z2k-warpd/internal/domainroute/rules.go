package domainroute

import (
	"bytes"
	"errors"
	"strings"
)

const MaxRules = 4096

type Rules struct {
	exact map[string]struct{}
	wild  map[string]struct{}
}

func ParseRules(data []byte) (Rules, error) {
	r := Rules{exact: make(map[string]struct{}), wild: make(map[string]struct{})}
	lines := bytes.Split(data, []byte{'\n'})
	if len(lines) == 0 || string(bytes.TrimSpace(lines[0])) != "v1" {
		return r, errors.New("invalid domain snapshot version")
	}
	count := 0
	for _, raw := range lines[1:] {
		name := strings.ToLower(strings.TrimSpace(string(raw)))
		if name == "" {
			continue
		}
		wild := strings.HasPrefix(name, "*.")
		base := name
		if wild {
			base = name[2:]
		}
		if !validDomain(base) {
			return r, errors.New("invalid domain in snapshot")
		}
		if wild {
			r.wild[base] = struct{}{}
		} else {
			r.exact[base] = struct{}{}
		}
		count++
		if count > MaxRules {
			return r, errors.New("too many domain rules")
		}
	}
	return r, nil
}

func validDomain(s string) bool {
	if len(s) < 4 || len(s) > 253 {
		return false
	}
	parts := strings.Split(s, ".")
	if len(parts) < 2 {
		return false
	}
	for _, part := range parts {
		if len(part) == 0 || len(part) > 63 || part[0] == '-' || part[len(part)-1] == '-' {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	tld := parts[len(parts)-1]
	if strings.HasPrefix(tld, "xn--") {
		return len(tld) > 4
	}
	for _, c := range tld {
		if c < 'a' || c > 'z' {
			return false
		}
	}
	return true
}

func (r Rules) Match(name string) bool {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	if _, ok := r.exact[name]; ok {
		return true
	}
	for suffix := range r.wild {
		if strings.HasSuffix(name, "."+suffix) {
			return true
		}
	}
	return false
}

func (r Rules) Len() int { return len(r.exact) + len(r.wild) }
