# Upstream documentation and contract sync

Run the audit after selecting the upstream base and target refs:

```sh
sh scripts/openwrt/audit-upstream-docs.sh p-85.13 p-85.16
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

The verified p-85.13 → p-85.16 diff has no changed normative documents, QA,
workflow or release scripts; its 34 changed paths are runtime/source, tests,
release snapshots and generated binaries. Therefore the committed ledger starts
with no classified changes. The helper fixture tests unclassified docs and CI
edits, exact blob-keyed acceptance, invalid classifications, and source-only
changes.
