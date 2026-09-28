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


def baseline(filename: str) -> str:
    try:
        value = (ROOT / "tests/openwrt" / filename).read_text(encoding="ascii").strip()
    except OSError as exc:
        fail(f"cannot read {filename}: {exc}")
    if not SHA_RE.fullmatch(value):
        fail(f"{filename} must contain a full source SHA")
    return value.lower()


def pinned_value(path: Path, pattern: str, label: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read {label}: {exc}")
    match = re.search(pattern, text, re.M)
    if not match:
        fail(f"cannot extract {label} from {path.relative_to(ROOT)}")
    return match.group(1).strip()


def default_provenance() -> dict[str, object]:
    runtime_make = ROOT / "package/z2k-runtime/Makefile"
    warp_make = ROOT / "package/z2k-warp-runtime/Makefile"
    adapter_api = ROOT / "package/openwrt/ADAPTER_API"
    try:
        adapter_api_value = next(
            line.strip() for line in adapter_api.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
    except (OSError, StopIteration) as exc:
        fail(f"cannot read adapter API version: {exc}")
    if not adapter_api_value.isdecimal():
        fail("package/openwrt/ADAPTER_API must contain a decimal integer")
    try:
        manifest_current = json.loads((ROOT / "UPDATES.json").read_text(encoding="utf-8")).get("current")
    except (OSError, json.JSONDecodeError, AttributeError):
        manifest_current = None
    return {
        "openwrt_release": "25.12.5",
        "target": "mediatek/filogic",
        "arch": "aarch64_cortex-a53",
        "upstream_payload_sha": baseline("BASELINE"),
        "warp_runtime_source_sha": baseline("WARP_RUNTIME_BASELINE"),
        "manifest_current": manifest_current,
        "runtime_tag": pinned_value(runtime_make, r"^Z2K_RT_TAG:=([^\s]+)", "zapret2 tag"),
        "adapter_api": adapter_api_value,
        "warp_runtime_package_version": pinned_value(warp_make, r"^PKG_VERSION:=([^\s]+)", "WARP package version"),
        "zapret2_package_version": pinned_value(runtime_make, r"^PKG_VERSION:=([^\s]+)", "zapret2 package version"),
    }


def load_provenance(dist: Path) -> dict[str, object]:
    path = dist / "provenance.json"
    if not path.exists():
        return default_provenance()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read builder provenance: {exc}")
    if not isinstance(data, dict) or data.get("production_release") is not True or data.get("ci_snapshot") is not False:
        fail("builder provenance must identify a non-snapshot production release")
    return data


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

    provenance = load_provenance(dist)
    if dist.joinpath("provenance.json").exists():
        if str(provenance.get("source_commit", "")).lower() != args.source_sha.lower():
            fail("builder provenance source commit does not match requested source SHA")
        if provenance.get("package_version") != args.version or str(provenance.get("package_release")) != "1":
            fail("builder provenance package identity does not match product version-r1")
    versions = {name: package_version_string(meta) for name, meta in sorted(metadata.items())}
    artifacts = [
        {
            "filename": path.name,
            "package": metadata[package_metadata(args.apk_tool, path)["name"]]["name"],
            "version": metadata[package_metadata(args.apk_tool, path)["name"]]["version"],
            "sha256": sha256(path),
            "size_bytes": path.stat().st_size,
        }
        for path in copied
    ]
    artifacts.append({
        "filename": index.name,
        "package": "apk-index",
        "version": None,
        "sha256": sha256(index),
        "size_bytes": index.stat().st_size,
    })
    manifest = {
        "product": "z2kOW",
        "version": args.version,
        "product_version": args.version,
        "tag": f"v{args.version}",
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
    checksum_files = sorted([*copied, index, manifest_path], key=lambda p: p.name)
    (output / "SHA256SUMS").write_text(
        "".join(f"{sha256(path)}  {path.name}\n" for path in checksum_files), encoding="ascii"
    )
    print(f"prepared={output}")
    print(f"version={args.version}")
    print(f"source_sha={args.source_sha.lower()}")


def expected_files(bundle: Path, final: bool) -> set[str]:
    apks = {p.name for p in bundle.glob("z2k-*.apk")}
    required = apks | {"packages.adb", "release-manifest.json", "SHA256SUMS", "RELEASE_NOTES.md"}
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
    actual_names = {p.name for p in bundle.iterdir() if p.is_file() and p.name not in {"SHA256SUMS", "RELEASE_NOTES.md", "SHA256SUMS.sig"}}
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
    files = sorted(p.name for p in bundle.iterdir() if p.is_file())
    required = expected_files(bundle, args.final)
    if set(files) != required:
        fail(f"bundle file set mismatch (expected={sorted(required)}, actual={files})")
    verify_checksums(bundle)

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
    if set(declared_apks) != {p.name for p in apk_paths} or "packages.adb" not in declared:
        fail("manifest artifact set does not cover the four APKs and packages.adb")
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
        "release-manifest.json", "z2k-feed.pem",
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

    checksum_names = sorted([*apk_names, "packages.adb", "release-manifest.json"])
    sums_path = bundle / "SHA256SUMS"
    sums_path.write_text("".join(f"{sha256(bundle / name)}  {name}\n" for name in checksum_names), encoding="ascii")
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
