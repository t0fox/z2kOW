#!/usr/bin/env python3
"""Проверка и сборка Rust TG артефактов, созданных матрицей GitHub Actions."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CRATE = ROOT / "platform/openwrt/tg-proxy"
TABLE = ROOT / "platform/openwrt/tg-rust-targets.tsv"
BUILD_SCRIPT = ROOT / "scripts/openwrt/build_tg_ws_proxy.sh"
GROUP_VARIANTS = {
    "zig": {"arm64", "x86_64", "x86", "riscv64"},
    "arm": {"arm"},
    "mips": {"mips"},
    "mipsel": {"mipsel"},
}
_PIN_NAMES = (
    "_zig_version", "_zig_sha256", "_arm_toolchain_sha256",
    "_mips_be_toolchain_sha256", "_mips_le_toolchain_sha256", "_mips_toolchain",
)
_GLOBAL_KEYS = (
    "artifact_schema", "source_sha", "ci_run_id", "matrix_group",
    "cargo_lock_sha256", "rust_toolchain_sha256", "target_table_sha256",
    "build_script_sha256", "license_sha256", "toolchain_fingerprint", "stable_rustc",
    "mips_rust_toolchain", "release_profile", "zig_version", "zig_sha256", "arm_toolchain_sha256",
    "mips_be_toolchain_sha256", "mips_le_toolchain_sha256", "variants",
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_text(value: str) -> str:
    return hashlib.sha256((value + "\n").encode("utf-8")).hexdigest()


def _provenance(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"нет обычного файла PROVENANCE: {path}")
    result: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or "=" not in line:
            raise ValueError(f"неверная строка PROVENANCE {path}:{line_number}")
        key, value = line.split("=", 1)
        if not key or not value or key in result:
            raise ValueError(f"пустой или повторный ключ PROVENANCE {path}:{line_number}")
        result[key] = value
    return result


def _table() -> dict[str, tuple[str, str, str, str, str, str]]:
    result: dict[str, tuple[str, str, str, str, str, str]] = {}
    for line_number, line in enumerate(TABLE.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 10:
            raise ValueError(f"неверная строка таблицы ABI {TABLE}:{line_number}")
        _pattern, _family, variant, target, abi, linker, _zig_target, cpu, std, flags = fields
        value = (target, abi, linker, cpu, std, flags)
        if variant in result and result[variant] != value:
            raise ValueError(f"вариант {variant} имеет конфликтующие параметры в таблице ABI")
        result[variant] = value
    return result


def _channel() -> str:
    match = re.search(r'^\s*channel\s*=\s*"([^"]+)"\s*$', (CRATE / "rust-toolchain.toml").read_text(encoding="utf-8"), re.M)
    if not match:
        raise ValueError("не удалось определить закреплённый stable Rust из rust-toolchain.toml")
    return match.group(1)


def _script_pins() -> dict[str, str]:
    source = BUILD_SCRIPT.read_text(encoding="utf-8")
    pins: dict[str, str] = {}
    for name in _PIN_NAMES:
        match = re.search(rf"^{re.escape(name)}=([^\s#]+)$", source, re.M)
        if not match:
            raise ValueError(f"в {BUILD_SCRIPT} отсутствует закреплённое значение {name}")
        pins[name] = match.group(1)
    return pins


def _expected_toolchain_fingerprint() -> str:
    values = _script_pins()
    ordered = (
        _channel(), values["_mips_toolchain"], values["_zig_version"],
        values["_zig_sha256"], values["_arm_toolchain_sha256"],
        values["_mips_be_toolchain_sha256"], values["_mips_le_toolchain_sha256"],
    )
    return _sha256_text("|".join(ordered))


def _expected_globals(source_sha: str) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("source SHA должен содержать 40 строчных шестнадцатеричных знаков")
    pins = _script_pins()
    return {
        "artifact_schema": "1",
        "source_sha": source_sha,
        "cargo_lock_sha256": _sha256(CRATE / "Cargo.lock"),
        "rust_toolchain_sha256": _sha256(CRATE / "rust-toolchain.toml"),
        "target_table_sha256": _sha256(TABLE),
        "build_script_sha256": _sha256(BUILD_SCRIPT),
        "license_sha256": _sha256(CRATE / "LICENSE"),
        "toolchain_fingerprint": _expected_toolchain_fingerprint(),
        "mips_rust_toolchain": pins["_mips_toolchain"],
        "release_profile": "strip=symbols,lto=true,codegen-units=1,panic=target-dependent",
        "zig_version": pins["_zig_version"],
        "zig_sha256": pins["_zig_sha256"],
        "arm_toolchain_sha256": pins["_arm_toolchain_sha256"],
        "mips_be_toolchain_sha256": pins["_mips_be_toolchain_sha256"],
        "mips_le_toolchain_sha256": pins["_mips_le_toolchain_sha256"],
    }


def _expected_variants(group: str) -> set[str]:
    rows = _table()
    if group not in GROUP_VARIANTS or not GROUP_VARIANTS[group] <= rows.keys():
        raise ValueError(f"группа Rust TG не совпадает с поддерживаемой ABI-матрицей: {group}")
    return GROUP_VARIANTS[group]


def _check_provenance(
    root: Path,
    provenance: dict[str, str],
    *,
    source_sha: str,
    run_id: str | None,
    group: str,
    expected_variants: set[str],
) -> None:
    missing = [key for key in _GLOBAL_KEYS if key not in provenance]
    if missing:
        raise ValueError(f"неполный PROVENANCE {root}: нет ключей {', '.join(missing)}")
    expected = _expected_globals(source_sha)
    for key, value in expected.items():
        if provenance[key] != value:
            label = "source SHA" if key == "source_sha" else key
            raise ValueError(f"PROVENANCE {root}: не совпадает {label}")
    if provenance["matrix_group"] != group:
        raise ValueError(f"PROVENANCE {root}: не совпадает матричная группа")
    fixed_fields = {
        "crate": "platform/openwrt/tg-proxy",
        "binary": "tg-ws-proxy",
        "upstream": "valnesfjord/tg-ws-proxy-rs@53c8bfe5e9efa561cf61a862c0371f1f8ba33869",
        "license": "MIT",
        "target_table": "platform/openwrt/tg-rust-targets.tsv",
    }
    for key, value in fixed_fields.items():
        if provenance.get(key) != value:
            raise ValueError(f"PROVENANCE {root}: не совпадает {key}")
    if run_id and provenance["ci_run_id"] != run_id:
        raise ValueError(f"PROVENANCE {root}: не совпадает Actions run ID")
    if not re.fullmatch(r"[0-9]+", provenance["ci_run_id"]):
        raise ValueError(f"PROVENANCE {root}: неверный Actions run ID")
    channel = _channel()
    pins = _script_pins()
    if not provenance["stable_rustc"].startswith(f"rustc {channel} "):
        raise ValueError(f"PROVENANCE {root}: Rust stable не совпадает с rust-toolchain.toml")
    variant_names = set(filter(None, provenance["variants"].split(",")))
    if variant_names != expected_variants:
        raise ValueError(f"PROVENANCE {root}: варианты не совпадают с группой {group}")
    rows = _table()
    expected_entries = {"LICENSE", "PROVENANCE", *(f"linux-{name}" for name in expected_variants)}
    actual_entries = {entry.name for entry in root.iterdir()}
    if actual_entries != expected_entries:
        raise ValueError(f"артефакт {root}: содержимое не совпадает с ожидаемым набором ABI")
    if (root / "LICENSE").is_symlink() or not (root / "LICENSE").is_file():
        raise ValueError(f"нет обычного файла LICENSE: {root}")
    if _sha256(root / "LICENSE") != provenance["license_sha256"]:
        raise ValueError(f"артефакт {root}: SHA-256 LICENSE не совпадает")
    for variant in sorted(expected_variants):
        target, abi, linker, cpu, std, flags = rows[variant]
        expected_fields = {
            f"target_{variant}": target,
            f"abi_{variant}": abi,
            f"linker_{variant}": linker,
            f"cpu_{variant}": cpu,
            f"std_{variant}": std,
            f"flags_{variant}": flags,
            f"toolchain_{variant}": pins["_mips_toolchain"] if std == "build-std" else channel,
        }
        for key, value in expected_fields.items():
            if provenance.get(key) != value:
                raise ValueError(f"PROVENANCE {root}: {key} не совпадает с ABI-таблицей")
        rustc_version = provenance.get(f"rustc_{variant}", "")
        if std == "build-std":
            if not re.fullmatch(
                r"rustc \d+\.\d+\.\d+-nightly \([0-9a-f]+ \d{4}-\d{2}-\d{2}\)",
                rustc_version,
            ):
                raise ValueError(f"PROVENANCE {root}: MIPS Rust nightly для {variant} не совпадает с pin")
        elif not rustc_version.startswith(f"rustc {channel} "):
            raise ValueError(f"PROVENANCE {root}: Rust toolchain для {variant} не совпадает с ABI-таблицей")
        directory = root / f"linux-{variant}"
        binary = directory / "tg-ws-proxy"
        if directory.is_symlink() or not directory.is_dir() or {p.name for p in directory.iterdir()} != {"tg-ws-proxy"}:
            raise ValueError(f"артефакт {root}: неверная раскладка linux-{variant}")
        if binary.is_symlink() or not binary.is_file():
            raise ValueError(f"артефакт {root}: нет обычного ELF linux-{variant}/tg-ws-proxy")
        digest = provenance.get(f"binary_sha256_{variant}", "")
        if not re.fullmatch(r"[0-9a-f]{64}", digest) or _sha256(binary) != digest:
            raise ValueError(f"артефакт {root}: SHA-256 ELF linux-{variant} не совпадает")


def verify_merged(directory: Path, *, source_sha: str, run_id: str | None = None) -> None:
    if directory.is_symlink():
        raise ValueError(f"каталог проверенных Rust TG артефактов не должен быть ссылкой: {directory}")
    directory = directory.resolve()
    if not directory.is_dir():
        raise ValueError(f"нет каталога проверенных Rust TG артефактов: {directory}")
    rows = _table()
    if set(rows) != set().union(*GROUP_VARIANTS.values()):
        raise ValueError("группы сборки не покрывают точную ABI-матрицу")
    provenance = _provenance(directory / "PROVENANCE")
    _check_provenance(
        directory, provenance, source_sha=source_sha, run_id=run_id,
        group="merged", expected_variants=set(rows),
    )
    if {entry.name for entry in directory.iterdir()} != {
        "LICENSE", "PROVENANCE", *(f"linux-{variant}" for variant in rows),
    }:
        raise ValueError("объединённый Rust TG набор содержит лишние или отсутствующие пути")
    for variant in rows:
        binary = directory / f"linux-{variant}" / "tg-ws-proxy"
        if not binary.stat().st_mode & 0o111:
            raise ValueError(f"ELF linux-{variant} после объединения не исполняемый")


def merge_artifacts(artifact_root: Path, output: Path, *, source_sha: str, run_id: str) -> None:
    if artifact_root.is_symlink():
        raise ValueError(f"каталог Actions артефактов не должен быть ссылкой: {artifact_root}")
    if output.is_symlink():
        raise ValueError(f"каталог объединения не должен быть ссылкой: {output}")
    artifact_root = artifact_root.resolve()
    output = output.resolve()
    if not artifact_root.is_dir():
        raise ValueError(f"нет каталога Actions артефактов: {artifact_root}")
    if output.exists():
        raise ValueError(f"каталог объединения уже существует: {output}")
    groups = {
        group: artifact_root / f"z2kow-tg-rust-{source_sha}-{group}"
        for group in GROUP_VARIANTS
    }
    missing = [str(path) for path in groups.values() if not path.is_dir() or path.is_symlink()]
    actual = {entry.name for entry in artifact_root.iterdir()}
    expected = {path.name for path in groups.values()}
    if missing or actual != expected:
        raise ValueError(f"неполный набор групп Rust TG артефактов: отсутствуют {missing}; лишние {sorted(actual - expected)}")

    shared: dict[str, str] | None = None
    provenance_by_variant: dict[str, str] = {}
    reference_license: bytes | None = None
    for group, directory in groups.items():
        provenance = _provenance(directory / "PROVENANCE")
        variants = _expected_variants(group)
        _check_provenance(
            directory, provenance, source_sha=source_sha, run_id=run_id,
            group=group, expected_variants=variants,
        )
        if shared is None:
            shared = {key: provenance[key] for key in _GLOBAL_KEYS if key not in {"matrix_group", "variants"}}
        else:
            for key, value in shared.items():
                if provenance.get(key) != value:
                    raise ValueError(f"группы Rust TG имеют разные входные данные: {key}")
        license_data = (directory / "LICENSE").read_bytes()
        if reference_license is None:
            reference_license = license_data
        elif license_data != reference_license:
            raise ValueError("LICENSE Rust TG расходится между группами")
        for variant in variants:
            for suffix in ("target", "abi", "linker", "cpu", "std", "flags", "toolchain", "rustc", "binary_sha256"):
                provenance_by_variant[f"{suffix}_{variant}"] = provenance[f"{suffix}_{variant}"]

    if shared is None or reference_license is None:
        raise ValueError("не собран ни один Rust TG артефакт")
    expected_variants = set(_table())
    if set().union(*GROUP_VARIANTS.values()) != expected_variants:
        raise ValueError("группы сборки не покрывают точную ABI-матрицу")
    combined = dict(shared)
    combined["matrix_group"] = "merged"
    combined["variants"] = ",".join(sorted(expected_variants))
    combined.update(provenance_by_variant)
    combined["artifact_groups"] = ",".join(sorted(GROUP_VARIANTS))
    rows = _table()
    combined.update({
        "crate": "platform/openwrt/tg-proxy",
        "binary": "tg-ws-proxy",
        "upstream": "valnesfjord/tg-ws-proxy-rs@53c8bfe5e9efa561cf61a862c0371f1f8ba33869",
        "license": "MIT",
        "target_table": "platform/openwrt/tg-rust-targets.tsv",
        "targets": ",".join(dict.fromkeys(row[0] for row in rows.values())),
        "armv5_openwrt_toolchain_sha256": combined["arm_toolchain_sha256"],
    })

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        (temporary / "LICENSE").write_bytes(reference_license)
        for group, directory in groups.items():
            for variant in GROUP_VARIANTS[group]:
                destination = temporary / f"linux-{variant}"
                shutil.copytree(directory / f"linux-{variant}", destination)
                binary = destination / "tg-ws-proxy"
                binary.chmod(0o755)
        (temporary / "PROVENANCE").write_text(
            "".join(f"{key}={value}\n" for key, value in sorted(combined.items())),
            encoding="utf-8",
        )
        verify_merged(temporary, source_sha=source_sha, run_id=run_id)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    merge = commands.add_parser("merge", help="проверить группы и объединить семь ABI")
    merge.add_argument("--artifacts", type=Path, required=True)
    merge.add_argument("--output", type=Path, required=True)
    merge.add_argument("--source-sha", required=True)
    merge.add_argument("--run-id", required=True)
    verify = commands.add_parser("verify", help="проверить объединённый набор Rust TG")
    verify.add_argument("--directory", type=Path, required=True)
    verify.add_argument("--source-sha", required=True)
    verify.add_argument("--run-id")
    args = parser.parse_args(argv)
    try:
        if args.command == "merge":
            merge_artifacts(args.artifacts, args.output, source_sha=args.source_sha, run_id=args.run_id)
        else:
            verify_merged(args.directory, source_sha=args.source_sha, run_id=args.run_id)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Rust TG артефакты: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
