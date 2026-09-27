# Upstream documentation and contract sync

Run the audit after selecting the upstream base and target refs:

```sh
sh scripts/openwrt/audit-upstream-docs.sh p-85.13 p-86.1
```

The audit includes every changed Markdown file (architecture, security,
release, QA, design, runbook and vendor-patch notes), workflow files, and the
CI/release/install lifecycle scripts named in the helper. Source-only changes
do not require a documentation classification.

Every changed normative file needs exactly one row in
`docs/UPSTREAM-SYNC.tsv`. The key contains the path and base/head Git blob IDs,
so an edit to already reviewed text becomes unclassified again. Use one of:

- `OPENWRT RELEVANT`
- `KEENETIC ONLY`
- `RETIRED/HISTORICAL`
- `DOC ONLY`

Every row also needs a short rationale. Missing rows, duplicate rows, unknown
classifications and empty rationale fail closed. The ledger is evidence of
review, not a blanket path allowlist.

The p-85.13 → p-86.1 diff changes two normative documents: `README.md` and the
unique-strategy-set design spec. Both are classified `OPENWRT RELEVANT` because
the common panel/detector workflow has been ported; the audit also records the
spec's stale measured-target description in `UPSTREAM-CONTRACTS.md`. Their
base/head blob IDs and rationales are recorded below. The helper fixture tests
unclassified docs and CI edits, exact blob-keyed acceptance, invalid
classifications, and source-only changes.
