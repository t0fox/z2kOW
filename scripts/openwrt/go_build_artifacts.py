#!/usr/bin/env python3
"""Проверяет Go ELF CI и переносит их в rootfs без повторной компиляции."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import sys
import tempfile
from functools import lru_cache
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "build-matrix.tsv"
MODULES = ("rt-proxy", "z2k-detect", "z2k-verify", "z2k-warpd")
ROOTFS_MODULES = ("rt-proxy", "z2k-detect", "z2k-warpd")
ROOTFS_ARCHES = ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
ARCH_BY_GOARCH = {
    "arm64": "arm64", "arm": "arm", "amd64": "x86_64", "386": "x86",
    "mips": "mips", "mipsle": "mipsel", "riscv64": "riscv64",
}
ELF_ABI = {
    "arm64": (2, 1, 183), "arm": (1, 1, 40), "amd64": (2, 1, 62),
    "386": (1, 1, 3), "mips": (1, 2, 8), "mipsle": (1, 1, 8),
    "mips64le": (2, 1, 8), "ppc64": (2, 2, 21), "riscv64": (2, 1, 243),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _matrix() -> dict[str, list[dict[str, str]]]:
    result = {module: [] for module in MODULES}
    for line_number, line in enumerate(MATRIX.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 7:
            raise ValueError(f"неверная строка Go build-matrix.tsv:{line_number}")
        module, package, build_dir, prefix, goarch, suffix, extra = fields
        if module not in result:
            raise ValueError(f"неизвестный Go-модуль в build-matrix.tsv:{line_number}")
        if goarch not in ELF_ABI:
            raise ValueError(f"неизвестный Go ABI {goarch} в build-matrix.tsv:{line_number}")
        if extra == "-":
            extra = ""
        result[module].append({
            "package": package, "build_dir": build_dir, "prefix": prefix,
            "goarch": goarch, "suffix": suffix, "extra": extra,
            "filename": f"{prefix}-linux-{suffix}",
        })
    if any(not rows for rows in result.values()):
        raise ValueError("Go build matrix не покрывает все четыре модуля")
    for module, rows in result.items():
        names = [row["filename"] for row in rows]
        if len(names) != len(set(names)):
            raise ValueError(f"Go build matrix повторяет имя бинарника для {module}")
    return result


@lru_cache(maxsize=None)
def _module_tree_sha256(module: str) -> str:
    directory = ROOT / module
    digest = hashlib.sha256()
    files = sorted(
        path for path in directory.rglob("*")
        if path.is_file() and not path.is_symlink()
        and not ({".git", "builds", "target", "vendor"} & set(path.relative_to(directory).parts))
    )
    for path in files:
        relative = path.relative_to(directory).as_posix().encode("utf-8")
        digest.update(relative + b"\0")
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def _descriptor(module: str, row: dict[str, str], release_tag: str) -> dict[str, object]:
    is_warpd = module == "z2k-warpd"
    return {
        "package": row["package"],
        "goarch": row["goarch"],
        "abi_flags": row["extra"],
        "cgo_enabled": 0,
        "goos": "linux",
        "trimpath": True,
        "buildvcs": False,
        "tags": ["openwrt"] if is_warpd else [],
        "overlay": "openwrt-overlay/overlay.json" if is_warpd else "",
        "ldflags": "-s -w -X main.version=" + release_tag if is_warpd else "-s -w",
    }


def _check_elf(path: Path, goarch: str) -> None:
    try:
        with path.open("rb") as stream:
            header = stream.read(20)
    except OSError as error:
        raise ValueError(f"не удалось прочитать Go ELF {path}: {error}") from error
    expected = ELF_ABI[goarch]
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise ValueError(f"артефакт не является ELF: {path}")
    elf_class, endian = header[4], header[5]
    if endian not in (1, 2):
        raise ValueError(f"неверный ELF endian: {path}")
    byte_order = "<" if endian == 1 else ">"
    machine = struct.unpack(byte_order + "H", header[18:20])[0]
    if (elf_class, endian, machine) != expected:
        raise ValueError(
            f"неверный ELF ABI {path}: class={elf_class}, endian={endian}, machine={machine}; "
            f"ожидалось {expected} для GOARCH={goarch}"
        )


def _validate_inputs(source_sha: str, run_id: str, go_version: str, release_tag: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("source SHA должен содержать 40 строчных hex-знаков")
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("GitHub Actions run ID неверен")
    if not go_version.startswith("go version go1.25.13 "):
        raise ValueError(f"неожиданный Go toolchain: {go_version}")
    if not re.fullmatch(r"[pr]-[0-9]+(?:\.[0-9]+)+", release_tag):
        raise ValueError("release tag неверен")


def _expected_provenance(module: str, source_sha: str, run_id: str, go_version: str, release_tag: str) -> dict[str, object]:
    return {
        "schema": 1,
        "source_sha": source_sha,
        "run_id": run_id,
        "module": module,
        "go_version": go_version,
        "build_matrix_sha256": _sha256(MATRIX),
        "module_tree_sha256": _module_tree_sha256(module),
        "release_tag": release_tag,
        "builds": {
            row["filename"]: _descriptor(module, row, release_tag)
            for row in _matrix()[module]
        },
    }


def attest(directory: Path, *, module: str, source_sha: str, run_id: str, go_version: str, release_tag: str) -> None:
    _validate_inputs(source_sha, run_id, go_version, release_tag)
    if module not in MODULES or directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"неверный Go artifact directory/module: {directory} ({module})")
    expected = _expected_provenance(module, source_sha, run_id, go_version, release_tag)
    records: dict[str, dict[str, object]] = {}
    for name, descriptor in expected["builds"].items():
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Go cross-build не создал обычный ELF {path}")
        _check_elf(path, str(descriptor["goarch"]))
        records[name] = {"sha256": _sha256(path), "size_bytes": path.stat().st_size}
    actual_names = {entry.name for entry in directory.iterdir()}
    if actual_names != set(records):
        raise ValueError(f"лишние или отсутствующие Go ELF: {sorted(actual_names ^ set(records))}")
    expected["artifacts"] = records
    (directory / "PROVENANCE.json").write_text(
        json.dumps(expected, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def verify(directory: Path, *, module: str, source_sha: str, run_id: str, go_version: str, release_tag: str) -> None:
    _validate_inputs(source_sha, run_id, go_version, release_tag)
    if module not in MODULES or directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"неверный Go artifact directory/module: {directory} ({module})")
    provenance_path = directory / "PROVENANCE.json"
    if provenance_path.is_symlink() or not provenance_path.is_file():
        raise ValueError(f"в Go artifact отсутствует обычный PROVENANCE.json: {directory}")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    expected = _expected_provenance(module, source_sha, run_id, go_version, release_tag)
    for key, value in expected.items():
        if provenance.get(key) != value:
            labels = {
                "source_sha": "source SHA", "run_id": "Actions run ID",
                "go_version": "Go toolchain", "release_tag": "release tag",
                "build_matrix_sha256": "hash Go build matrix",
                "module_tree_sha256": "hash исходников модуля",
            }
            raise ValueError(f"Go artifact provenance не совпадает: {labels.get(key, key)}")
    expected_names = set(expected["builds"])
    artifacts = provenance.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != expected_names:
        raise ValueError(f"Go artifact provenance не перечисляет все ELF для {module}")
    if {entry.name for entry in directory.iterdir()} != expected_names | {"PROVENANCE.json"}:
        raise ValueError(f"Go artifact имеет лишние или отсутствующие файлы: {directory}")
    for name, descriptor in expected["builds"].items():
        path = directory / name
        record = artifacts[name]
        if path.is_symlink() or not path.is_file() or record != {
            "sha256": _sha256(path), "size_bytes": path.stat().st_size,
        }:
            raise ValueError(f"Go ELF не совпадает с SHA-256/размером provenance: {path}")
        _check_elf(path, str(descriptor["goarch"]))


def verify_all(artifact_root: Path, *, source_sha: str, run_id: str, go_version: str, release_tag: str) -> dict[str, Path]:
    if artifact_root.is_symlink() or not artifact_root.is_dir():
        raise ValueError(f"нет обычного каталога Go Actions artifacts: {artifact_root}")
    expected_dirs = {f"z2kow-go-{source_sha}-{module}" for module in MODULES}
    actual_dirs = {entry.name for entry in artifact_root.iterdir()}
    if actual_dirs != expected_dirs:
        raise ValueError(
            f"Go artifacts неполны: отсутствуют {sorted(expected_dirs - actual_dirs)}, "
            f"лишние {sorted(actual_dirs - expected_dirs)}"
        )
    verified: dict[str, Path] = {}
    for module in MODULES:
        directory = artifact_root / f"z2kow-go-{source_sha}-{module}"
        verify(directory, module=module, source_sha=source_sha, run_id=run_id,
               go_version=go_version, release_tag=release_tag)
        verified[module] = directory
    return verified


def stage_openwrt(artifact_root: Path, output: Path, *, source_sha: str, run_id: str, go_version: str, release_tag: str) -> None:
    verified = verify_all(artifact_root, source_sha=source_sha, run_id=run_id,
                          go_version=go_version, release_tag=release_tag)
    if output.is_symlink() or output.exists():
        raise ValueError(f"каталог rootfs Go ELF уже существует или является ссылкой: {output}")
    matrix = _matrix()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        for module in ROOTFS_MODULES:
            for arch in ROOTFS_ARCHES:
                goarch = next(key for key, value in ARCH_BY_GOARCH.items() if value == arch)
                rows = [row for row in matrix[module] if row["goarch"] == goarch]
                if not rows:
                    raise ValueError(f"Go build matrix не покрывает {module}/{arch}")
                canonical_suffix = {"amd64": "amd64", "386": "386", "mipsle": "mipsel"}.get(goarch, goarch)
                row = next((entry for entry in rows if entry["suffix"] == canonical_suffix), rows[0])
                source = verified[module] / row["filename"]
                destination = temporary / module / f"linux-{arch}" / row["prefix"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                destination.chmod(0o755)
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def compare_repository(artifact_root: Path, *, source_sha: str, run_id: str, go_version: str, release_tag: str) -> None:
    verified = verify_all(artifact_root, source_sha=source_sha, run_id=run_id,
                          go_version=go_version, release_tag=release_tag)
    failures = []
    for module in MODULES:
        if module == "z2k-warpd":
            continue  # OpenWrt runtime с overlay собирается отдельно от upstream binaries.
        for row in _matrix()[module]:
            source = verified[module] / row["filename"]
            committed = ROOT / row["build_dir"] / row["filename"]
            if not committed.is_file() or _sha256(source) != _sha256(committed):
                failures.append(f"{module}/{row['filename']}")
    if failures:
        raise ValueError("отгружаемые Go-бинарники отличаются от проверенной сборки: " + ", ".join(failures))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("attest", "verify"):
        item = sub.add_parser(command)
        item.add_argument("--directory", type=Path, required=True)
        item.add_argument("--module", choices=MODULES, required=True)
        item.add_argument("--source-sha", required=True)
        item.add_argument("--run-id", required=True)
        item.add_argument("--go-version", required=True)
        item.add_argument("--release-tag", required=True)
    for command in ("stage", "compare-repository"):
        item = sub.add_parser(command)
        item.add_argument("--artifacts", type=Path, required=True)
        item.add_argument("--source-sha", required=True)
        item.add_argument("--run-id", required=True)
        item.add_argument("--go-version", required=True)
        item.add_argument("--release-tag", required=True)
        if command == "stage":
            item.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "attest":
            attest(args.directory, module=args.module, source_sha=args.source_sha, run_id=args.run_id,
                   go_version=args.go_version, release_tag=args.release_tag)
        elif args.command == "verify":
            verify(args.directory, module=args.module, source_sha=args.source_sha, run_id=args.run_id,
                   go_version=args.go_version, release_tag=args.release_tag)
        elif args.command == "stage":
            stage_openwrt(args.artifacts, args.output, source_sha=args.source_sha, run_id=args.run_id,
                          go_version=args.go_version, release_tag=args.release_tag)
        else:
            compare_repository(args.artifacts, source_sha=args.source_sha, run_id=args.run_id,
                               go_version=args.go_version, release_tag=args.release_tag)
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, ValueError) as error:
        print(f"артефакт Go из CI: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
