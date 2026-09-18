package classify

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestRunDeadlineEmitsTypedPartialResult(t *testing.T) {
	tr, err := TLSTrigger("example.com")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	var events []ProgressEvent
	res := Run(ctx, "198.51.100.1:443", tr, Options{
		Repeats: 1,
		Timeout: time.Second,
		Dialer: func(ctx context.Context, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		},
		Progress: func(ev ProgressEvent) { events = append(events, ev) },
	})
	if res.ErrorCode != "GLOBAL_TIMEOUT" {
		t.Fatalf("error_code=%q, want GLOBAL_TIMEOUT; reason=%s", res.ErrorCode, res.Reason)
	}
	if res.DurationMS <= 0 || res.CandidatesTested == 0 || res.TimeToFirstProbeMS <= 0 {
		t.Fatalf("missing metrics: duration=%d candidates=%d first=%d", res.DurationMS, res.CandidatesTested, res.TimeToFirstProbeMS)
	}
	if len(events) != res.CandidatesTested {
		t.Fatalf("progress events=%d candidates=%d", len(events), res.CandidatesTested)
	}
}
