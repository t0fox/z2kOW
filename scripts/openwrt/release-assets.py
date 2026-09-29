#!/usr/bin/env python3
"""Prepare and verify the exact public asset bundle for a z2kOW release."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import date
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SHA_RE = re.compile(r"[0-9a-fA-F]{40}\Z")
SEMVER_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
PACKAGE_NAMES = {
    "z2k-adapter",
    "z2k-webpanel",
    "z2k-warp-runtime",
    "z2k-zapret2-runtime",
}


class AssetError(Exception):
    pass


def fail(message: str) -> None:
    raise AssetError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True, encoding="utf-8")
    except OSError as exc:
        fail(f"cannot run {command[0]}: {exc}")
    if result.returncode != 0:
        fail(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr.strip()}")
    return result


def package_metadata(apk_tool: str, path: Path) -> dict[str, str]:
    output = run([apk_tool, "adbdump", str(path)]).stdout
    fields: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"^\s*(name|version|arch)\s*(?:=|:)\s*(.*?)\s*$", line, re.I)
        if match:
            fields[match.group(1).lower()] = match.group(2)
    missing = {"name", "version", "arch"} - fields.keys()
    if missing:
        fail(f"{path.name}: apk adbdump is missing {', '.join(sorted(missing))}")
    if path.name != f"{fields['name']}-{fields['version']}.apk":
        fail(f"APK filename does not match its metadata: {path.name}")
    if fields["name"] not in PACKAGE_NAMES:
        fail(f"unexpected release package: {fields['name']}")
    return fields


def changelog_section(path: Path, version: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read changelog: {exc}")
    lines = text.splitlines()
    wanted = re.compile(rf"^##\s+\[{re.escape(version)}\](?:\s|$)")
    start = next((i for i, line in enumerate(lines) if wanted.match(line)), None)
    if start is None:
        fail(f"CHANGELOG.md has no section for [{version}]")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    body = "\n".join(lines[start + 1 : end]).strip()
    if not body:
        fail(f"CHANGELOG.md section [{version}] is empty")
    return body + "\n"


def parse_changelog_history(path: Path) -> list[dict[str, object]]:
    """Parse published release sections from the canonical CHANGELOG.md."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail(f"cannot read changelog: {exc}")

    heading = re.compile(r"^##\s+\[([^]]+)\]\s+-\s+(\S+)\s*$")
    section_indexes = [i for i, line in enumerate(lines) if line.startswith("## ")]
    releases: list[dict[str, object]] = []
    seen: set[str] = set()
    aliases = {
        "новое": "new", "добавлено": "new", "добавления": "new",
        "исправлено": "fixed", "исправления": "fixed",
        "изменено": "changed", "изменения": "changed", "доступность": "changed",
        "важно": "important", "важные замечания": "important",
        "совместимость": "important", "обновление с предыдущих сборок": "important",
    }
    for position, start in enumerate(section_indexes):
        match = heading.fullmatch(lines[start])
        if not match:
            continue
        version, published_at = match.groups()
        if not SEMVER_RE.fullmatch(version):
            fail(f"CHANGELOG.md release version is not SemVer: {version}")
        if version in seen:
            fail(f"CHANGELOG.md contains duplicate release version: {version}")
        seen.add(version)
        try:
            date.fromisoformat(published_at)
        except ValueError:
            fail(f"CHANGELOG.md release date is invalid for {version}: {published_at}")
        end = section_indexes[position + 1] if position + 1 < len(section_indexes) else len(lines)
        changelog: dict[str, list[str]] = {"new": [], "fixed": [], "changed": [], "important": []}
        category = "changed"
        last_item: tuple[str, int] | None = None
        for line in lines[start + 1 : end]:
            if line.startswith("### "):
                category = aliases.get(line[4:].strip().casefold(), "changed")
                last_item = None
                continue
            item = re.match(r"^\s*[-*]\s+(\S.*)$", line)
            if item:
                changelog[category].append(item.group(1).strip())
                last_item = (category, len(changelog[category]) - 1)
                continue
            if last_item and line.startswith(("  ", "\t")) and line.strip():
                cat, index = last_item
                changelog[cat][index] += " " + line.strip()
            elif line.strip():
                last_item = None
        if not any(changelog.values()):
            fail(f"CHANGELOG.md release section [{version}] is empty")
        releases.append({
            "version": version,
            "tag": f"v{version}",
            "published_at": published_at,
            "release_url": f"https://github.com/t0fox/z2kOW/releases/tag/v{version}",
            "changelog": changelog,
        })

    for newer, older in zip(releases, releases[1:]):
        newer_version = tuple(int(part) for part in str(newer["version"]).split("."))
        older_version = tuple(int(part) for part in str(older["version"]).split("."))
        if newer_version <= older_version:
            fail("CHANGELOG.md release sections must be in strictly descending SemVer order")
    return releases


def validate_product_history(history: list[dict[str, object]], version: str) -> None:
    if not history:
        fail("CHANGELOG.md has no published product release history")
    if history[0].get("version") != version:
        fail("candidate version must be the newest published CHANGELOG.md section")
    if sum(item.get("version") == version for item in history) != 1:
        fail(f"CHANGELOG.md must contain exactly one section for [{version}]")


def baseline(filename: str) -> str:
    try:
        value = (ROOT / "tests/openwrt" / filename).read_text(encoding="ascii").strip()
    except OSError as exc:
        fail(f"cannot read {filename}: {exc}")
    if not SHA_RE.fullmatch(value):
        fail(f"{filename} must contain a full source SHA")
    return value.lower()


def load_provenance(dist: Path) -> dict[str, object]:
    path = dist / "provenance.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read builder provenance: {exc}")
    if not isinstance(data, dict) or data.get("production_release") is not True or data.get("ci_snapshot") is not False:
        fail("builder provenance must identify a non-snapshot production release")
    if data.get("verified_sdk") is not True or data.get("seed_ref_verified_remote") is not True:
        fail("production provenance must confirm the pinned SDK and remote seed ref")
    return data


def public_key_der(path: Path) -> bytes:
    if not path.is_file():
        fail(f"pinned feed public key does not exist: {path}")
    try:
        pem = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as exc:
        fail(f"cannot read pinned feed public key: {exc}")
    if "-----BEGIN PUBLIC KEY-----" not in pem or "PRIVATE KEY" in pem:
        fail("pinned feed key must be a public SubjectPublicKeyInfo PEM")
    try:
        result = subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", str(path), "-outform", "DER"],
            check=False, capture_output=True,
        )
    except OSError as exc:
        fail(f"cannot run openssl to read pinned feed key: {exc}")
    if result.returncode != 0 or not result.stdout:
        fail("pinned feed public key is not a valid OpenSSL public key")
    return result.stdout


def rendered_installer(template: Path, source_sha: str, key_fingerprint: str) -> str:
    try:
        text = template.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read production installer template: {exc}")
    replacements = {
        "@Z2K_FEED_KEY_SHA256@": key_fingerprint,
        "@Z2K_KEY_SOURCE_SHA@": source_sha.lower(),
    }
    for marker, value in replacements.items():
        if text.count(marker) != 1:
            fail(f"installer template must contain {marker} exactly once")
        text = text.replace(marker, value)
    if "@Z2K_" in text:
        fail("installer template contains an unresolved production marker")
    return text


def rendered_bootstrap(template: Path, key_fingerprint: str) -> str:
    try:
        text = template.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read z2kow bootstrap: {exc}")
    assignment = re.compile(r'(?m)^EXPECTED_FEED_KEY_SHA256="([^"]*)"$')
    matches = list(assignment.finditer(text))
    if len(matches) != 1:
        fail("z2kow.sh must define EXPECTED_FEED_KEY_SHA256 exactly once")
    current = matches[0].group(1)
    if current == "@Z2K_FEED_KEY_SHA256@":
        text = text.replace(current, key_fingerprint)
    elif current.lower() != key_fingerprint.lower():
        fail("z2kow.sh pinned feed key fingerprint does not match package/openwrt/keys/z2k-feed.pem")
    if "@Z2K_" in text:
        fail("z2kow.sh contains an unresolved production marker")
    return text


def artifact_record(path: Path, package: str, version: str | None = None) -> dict[str, object]:
    return {
        "filename": path.name,
        "package": package,
        "version": version,
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
    }


def checksum_names(bundle: Path) -> list[str]:
    excluded = {"SHA256SUMS", "SHA256SUMS.sig", "RELEASE_NOTES.md"}
    return sorted(path.name for path in bundle.iterdir() if path.is_file() and path.name not in excluded)


def package_version_string(metadata: dict[str, str]) -> str:
    return metadata["version"]


def prepare(args: argparse.Namespace) -> None:
    if not SEMVER_RE.fullmatch(args.version):
        fail("version must be SemVer X.Y.Z without leading zeroes")
    if not SHA_RE.fullmatch(args.source_sha):
        fail("source SHA must be a full 40-character commit SHA")
    dist = args.dist.resolve()
    output = args.out.resolve()
    if not dist.is_dir():
        fail(f"distribution directory does not exist: {dist}")
    if not str(args.ci_run_id).isdecimal() or int(args.ci_run_id) < 1:
        fail("CI run id must be a positive integer")
    if output == dist or dist in output.parents:
        fail("bundle output must not be inside the canonical builder dist directory")
    if output.exists():
        if not output.is_dir() or any(output.iterdir()):
            fail(f"bundle output must be a new or empty directory: {output}")
    output.mkdir(parents=True, exist_ok=True)

    provenance = load_provenance(dist)
    if str(provenance.get("source_commit", "")).lower() != args.source_sha.lower():
        fail("builder provenance source commit does not match requested source SHA")
    if provenance.get("package_version") != args.version or str(provenance.get("package_release")) != "1":
        fail("builder provenance package identity does not match product version-r1")
    if provenance.get("openwrt_release") != "25.12.5" or provenance.get("target") != "mediatek/filogic" \
       or provenance.get("arch") != "aarch64_cortex-a53":
        fail("builder provenance target does not match the pinned production target")
    public_key = args.public_key.resolve()
    public_key_der(public_key)  # validate the pinned key before rendering assets
    key_fingerprint = sha256(public_key)
    installer_text = rendered_installer(args.installer_template.resolve(), args.source_sha, key_fingerprint)

    apks = sorted(dist.glob("z2k-*.apk"), key=lambda p: p.name)
    metadata = {entry["name"]: entry for entry in (package_metadata(args.apk_tool, apk) for apk in apks)}
    if set(metadata) != PACKAGE_NAMES or len(apks) != len(PACKAGE_NAMES):
        missing = sorted(PACKAGE_NAMES - set(metadata))
        extra = sorted(set(metadata) - PACKAGE_NAMES)
        fail(f"release APK set must contain exactly four packages (missing={missing}, extra={extra})")
    expected_frontend_version = f"{args.version}-r1"
    for name in ("z2k-adapter", "z2k-webpanel"):
        if metadata[name]["version"] != expected_frontend_version:
            fail(f"{name} must be {expected_frontend_version}, got {metadata[name]['version']}")
    arches = {entry["arch"] for entry in metadata.values()}
    if len(arches) != 1:
        fail(f"release APK architectures differ: {sorted(arches)}")
    if arches != {"aarch64_cortex-a53"}:
        fail(f"release APK architecture is not the pinned mediatek/filogic target: {sorted(arches)}")

    copied: list[Path] = []
    for apk in apks:
        destination = output / apk.name
        shutil.copyfile(apk, destination)
        copied.append(destination)

    index = output / "packages.adb"
    run([args.apk_tool, "mkndx", "--output", index.name, *[p.name for p in copied]], cwd=output)
    if not index.is_file() or index.stat().st_size == 0:
        fail("apk mkndx did not create a non-empty packages.adb")

    provenance_copy = output / "provenance.json"
    shutil.copyfile(dist / "provenance.json", provenance_copy)
    key_copy = output / "z2k-feed.pem"
    shutil.copyfile(public_key, key_copy)
    installer_path = output / "install.sh"
    installer_path.write_text(installer_text, encoding="utf-8", newline="\n")
    installer_path.chmod(0o755)
    bootstrap_path = output / "z2kow.sh"
    bootstrap_path.write_text(
        rendered_bootstrap(ROOT / "z2kow.sh", key_fingerprint), encoding="utf-8", newline="\n"
    )
    bootstrap_path.chmod(0o755)
    versions = {name: package_version_string(meta) for name, meta in sorted(metadata.items())}
    artifacts = [artifact_record(path, metadata[package_metadata(args.apk_tool, path)["name"]]["name"],
                                 metadata[package_metadata(args.apk_tool, path)["name"]]["version"])
                 for path in copied]
    artifacts.extend([
        artifact_record(index, "apk-index"),
        artifact_record(provenance_copy, "build-provenance"),
        artifact_record(installer_path, "production-installer"),
        artifact_record(key_copy, "apk-feed-public-key"),
        artifact_record(bootstrap_path, "product-bootstrap"),
    ])
    release_url = f"https://github.com/t0fox/z2kOW/releases/download/v{args.version}"
    for artifact in artifacts:
        artifact["url"] = f"{release_url}/{artifact['filename']}"
    history = parse_changelog_history(args.changelog)
    validate_product_history(history, args.version)
    manifest = {
        "schema": 2,
        "product": "z2kOW",
        "channel": "stable",
        "version": args.version,
        "product_version": args.version,
        "tag": f"v{args.version}",
        "published_at": history[0]["published_at"],
        "minimum_openwrt": provenance.get("minimum_openwrt", "25.12.5"),
        "supported_architectures": [next(iter(arches))],
        "release_url": release_url,
        "changelog": history[0]["changelog"],
        "history": history,
        "source_sha": args.source_sha.lower(),
        "ci_run_id": args.ci_run_id,
        "openwrt": {
            "release": provenance.get("openwrt_release", provenance.get("OW_RELEASE", "25.12.5")),
            "target": provenance.get("target", "mediatek/filogic"),
            "arch": next(iter(arches)),
            "adapter_api": provenance.get("adapter_api", "1"),
        },
        "upstream": {
            "repository": "necronicle/z2k",
            "baseline": provenance.get("manifest_current", provenance.get("upstream_payload_sha", "unknown")),
            "sha": provenance.get("upstream_payload_sha", baseline("BASELINE")),
        },
        "warp_runtime": {
            "baseline": provenance.get("warp_runtime_baseline", provenance.get("warp_runtime_package_version", versions["z2k-warp-runtime"].split("-r", 1)[0])),
            "sha": provenance.get("warp_runtime_source_sha", baseline("WARP_RUNTIME_BASELINE")),
            "package_version": provenance.get("warp_runtime_package_version", versions["z2k-warp-runtime"].split("-r", 1)[0]),
        },
        "zapret2": {
            "version": provenance.get("runtime_tag", "unknown"),
            "package_version": provenance.get("zapret2_package_version", versions["z2k-zapret2-runtime"].split("-r", 1)[0]),
        },
        "package_versions": versions,
        "artifacts": artifacts,
    }
    manifest_path = output / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    notes = changelog_section(args.changelog, args.version)
    acceptance_path = ROOT / "docs/openwrt-release-acceptance.json"
    try:
        acceptance = json.loads(acceptance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        acceptance = {}
    cudy_record = acceptance.get("cudy_live_acceptance", {}) if isinstance(acceptance, dict) else {}
    cudy_status = cudy_record.get("status", "not recorded") if isinstance(cudy_record, dict) else "not recorded"
    release_notes = (
        notes.rstrip()
        + "\n\n## Совместимость\n"
        + f"OpenWrt {manifest['openwrt']['release']} ({manifest['openwrt']['target']}, {manifest['openwrt']['arch']})\n"
        + f"Cudy WBR3000UAX v1: {cudy_status}\n\n"
        + "## Компоненты\n"
        + f"Upstream z2k: {manifest['upstream']['baseline']}\n"
        + f"WARP runtime: {manifest['warp_runtime']['package_version']} (source SHA {manifest['warp_runtime']['sha']})\n"
        + f"zapret2: {manifest['zapret2']['version']} ({manifest['zapret2']['package_version']})\n\n"
        + "## Проверка\n"
        + f"CI run: {args.ci_run_id}\nSource: {args.source_sha.lower()}\n"
    )
    (output / "RELEASE_NOTES.md").write_text(release_notes, encoding="utf-8")
    (output / "SHA256SUMS").write_text(
        "".join(f"{sha256(output / name)}  {name}\n" for name in checksum_names(output)), encoding="ascii"
    )
    print(f"prepared={output}")
    print(f"version={args.version}")
    print(f"source_sha={args.source_sha.lower()}")


def expected_files(bundle: Path, final: bool) -> set[str]:
    apks = {p.name for p in bundle.glob("z2k-*.apk")}
    required = apks | {
        "packages.adb", "release-manifest.json", "SHA256SUMS", "RELEASE_NOTES.md",
        "provenance.json", "install.sh", "z2kow.sh", "z2k-feed.pem",
    }
    if final:
        required.add("SHA256SUMS.sig")
    return required


def verify_checksums(bundle: Path) -> None:
    sums_path = bundle / "SHA256SUMS"
    try:
        lines = sums_path.read_text(encoding="ascii").splitlines()
    except OSError as exc:
        fail(f"cannot read SHA256SUMS: {exc}")
    expected: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._+-]+)", line)
        if not match or match.group(2) in expected:
            fail("SHA256SUMS has an invalid or duplicate entry")
        expected[match.group(2)] = match.group(1)
    actual_names = set(checksum_names(bundle))
    if set(expected) != actual_names:
        fail(f"SHA256SUMS file set mismatch (listed={sorted(expected)}, actual={sorted(actual_names)})")
    for filename, digest in expected.items():
        path = bundle / filename
        if not path.is_file() or sha256(path) != digest:
            fail(f"SHA256SUMS mismatch: {filename}")


def verify(args: argparse.Namespace) -> None:
    bundle = args.bundle.resolve()
    if not bundle.is_dir():
        fail(f"bundle directory does not exist: {bundle}")
    manifest_path = bundle / "release-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read release manifest: {exc}")
    if not isinstance(manifest, dict):
        fail("release manifest root must be an object")
    if args.version is not None and manifest.get("version") != args.version:
        fail("release manifest version does not match requested version")
    if args.source_sha is not None and str(manifest.get("source_sha", "")).lower() != args.source_sha.lower():
        fail("release manifest source SHA does not match requested SHA")
    if manifest.get("tag") != f"v{manifest.get('version', '')}" or manifest.get("product") != "z2kOW":
        fail("release manifest product or tag is invalid")
    if not SEMVER_RE.fullmatch(str(manifest.get("version", ""))) or not SHA_RE.fullmatch(str(manifest.get("source_sha", ""))):
        fail("release manifest version/source SHA is malformed")
    if manifest.get("schema") != 2 or manifest.get("channel") != "stable":
        fail("release manifest schema or product channel is invalid")
    if manifest.get("product_version") != manifest.get("version"):
        fail("release manifest product version is inconsistent")
    release_url = f"https://github.com/t0fox/z2kOW/releases/download/{manifest['tag']}"
    if manifest.get("release_url") != release_url:
        fail("release manifest URL is not the immutable t0fox/z2kOW release")
    history = manifest.get("history")
    if not isinstance(history, list) or any(not isinstance(item, dict) for item in history):
        fail("release manifest history is malformed")
    validate_product_history(history, str(manifest["version"]))
    if history[0].get("tag") != manifest.get("tag") or history[0].get("release_url") != f"https://github.com/t0fox/z2kOW/releases/tag/{manifest['tag']}":
        fail("release manifest latest history identity is inconsistent")
    if history[0].get("changelog") != manifest.get("changelog") or history[0].get("published_at") != manifest.get("published_at"):
        fail("release manifest latest changelog identity is inconsistent")
    if manifest.get("supported_architectures") != ["aarch64_cortex-a53"]:
        fail("release manifest supported architecture is not the pinned production target")
    manifest_openwrt = manifest.get("openwrt")
    if not isinstance(manifest_openwrt, dict):
        fail("release manifest OpenWrt target is malformed")
    if manifest_openwrt.get("release") != manifest.get("minimum_openwrt"):
        fail("release manifest minimum OpenWrt does not match the package target")
    files = sorted(p.name for p in bundle.iterdir() if p.is_file())
    required = expected_files(bundle, args.final)
    if set(files) != required:
        fail(f"bundle file set mismatch (expected={sorted(required)}, actual={files})")
    verify_checksums(bundle)

    provenance_path = bundle / "provenance.json"
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read bundled production provenance: {exc}")
    if not isinstance(provenance, dict) or provenance.get("production_release") is not True \
       or provenance.get("ci_snapshot") is not False or provenance.get("verified_sdk") is not True \
       or provenance.get("seed_ref_verified_remote") is not True:
        fail("bundle provenance is not verified production provenance")
    if str(provenance.get("source_commit", "")).lower() != str(manifest.get("source_sha", "")).lower() \
       or provenance.get("package_version") != manifest.get("version") or str(provenance.get("package_release")) != "1":
        fail("bundle provenance source or package identity does not match the release manifest")
    if provenance.get("openwrt_release") != "25.12.5" or provenance.get("target") != "mediatek/filogic" \
       or provenance.get("arch") != "aarch64_cortex-a53":
        fail("bundle provenance target is not the pinned production target")

    public_key_der(bundle / "z2k-feed.pem")  # validate the bundled key encoding
    key_fingerprint = sha256(bundle / "z2k-feed.pem")
    try:
        installer_text = (bundle / "install.sh").read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read bundled production installer: {exc}")
    if f'EXPECTED_FEED_KEY_SHA256="{key_fingerprint}"' not in installer_text:
        fail("production installer fingerprint does not match bundled APK feed key")
    if f'KEY_SOURCE_SHA="{manifest["source_sha"]}"' not in installer_text:
        fail("production installer does not pin the manifest source commit for key retrieval")
    if "@Z2K_" in installer_text:
        fail("production installer contains an unresolved template marker")

    bootstrap_path = bundle / "z2kow.sh"
    try:
        bootstrap_text = bootstrap_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read bundled z2kow bootstrap: {exc}")
    if f'EXPECTED_FEED_KEY_SHA256="{key_fingerprint}"' not in bootstrap_text or "@Z2K_" in bootstrap_text:
        fail("bundled z2kow bootstrap does not pin the bundled production key")

    artifact_items = manifest.get("artifacts")
    if not isinstance(artifact_items, list):
        fail("release manifest has no artifacts list")
    declared: dict[str, dict[str, object]] = {}
    for item in artifact_items:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            fail("manifest has an invalid artifact entry")
        filename = item["filename"]
        if filename in declared:
            fail(f"duplicate artifact entry: {filename}")
        if item.get("url") != f"{release_url}/{filename}":
            fail(f"artifact URL is not pinned to the t0fox release: {filename}")
        declared[filename] = item
        artifact_path = bundle / filename
        if not artifact_path.is_file() or item.get("sha256") != sha256(artifact_path):
            fail(f"manifest artifact hash mismatch: {filename}")
        if item.get("size_bytes") != artifact_path.stat().st_size:
            fail(f"manifest artifact size mismatch: {filename}")
    apk_paths = sorted(bundle.glob("z2k-*.apk"), key=lambda p: p.name)
    if len(apk_paths) != 4 or {p.name for p in apk_paths} != {p.name for p in bundle.glob("*.apk")}:
        fail("bundle must contain exactly four z2k APKs")
    metadata: dict[str, dict[str, str]] = {}
    for apk in apk_paths:
        if args.apk_tool:
            item = package_metadata(args.apk_tool, apk)
            metadata[item["name"]] = item
        else:
            match = re.fullmatch(r"(z2k-[a-z0-9-]+)-(.+)\.apk", apk.name)
            if not match:
                fail(f"invalid APK filename: {apk.name}")
            metadata[match.group(1)] = {"name": match.group(1), "version": match.group(2), "arch": "unknown"}
    if set(metadata) != PACKAGE_NAMES:
        fail("bundle APK package set is invalid")
    if args.apk_tool and {item["arch"] for item in metadata.values()} != {"aarch64_cortex-a53"}:
        fail("bundle APK architecture is not the pinned mediatek/filogic target")
    expected_versions = {name: item["version"] for name, item in sorted(metadata.items())}
    if manifest.get("package_versions") != expected_versions:
        fail("release manifest package versions do not match the APK metadata")
    manifest_openwrt = manifest.get("openwrt")
    if not isinstance(manifest_openwrt, dict) or manifest_openwrt.get("arch") != "aarch64_cortex-a53":
        fail("release manifest must identify the mediatek/filogic package architecture")
    if manifest_openwrt.get("target") != "mediatek/filogic" or manifest_openwrt.get("release") != "25.12.5":
        fail("release manifest OpenWrt target or release is not the pinned production target")
    for name in ("z2k-adapter", "z2k-webpanel"):
        if metadata[name]["version"] != f"{manifest['version']}-r1":
            fail(f"{name} APK must have product package identity {manifest['version']}-r1")
    if args.apk_tool:
        index_dump = run([args.apk_tool, "adbdump", str(bundle / "packages.adb")]).stdout
        indexed = set(re.findall(r"(?m)^\s*(?:P:\s*|name\s*=\s*)(z2k-[a-z0-9-]+)\s*$", index_dump))
        if indexed != PACKAGE_NAMES:
            fail(f"packages.adb package set is invalid: {sorted(indexed)}")
    declared_apks = {name: item for name, item in declared.items() if name.endswith(".apk")}
    required_artifacts = {p.name for p in apk_paths} | {
        "packages.adb", "provenance.json", "install.sh", "z2kow.sh", "z2k-feed.pem",
    }
    if set(declared) != required_artifacts:
        fail("manifest artifact set does not cover the exact release payload")
    for name, item in metadata.items():
        artifact = declared_apks.get(next((p.name for p in apk_paths if p.name.startswith(name + "-")), ""))
        if not artifact or artifact.get("package") != name or artifact.get("version") != item["version"]:
            fail(f"manifest artifact identity does not match {name} APK metadata")
    upstream = manifest.get("upstream")
    warp = manifest.get("warp_runtime")
    zapret = manifest.get("zapret2")
    if not isinstance(upstream, dict) or not upstream.get("baseline") or not SHA_RE.fullmatch(str(upstream.get("sha", ""))):
        fail("release manifest upstream baseline/SHA is missing or invalid")
    if not isinstance(warp, dict) or not warp.get("baseline") or not SHA_RE.fullmatch(str(warp.get("sha", ""))):
        fail("release manifest WARP runtime baseline/SHA is missing or invalid")
    if not isinstance(zapret, dict) or not zapret.get("version") or not zapret.get("package_version"):
        fail("release manifest zapret2 runtime version is missing")

    if args.final:
        if not args.public_key or not args.apk_tool or not args.apk_key_dir:
            fail("--final requires --public-key, --apk-tool, and --apk-key-dir")
        if public_key_der(args.public_key) != public_key_der(bundle / "z2k-feed.pem"):
            fail("final verifier key does not match the bundled/pinned feed public key")
        signature = bundle / "SHA256SUMS.sig"
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(args.public_key),
             "-signature", str(signature), str(bundle / "SHA256SUMS")],
            check=False, capture_output=True, text=True, encoding="utf-8",
        )
        if result.returncode != 0:
            fail("SHA256SUMS signature does not match the pinned release public key")
        index_check = run([
            args.apk_tool, "--keys-dir", str(args.apk_key_dir.resolve()),
            "adbdump", str(bundle / "packages.adb"),
        ])
        index_output = index_check.stdout + index_check.stderr
        if not re.search(r"(?m)^\s*sig\s", index_output):
            fail("final packages.adb has no APK index signature")
        if "UNTRUSTED" in index_output:
            fail("final packages.adb signature is not trusted by the pinned APK key directory")
    print("verified=true")
    print(f"version={manifest['version']}")
    print(f"source_sha={manifest['source_sha']}")


def verify_remote(args: argparse.Namespace) -> None:
    bundle = args.bundle.resolve()
    try:
        remote_assets = json.loads(args.remote_assets.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read GitHub release asset metadata: {exc}")
    if not bundle.is_dir() or not isinstance(remote_assets, list):
        fail("bundle directory and a JSON array of GitHub assets are required")

    apk_paths = sorted(bundle.glob("z2k-*.apk"))
    if len(apk_paths) != 4:
        fail(f"expected four candidate APKs, found {len(apk_paths)}")
    fixed_names = (
        "packages.adb", "SHA256SUMS", "SHA256SUMS.sig",
        "release-manifest.json", "z2k-feed.pem", "provenance.json", "install.sh", "z2kow.sh",
    )
    local_paths = [*apk_paths, *(bundle / name for name in fixed_names)]
    missing = [path.name for path in local_paths if not path.is_file()]
    if missing:
        fail(f"candidate is missing release assets: {', '.join(missing)}")

    remote_by_name: dict[str, dict[str, object]] = {}
    for item in remote_assets:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            fail("GitHub returned a malformed release asset")
        name = item["name"]
        if name in remote_by_name:
            fail(f"GitHub returned duplicate release asset: {name}")
        remote_by_name[name] = item
    if set(remote_by_name) != {path.name for path in local_paths}:
        fail("uploaded release asset names do not match the verified candidate")

    for path in local_paths:
        expected = f"sha256:{sha256(path)}"
        actual = remote_by_name[path.name].get("digest")
        if actual != expected:
            fail(f"uploaded release asset digest mismatch: {path.name}")
    print(f"verified_remote={len(local_paths)} assets")


def sign_candidate(args: argparse.Namespace) -> None:
    bundle = args.bundle.resolve()
    private_key = args.private_key.resolve()
    public_key = args.public_key.resolve()
    output = args.overlay_out.resolve()
    if not bundle.is_dir():
        fail(f"candidate bundle directory does not exist: {bundle}")
    if not private_key.is_file() or not public_key.is_file():
        fail("offline private key and pinned public key must both be readable files")
    try:
        private_key.relative_to(ROOT)
    except ValueError:
        pass
    else:
        fail("offline signing private key must be stored outside the repository")
    if output == bundle or bundle in output.parents:
        fail("signature overlay output must be outside the candidate bundle")
    output.parent.mkdir(parents=True, exist_ok=True)

    def public_der(command: list[str]) -> bytes:
        result = subprocess.run(command, check=False, capture_output=True)
        if result.returncode != 0:
            fail("cannot derive public key from offline key material")
        return result.stdout

    derived = public_der(["openssl", "pkey", "-in", str(private_key), "-pubout", "-outform", "DER"])
    pinned = public_der(["openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER"])
    if derived != pinned:
        fail("offline private key does not match the pinned release public key")

    verify(argparse.Namespace(
        bundle=bundle, version=None, source_sha=None, apk_tool=args.apk_tool,
        final=False, public_key=None, apk_key_dir=None,
    ))
    apk_names = sorted(p.name for p in bundle.glob("z2k-*.apk"))
    signed_index = bundle / ".packages.adb.signed"
    run([
        args.apk_tool, "--keys-dir", str(public_key.parent), "mkndx",
        "--allow-untrusted", "--sign", str(private_key),
        "--output", str(signed_index), *apk_names,
    ], cwd=bundle)
    if not signed_index.is_file() or signed_index.stat().st_size == 0:
        fail("offline apk mkndx did not create a signed packages.adb")
    (bundle / "packages.adb").write_bytes(signed_index.read_bytes())
    signed_index.unlink()

    manifest_path = bundle / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    index_hash = sha256(bundle / "packages.adb")
    index_size = (bundle / "packages.adb").stat().st_size
    index_entries = [item for item in manifest.get("artifacts", []) if isinstance(item, dict) and item.get("filename") == "packages.adb"]
    if len(index_entries) != 1:
        fail("candidate manifest must declare packages.adb exactly once")
    index_entries[0]["sha256"] = index_hash
    index_entries[0]["size_bytes"] = index_size
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    checksum_file_names = checksum_names(bundle)
    sums_path = bundle / "SHA256SUMS"
    sums_path.write_text("".join(f"{sha256(bundle / name)}  {name}\n" for name in checksum_file_names), encoding="ascii")
    signature_path = bundle / "SHA256SUMS.sig"
    sign_result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature_path), str(sums_path)],
        check=False, capture_output=True, text=True, encoding="utf-8",
    )
    if sign_result.returncode != 0:
        fail("OpenSSL could not sign SHA256SUMS with the pinned release key")

    verify(argparse.Namespace(
        bundle=bundle, version=None, source_sha=None, apk_tool=args.apk_tool,
        final=True, public_key=public_key, apk_key_dir=public_key.parent,
    ))
    try:
        with tarfile.open(output, "w:gz") as archive:
            for name in ("packages.adb", "release-manifest.json", "SHA256SUMS", "SHA256SUMS.sig"):
                archive.add(bundle / name, arcname=name, recursive=False)
    except OSError as exc:
        fail(f"cannot write offline signature overlay: {exc}")
    max_bytes = 48 * 1024
    if output.stat().st_size > max_bytes:
        output.unlink()
        fail(f"signature overlay exceeds the workflow input limit ({max_bytes} bytes)")
    print(f"signature_overlay={output}")
    print(f"bytes={output.stat().st_size}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare", help="create release bundle and preview notes")
    prep.add_argument("--dist", type=Path, required=True)
    prep.add_argument("--out", type=Path, required=True)
    prep.add_argument("--version", required=True)
    prep.add_argument("--source-sha", required=True)
    prep.add_argument("--ci-run-id", required=True)
    prep.add_argument("--changelog", type=Path, required=True)
    prep.add_argument("--apk-tool", required=True)
    prep.add_argument("--public-key", type=Path, required=True)
    prep.add_argument("--installer-template", type=Path, required=True)
    prep.set_defaults(func=prepare)
    check = commands.add_parser("verify", help="verify bundle hashes and optional final signature")
    check.add_argument("--bundle", type=Path, default=Path("."))
    check.add_argument("--version")
    check.add_argument("--source-sha")
    check.add_argument("--apk-tool")
    check.add_argument("--final", action="store_true")
    check.add_argument("--public-key", type=Path)
    check.add_argument("--apk-key-dir", type=Path)
    check.set_defaults(func=verify)
    remote = commands.add_parser("verify-remote", help="compare GitHub asset digests with the verified candidate")
    remote.add_argument("--bundle", type=Path, required=True)
    remote.add_argument("--remote-assets", type=Path, required=True)
    remote.set_defaults(func=verify_remote)
    signer = commands.add_parser("sign", help="sign a candidate bundle offline and emit a small overlay")
    signer.add_argument("--bundle", type=Path, required=True)
    signer.add_argument("--apk-tool", required=True)
    signer.add_argument("--private-key", type=Path, required=True)
    signer.add_argument("--public-key", type=Path, required=True)
    signer.add_argument("--overlay-out", type=Path, required=True)
    signer.set_defaults(func=sign_candidate)
    return root


def main() -> int:
    args = parser().parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssetError as exc:
        print(f"release-assets: {exc}", file=sys.stderr)
        raise SystemExit(1)
