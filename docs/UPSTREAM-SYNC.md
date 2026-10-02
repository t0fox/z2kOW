# Upstream documentation review

Use this procedure when carrying a new `necronicle/z2k` revision into z2kOW. Choose the upstream baseline and target refs first, then inspect the full source and documentation diff. The current audit snapshot and behavior gaps are in [`UPSTREAM-PARITY-MATRIX.md`](UPSTREAM-PARITY-MATRIX.md).

```sh
sh scripts/openwrt/audit-upstream-docs.sh <base-ref> <target-ref>
```

The helper checks changed Markdown contracts/design/QA notes, workflow files and named release/lifecycle scripts. Each changed normative file needs one exact row in [`UPSTREAM-SYNC.tsv`](UPSTREAM-SYNC.tsv), keyed by path and base/head Git blob IDs. A changed blob requires a fresh review row. Accepted classifications are:

- `OPENWRT RELEVANT`
- `KEENETIC ONLY`
- `RETIRED/HISTORICAL`
- `DOC ONLY`

Each row needs a short rationale. The ledger records review evidence; it is not a path allowlist and does not replace source-level behavior review.

`UPSTREAM-SYNC.tsv` currently retains the historical p-85.13 → p-86.1 documentation classification. Those blob IDs are not evidence for a later audit. Add classifications for the exact refs being reviewed; do not reuse historical rows when file contents have changed.

The OpenWrt user release flow is documented separately in [`openwrt-release-operations.md`](openwrt-release-operations.md). Upstream sequence discovery does not publish an OpenWrt artifact or make it visible to routers.
