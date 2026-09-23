package domainroute

import "testing"

func TestRulesWildcardExcludesApexAndNormalizesCase(t *testing.T) {
	r, err := ParseRules([]byte("v1\n*.Example.COM\nexact.example\n"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.example.com", "a.b.example.com", "EXACT.EXAMPLE"} {
		if !r.Match(name) {
			t.Errorf("should match %s", name)
		}
	}
	for _, name := range []string{"example.com", "notexample.com", "a.example.net"} {
		if r.Match(name) {
			t.Errorf("unexpected match %s", name)
		}
	}
}

func TestRulesRejectWrongVersion(t *testing.T) {
	if _, err := ParseRules([]byte("v2\nexample.com\n")); err == nil {
		t.Fatal("accepted unknown snapshot version")
	}
}
