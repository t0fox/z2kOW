# Upstream model

z2kOW is maintained as an independent OpenWrt project derived from
[necronicle/z2k](https://github.com/necronicle/z2k).

The GitHub fork relationship is not required for synchronization. Upstream is
treated as a versioned source dependency and integrated through controlled sync
branches.

## Branch model

- `main` — z2kOW product branch.
- `sync/<version>` — temporary integration branch for one upstream update.
- `z2k-staging` / `z2k-enhanced` — retained only where the existing release
  pipeline uses them as staging / delivery pointers. They are not the z2kOW
  development branch.

## Recorded baseline

The machine-readable baseline lives in [UPSTREAM.json](./UPSTREAM.json).

Current recorded upstream:

- repository: `necronicle/z2k`
- branch: `z2k-enhanced`
- version: `p-86.1`
- commit: `950928ee615431f3442640b08a9a1cb877641900`
- first z2kOW product baseline after that sync:
  `13b22feadb7fa998bfd4f6ace08f85779fb1872a`

## Git remotes

A local clone should use:

```text
origin    https://github.com/t0fox/z2kOW.git
upstream  https://github.com/necronicle/z2k.git
```

Configure it once:

```bash
git remote add upstream https://github.com/necronicle/z2k.git
git fetch upstream --tags
```

If `upstream` already exists:

```bash
git remote set-url upstream https://github.com/necronicle/z2k.git
git fetch upstream --tags
```

## Normal update flow

Do not merge upstream directly into `main`.

The intended flow is:

```text
necronicle/z2k:z2k-enhanced
              |
              | fetch
              v
        sync/<version>
              |
              | audit + CI + fixes
              v
             main
```

The repository includes two ways to do this:

1. GitHub Actions -> **Sync upstream** -> **Run workflow**
   - `check` only reports whether upstream changed.
   - `prepare` creates `sync/<version>`, performs a controlled merge,
     updates `UPSTREAM.json`, pushes the branch and attempts to open a PR
     against `main`.
   - if Git reports merge conflicts, the workflow stops without modifying
     `main`.

2. Local helper:

```bash
./tools/sync-upstream.sh check
./tools/sync-upstream.sh prepare
```

A clean merge is only a candidate. Existing CI remains the authority for
whether the resulting z2kOW state is acceptable.

## Why this is not a blind mirror

OpenWrt-specific lifecycle, packaging, firewall integration, UCI/dnsmasq,
procd, WebUI behavior and compatibility contracts can overlap with upstream
changes. Therefore an upstream update is never allowed to fast-forward
`main` automatically.

The sync branch exists specifically to expose those overlaps before the product
branch moves.

## Attribution

Detaching the repository from GitHub's fork network does not remove source
history or attribution. z2kOW continues to record and link its z2k origin here,
in the Git history and in the project README.
