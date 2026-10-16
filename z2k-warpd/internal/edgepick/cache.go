package edgepick

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

const cacheTTL = 24 * time.Hour
const maxFailureTTL = 10 * time.Minute

type FailureReason string

const (
	FailureHandshake FailureReason = "handshake"
	FailureTransit   FailureReason = "transit"
	FailureGeo       FailureReason = "geo"
)

type Failure struct {
	Step     account.Step  `json:"step"`
	Reason   FailureReason `json:"reason"`
	FailedAt time.Time     `json:"failed_at"`
	RetryAt  time.Time     `json:"retry_at"`
}

type cacheFile struct {
	Version  int       `json:"version"`
	WAN      string    `json:"wan"`
	SavedAt  time.Time `json:"saved_at"`
	Results  []Result  `json:"results"`
	Failures []Failure `json:"failures,omitempty"`
}

// LoadCache returns hints for the same uplink only. Live proof is still needed.
func LoadCache(path, wan string, now time.Time) []Result {
	cache, ok := readCache(path, wan, now)
	if !ok {
		return nil
	}
	var result []Result
	for _, r := range cache.Results {
		if !validStep(r.Step) {
			continue
		}
		if r.CheckedAt.IsZero() || now.Sub(r.CheckedAt) > cacheTTL || r.CheckedAt.Sub(now) > 5*time.Minute {
			continue
		}
		result = append(result, r)
	}
	return result
}

// LoadFailures возвращает временные исключения для той же идентичности WAN.
func LoadFailures(path, wan string, now time.Time) []Failure {
	cache, ok := readCache(path, wan, now)
	if !ok || cache.Version < 2 {
		return nil
	}
	var failures []Failure
	for _, failure := range cache.Failures {
		if !validStep(failure.Step) || !validFailureReason(failure.Reason) {
			continue
		}
		if failure.FailedAt.IsZero() || failure.FailedAt.Sub(now) > 5*time.Minute ||
			!failure.RetryAt.After(failure.FailedAt) || failure.RetryAt.Sub(failure.FailedAt) > maxFailureTTL ||
			!failure.RetryAt.After(now) {
			continue
		}
		failures = append(failures, failure)
	}
	return failures
}

func readCache(path, wan string, now time.Time) (cacheFile, bool) {
	if wan == "" {
		return cacheFile{}, false
	}
	f, err := os.Open(path)
	if err != nil {
		return cacheFile{}, false
	}
	defer f.Close()
	var cache cacheFile
	dec := json.NewDecoder(io.LimitReader(f, 64<<10))
	if err := dec.Decode(&cache); err != nil || (cache.Version != 1 && cache.Version != 2) || cache.WAN != wan {
		return cacheFile{}, false
	}
	if cache.SavedAt.IsZero() || now.Sub(cache.SavedAt) > cacheTTL || cache.SavedAt.Sub(now) > 5*time.Minute {
		return cacheFile{}, false
	}
	return cache, true
}

// SaveCache writes a versioned, key-free hint file using atomic rename.
func SaveCache(ctx context.Context, path, wan string, results []Result) error {
	return SaveCacheWithFailures(ctx, path, wan, results, nil)
}

// SaveCacheWithFailures атомарно сохраняет успешные подсказки и временные отказы.
func SaveCacheWithFailures(ctx context.Context, path, wan string, results []Result, failures []Failure) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var savedAt time.Time
	for _, r := range results {
		if r.CheckedAt.After(savedAt) {
			savedAt = r.CheckedAt
		}
	}
	for _, failure := range failures {
		if failure.FailedAt.After(savedAt) {
			savedAt = failure.FailedAt
		}
	}
	if savedAt.IsZero() {
		savedAt = time.Now()
	}
	data, err := json.Marshal(cacheFile{Version: 2, WAN: wan, SavedAt: savedAt, Results: results, Failures: failures})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".edge-cache-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	if dir, err := os.Open(filepath.Dir(path)); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}

func validStep(step account.Step) bool {
	return step.Transport == "wg" && step.Host != "" && step.Port > 0 && step.Port <= 65535
}

func validFailureReason(reason FailureReason) bool {
	switch reason {
	case FailureHandshake, FailureTransit, FailureGeo:
		return true
	default:
		return false
	}
}
