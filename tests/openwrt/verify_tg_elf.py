#!/usr/bin/env python3
"""Проверить ELF/ABI каждого локального Rust TG артефакта."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "platform" / "openwrt" / "tg-rust-targets.tsv"


def _read_table() -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for line_number, line in enumerate(TABLE.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 10:
            raise ValueError(f"неверная строка таблицы ABI {TABLE}:{line_number}")
        _pattern, _family, output, target, abi, *_rest = fields
        current = (target, abi)
        if output in result and result[output] != current:
            raise ValueError(f"вариант {output} описан несовместимыми target/ABI")
        result[output] = current
    return result


def _header(readelf: str, binary: Path) -> str:
    result = subprocess.run([readelf, "-h", str(binary)], capture_output=True, text=True, check=True)
    return result.stdout


def verify(binary_root: Path, readelf: str = "readelf", variants: set[str] | None = None) -> None:
    expected = _read_table()
    if variants is not None:
        missing_from_table = variants - set(expected)
        if missing_from_table:
            raise ValueError(f"неизвестные ABI-варианты: {sorted(missing_from_table)}")
        expected = {name: value for name, value in expected.items() if name in variants}
    actual = {path.name.removeprefix("linux-") for path in binary_root.glob("linux-*") if path.is_dir()}
    if actual != set(expected):
        raise ValueError(f"каталоги ELF не совпали с ABI-таблицей: ожидаются {sorted(expected)}, найдены {sorted(actual)}")

    requirements = {
        "arm64": ("ELF64", "little endian", "AArch64"),
        "arm": ("ELF32", "little endian", "ARM", "soft-float ABI"),
        "x86_64": ("ELF64", "little endian", "Advanced Micro Devices X86-64"),
        "x86": ("ELF32", "little endian", "Intel 80386"),
        "mips": ("ELF32", "big endian", "MIPS", "o32"),
        "mipsel": ("ELF32", "little endian", "MIPS", "o32"),
        "riscv64": ("ELF64", "little endian", "RISC-V", "double-float ABI"),
    }
    for output, (target, abi) in expected.items():
        binary = binary_root / f"linux-{output}" / "tg-ws-proxy"
        if not binary.is_file() or not binary.stat().st_mode & 0o111:
            raise ValueError(f"нет исполняемого Rust TG бинарника для {output}: {binary}")
        header = _header(readelf, binary)
        if "INTERP" in subprocess.run([readelf, "-l", str(binary)], capture_output=True, text=True, check=True).stdout:
            raise ValueError(f"{binary} должен быть статическим и не иметь PT_INTERP")
        for required in requirements[output]:
            if required not in header:
                raise ValueError(f"{binary}: нет ELF-признака {required!r}; target={target}, ABI={abi}")
        if output == "arm" and "armv5te" not in target.lower():
            raise ValueError("ARM32 бинарник обязан использовать минимальный ISA ARMv5TE")
        if output == "x86" and (target != "i686-unknown-linux-musl" or "Pentium4" not in abi or "SSE2" not in abi):
            raise ValueError("32-битный x86 бинарник требует ISA Pentium 4 с SSE2")
        if output.startswith("mips"):
            if "mips32r2" not in header.lower() or "o32" not in header.lower() or "soft" not in abi.lower():
                raise ValueError(f"{binary}: ожидался MIPS32r2 O32 soft-float")
            attributes = subprocess.run([readelf, "-A", str(binary)], capture_output=True, text=True, check=True).stdout
            if "FP ABI: Soft float" not in attributes:
                raise ValueError(f"{binary}: ELF attributes не подтверждают MIPS soft-float")
        if output == "riscv64" and "RVC" not in header:
            raise ValueError(f"{binary}: ожидался Rust target RV64GC с compressed instructions")
        print(f"OK {output}: {target} ({abi})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary_root", type=Path)
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--variants", help="проверить только эти ABI-варианты, разделённые пробелом или запятой")
    args = parser.parse_args()
    try:
        variants = None
        if args.variants is not None:
            variants = set(args.variants.replace(",", " ").split())
            if not variants:
                raise ValueError("список ABI-вариантов пуст")
        verify(args.binary_root, args.readelf, variants)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
