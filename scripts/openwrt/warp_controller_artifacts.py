#!/usr/bin/env python3
"""Проверка и объединение Rust WARP ELF из матрицы GitHub Actions."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CRATE = ROOT / "platform/openwrt/warp-controller"
TABLE = CRATE / "rust-targets.tsv"
BUILD = ROOT / "scripts/openwrt/build_warp_controller.sh"
GROUPS = {
    "zig": {"arm64", "x86_64", "x86", "riscv64"},
    "arm": {"arm"},
    "mips": {"mips"},
    "mipsel": {"mipsel"},
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def targets() -> dict[str, tuple[str, str, str, str, str]]:
    result = {}
    for number, line in enumerate(TABLE.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        row = line.split()
        if len(row) != 6 or row[0] in result:
            raise ValueError(f"неверная или повторная запись Rust ABI {TABLE}:{number}")
        result[row[0]] = tuple(row[1:])
    return result


def provenance(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"нет обычного PROVENANCE: {path}")
    result = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or "=" not in line:
            raise ValueError(f"неверная строка PROVENANCE {path}:{number}")
        key, value = line.split("=", 1)
        if not key or not value or key in result:
            raise ValueError(f"пустой или повторный ключ PROVENANCE {path}:{number}")
        result[key] = value
    return result


def expected(source_sha: str, run_id: str | None) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("source SHA должен содержать 40 строчных шестнадцатеричных знаков")
    source = BUILD.read_text(encoding="utf-8")
    pins = {}
    for key in ("_stable", "_zig_version", "_zig_sha256", "_arm_sha256", "_mips_be_sha256", "_mips_le_sha256", "_mips_toolchain"):
        match = re.search(rf"^{key}=([^\s#]+)$", source, re.M)
        if not match:
            raise ValueError(f"в {BUILD} отсутствует закреплённое значение {key}")
        pins[key] = match.group(1)
    return {
        "artifact_schema": "1",
        "source_sha": source_sha,
        "ci_run_id": run_id or "0",
        "crate": "platform/openwrt/warp-controller",
        "binary": "z2k-warp-controller",
        "cargo_lock_sha256": digest(CRATE / "Cargo.lock"),
        "target_table_sha256": digest(TABLE),
        "build_script_sha256": digest(BUILD),
        "stable_rustc_prefix": f"rustc {pins['_stable']} ",
        "mips_rust_toolchain": pins["_mips_toolchain"],
        "zig_version": pins["_zig_version"],
        "zig_sha256": pins["_zig_sha256"],
        "arm_toolchain_sha256": pins["_arm_sha256"],
        "mips_be_toolchain_sha256": pins["_mips_be_sha256"],
        "mips_le_toolchain_sha256": pins["_mips_le_sha256"],
        "release_profile": "strip=symbols,lto=true,codegen-units=1,panic=abort",
    }


def verify(directory: Path, *, source_sha: str, run_id: str | None = None, group: str | None = None) -> dict[str, str]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"каталог Rust WARP артефактов отсутствует или является ссылкой: {directory}")
    meta = provenance(directory / "PROVENANCE")
    expected_meta = expected(source_sha, run_id)
    for key, value in expected_meta.items():
        if key == "stable_rustc_prefix":
            actual = meta.get("stable_rustc", "")
            if not actual.startswith(value):
                raise ValueError("PROVENANCE: версия Rust stable не совпадает")
        elif meta.get(key, "") != value:
            if key == "ci_run_id":
                raise ValueError("PROVENANCE: Actions run ID не совпадает")
            raise ValueError(f"PROVENANCE: не совпадает {key}")
    if not re.fullmatch(r"[0-9]+", meta.get("ci_run_id", "")):
        raise ValueError("PROVENANCE: неверный Actions run ID")

    table = targets()
    variants = set(filter(None, meta.get("variants", "").split(",")))
    allowed = GROUPS.get(group, set(table)) if group else set(table)
    if not variants or variants != allowed:
        raise ValueError("PROVENANCE: варианты не совпадают с ожидаемой группой ABI")
    if group and meta.get("matrix_group") != group:
        raise ValueError("PROVENANCE: не совпадает матричная группа")
    if not group and meta.get("matrix_group") != "merged":
        raise ValueError("PROVENANCE: набор не помечен как merged")
    if not group and variants != set(table):
        raise ValueError("PROVENANCE: объединённый набор не покрывает всю ABI-матрицу")
    if not group and meta.get("artifact_groups") != ",".join(sorted(GROUPS)):
        raise ValueError("PROVENANCE: объединённый набор не покрывает все матричные группы")

    expected_entries = {"PROVENANCE", *(f"linux-{variant}" for variant in variants)}
    if {entry.name for entry in directory.iterdir()} != expected_entries:
        raise ValueError("Rust WARP artifact содержит лишние или отсутствующие пути")
    for variant in variants:
        target, linker, zig_target, cpu, std = table[variant]
        expected_fields = {
            f"target_{variant}": target,
            f"linker_{variant}": linker,
            f"zig_target_{variant}": zig_target,
            f"cpu_{variant}": cpu,
            f"std_{variant}": std,
            f"toolchain_{variant}": meta["mips_rust_toolchain"] if std == "build-std" else meta["stable_rustc"].split()[1],
        }
        for key, value in expected_fields.items():
            if meta.get(key) != value:
                raise ValueError(f"PROVENANCE: {key} не совпадает с таблицей ABI")
        arch_dir = directory / f"linux-{variant}"
        binary = arch_dir / "z2k-warp-controller"
        if arch_dir.is_symlink() or not arch_dir.is_dir() or {entry.name for entry in arch_dir.iterdir()} != {binary.name}:
            raise ValueError(f"неверная раскладка linux-{variant}")
        if binary.is_symlink() or not binary.is_file() or not binary.stat().st_mode & 0o111:
            raise ValueError(f"ELF linux-{variant} отсутствует или не исполняемый")
        if digest(binary) != meta.get(f"binary_sha256_{variant}"):
            raise ValueError(f"SHA-256 ELF linux-{variant} не совпадает")
    return meta


def merge(artifact_root: Path, output: Path, *, source_sha: str, run_id: str) -> None:
    if artifact_root.is_symlink() or not artifact_root.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("каталоги Actions артефактов/результата отсутствуют, повторяются или являются ссылками")
    groups = {name: artifact_root / f"z2kow-warp-controller-{source_sha}-{name}" for name in GROUPS}
    if {entry.name for entry in artifact_root.iterdir()} != {path.name for path in groups.values()}:
        raise ValueError("набор Actions WARP артефактов неполон или содержит лишние группы")
    shared = None
    records = {}
    for name, directory in groups.items():
        meta = verify(directory, source_sha=source_sha, run_id=run_id, group=name)
        if set(meta["variants"].split(",")) != GROUPS[name]:
            raise ValueError(f"матрица WARP группы {name} неполна")
        per_variant = {
            f"{prefix}_{variant}"
            for variant in targets()
            for prefix in ("target", "linker", "zig_target", "cpu", "std", "toolchain", "binary_sha256")
        }
        values = {key: value for key, value in meta.items() if key not in per_variant | {"matrix_group", "variants"}}
        if shared is None:
            shared = values
        elif values != shared:
            raise ValueError("WARP группы собраны из разных исходников или toolchain")
        for variant in GROUPS[name]:
            for prefix in ("target", "linker", "zig_target", "cpu", "std", "toolchain", "binary_sha256"):
                records[f"{prefix}_{variant}"] = meta[f"{prefix}_{variant}"]

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        for name, directory in groups.items():
            for variant in GROUPS[name]:
                shutil.copytree(directory / f"linux-{variant}", temporary / f"linux-{variant}")
        merged = dict(shared or {})
        merged.update(records)
        merged["matrix_group"] = "merged"
        merged["variants"] = ",".join(sorted(targets()))
        merged["artifact_groups"] = ",".join(sorted(GROUPS))
        (temporary / "PROVENANCE").write_text("".join(f"{key}={value}\n" for key, value in sorted(merged.items())), encoding="utf-8")
        verify(temporary, source_sha=source_sha, run_id=run_id)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    merge_parser = sub.add_parser("merge")
    merge_parser.add_argument("--artifacts", type=Path, required=True)
    merge_parser.add_argument("--output", type=Path, required=True)
    merge_parser.add_argument("--source-sha", required=True)
    merge_parser.add_argument("--run-id", required=True)
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--directory", type=Path, required=True)
    verify_parser.add_argument("--source-sha", required=True)
    verify_parser.add_argument("--run-id")
    verify_parser.add_argument("--group", choices=sorted(GROUPS))
    args = parser.parse_args()
    if args.command == "merge":
        merge(args.artifacts, args.output, source_sha=args.source_sha, run_id=args.run_id)
        print(f"объединены WARP ELF: {args.output}")
    else:
        verify(args.directory, source_sha=args.source_sha, run_id=args.run_id, group=args.group)
        print(f"проверен WARP ELF payload: {args.directory}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        raise SystemExit(f"Rust WARP артефакты: {exc}") from exc
