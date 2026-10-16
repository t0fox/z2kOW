package engine

import (
	"context"
	"sort"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/edgepick"
	"github.com/necronicle/z2k/z2k-warpd/internal/ladder"
)

const edgeScanBudget = 60 * time.Second

const (
	edgeHandshakeFailureTTL = 2 * time.Minute
	edgeTransitFailureTTL   = 5 * time.Minute
	edgeGeoFailureTTL       = 2 * time.Minute
)

// scanEdges runs before ready/routing. One WG transport at a time uses the
// existing device key and shared TUN; a second session could steal replies.
func (e *Engine) scanEdges(ctx context.Context) []edgepick.Result {
	if e.cfg.Mode == ladder.ModeH2 || len(e.cfg.EdgeCandidates) == 0 {
		return nil
	}
	scanCtx, cancel := context.WithTimeout(ctx, edgeScanBudget)
	defer cancel()
	wan, err := e.cfg.EdgeWAN(e.cfg.EdgeCandidates[0].Host)
	if err != nil {
		e.cfg.Logf("edge: WAN fingerprint unavailable: %v", err)
	}
	var results []edgepick.Result
	checked := make(map[account.Step]bool)
	failures := make(map[account.Step]edgepick.Failure)
	if wan != "" {
		for _, failure := range edgepick.LoadFailures(e.cfg.EdgeCachePath, wan, e.cfg.Now()) {
			failures[failure.Step] = failure
		}
	}
	retryAll := len(e.cfg.EdgeCandidates) > 0
	for _, step := range e.cfg.EdgeCandidates {
		if _, failed := failures[step]; !failed {
			retryAll = false
			break
		}
	}
	if retryAll {
		e.cfg.Logf("edge: все кандидаты в отрицательном кэше; повторяем полный проход")
	}
	var cached []edgepick.Result
	if wan != "" {
		cached = edgepick.Rank(edgepick.LoadCache(e.cfg.EdgeCachePath, wan, e.cfg.Now()))
		for _, hint := range cached {
			if hint.Country == "" || hint.Country == "RU" {
				continue
			}
			if _, failed := failures[hint.Step]; failed && !retryAll {
				break
			}
			_, hadFailure := failures[hint.Step]
			result, ok, reason := e.checkEdge(scanCtx, hint.Step)
			if scanCtx.Err() == nil {
				checked[hint.Step] = true
				if ok {
					delete(failures, hint.Step)
				} else if reason != "" {
					failures[hint.Step] = edgeFailure(hint.Step, reason, e.cfg.Now())
				}
			}
			if ok {
				if result.Country != "" && result.Country != "RU" {
					e.cfg.Logf("edge: cached foreign %s %s %s proved again", result.Colo, result.Country, result.Step.Host)
					if hadFailure {
						updated := replaceResult(cached, result)
						e.saveEdgeCache(ctx, wan, updated, failures)
					}
					return []edgepick.Result{result}
				}
				results = append(results, result)
			}
			break
		}
	}
	var skipped []account.Step
	for _, step := range e.cfg.EdgeCandidates {
		if scanCtx.Err() != nil {
			break
		}
		if checked[step] {
			continue
		}
		if _, failed := failures[step]; failed && !retryAll {
			skipped = append(skipped, step)
			continue
		}
		result, ok, reason := e.checkEdge(scanCtx, step)
		if ok {
			results = append(results, result)
			delete(failures, step)
		} else if scanCtx.Err() == nil {
			checked[step] = true
			if reason != "" {
				failures[step] = edgeFailure(step, reason, e.cfg.Now())
			}
		}
	}
	if len(results) == 0 && !retryAll && len(skipped) > 0 && scanCtx.Err() == nil {
		step := skipped[0]
		result, ok, reason := e.checkEdge(scanCtx, step)
		if ok {
			results = append(results, result)
			delete(failures, step)
		} else if scanCtx.Err() == nil && reason != "" {
			failures[step] = edgeFailure(step, reason, e.cfg.Now())
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	if wan != "" && (len(results) > 0 || len(failures) > 0) {
		e.saveEdgeCache(ctx, wan, results, failures)
	}
	e.cfg.Logf("edge: checked up to %d candidates, %d verified with location", len(e.cfg.EdgeCandidates), len(results))
	return results
}

func (e *Engine) checkEdge(ctx context.Context, step account.Step) (edgepick.Result, bool, edgepick.FailureReason) {
	if step.Transport != "wg" || step.Host == "" || step.Port < 1 || step.Port > 65535 {
		return edgepick.Result{}, false, ""
	}
	tr, err := e.open(ctx, step, e.tunDev.Handle())
	if err != nil {
		e.cfg.Logf("edge: %s handshake failed: %v", ladder.Label(step), err)
		if ctx.Err() != nil {
			return edgepick.Result{}, false, ""
		}
		return edgepick.Result{}, false, edgepick.FailureHandshake
	}
	defer tr.Close()
	if err := e.cfg.Probe(ctx, e.iface); err != nil {
		e.cfg.Logf("edge: %s no transit: %v", ladder.Label(step), err)
		if ctx.Err() != nil {
			return edgepick.Result{}, false, ""
		}
		return edgepick.Result{}, false, edgepick.FailureTransit
	}
	meta, rtt, loss, geoErr := e.cfg.GeoProbe(ctx, e.iface)
	result := edgepick.Result{Step: step, RTT: rtt, LossPct: loss, CheckedAt: e.cfg.Now()}
	if geoErr != nil || meta.Country == "" {
		e.cfg.Logf("edge: %s location unavailable: %v", ladder.Label(step), geoErr)
		if ctx.Err() != nil {
			return edgepick.Result{}, false, ""
		}
		return edgepick.Result{}, false, edgepick.FailureGeo
	}
	result.Colo, result.Country = meta.Colo, meta.Country
	if wan, err := e.cfg.EdgeWAN(step.Host); err == nil {
		result.WAN = wan
	}
	return result, true, ""
}

func edgeFailure(step account.Step, reason edgepick.FailureReason, now time.Time) edgepick.Failure {
	ttl := edgeHandshakeFailureTTL
	switch reason {
	case edgepick.FailureTransit:
		ttl = edgeTransitFailureTTL
	case edgepick.FailureGeo:
		ttl = edgeGeoFailureTTL
	}
	return edgepick.Failure{Step: step, Reason: reason, FailedAt: now, RetryAt: now.Add(ttl)}
}

func (e *Engine) saveEdgeCache(ctx context.Context, wan string, results []edgepick.Result, failures map[account.Step]edgepick.Failure) {
	list := make([]edgepick.Failure, 0, len(failures))
	for _, failure := range failures {
		list = append(list, failure)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Step.Host != list[j].Step.Host {
			return list[i].Step.Host < list[j].Step.Host
		}
		if list[i].Step.Port != list[j].Step.Port {
			return list[i].Step.Port < list[j].Step.Port
		}
		return list[i].Step.Transport < list[j].Step.Transport
	})
	if err := edgepick.SaveCacheWithFailures(ctx, e.cfg.EdgeCachePath, wan, results, list); err != nil {
		e.cfg.Logf("edge: cache save failed: %v", err)
	}
}

func replaceResult(results []edgepick.Result, result edgepick.Result) []edgepick.Result {
	out := make([]edgepick.Result, 0, len(results)+1)
	for _, existing := range results {
		if existing.Step != result.Step {
			out = append(out, existing)
		}
	}
	return append(out, result)
}
