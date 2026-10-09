#!/usr/bin/env python3
"""Создание единого воспроизводимого транспортного архива релиза OpenWrt."""

from __future__ import annotations

import argparse
import gzip
import os
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Iterator


_USER_DATA = (
    PurePosixPath("etc/z2k/config"),
    PurePosixPath("etc/z2k/state"),
    PurePosixPath("etc/z2k/conf"),
    PurePosixPath("etc/z2k/user-lists"),
    PurePosixPath("etc/z2k/webpanel"),
)
_LEGACY_APK_PATHS = (PurePosixPath("etc/apk"),)


def _under(path: PurePosixPath, parent: PurePosixPath) -> bool:
    return path == parent or parent in path.parents


def _relative(path: Path, root: Path) -> PurePosixPath:
    relative = PurePosixPath(path.relative_to(root).as_posix())
    text = relative.as_posix()
    if relative.is_absolute() or not relative.parts or any(p in ("", ".", "..") for p in relative.parts):
        raise ValueError(f"небезопасный подготовленный путь: {text}")
    if "\\" in text or any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in text):
        raise ValueError(f"непереносимый подготовленный путь: {text}")
    return relative


def _check_path(relative: PurePosixPath) -> None:
    if _under(relative, PurePosixPath("www")):
        raise ValueError(f"запрещённый путь LuCI/uhttpd: /{relative}")
    if relative == PurePosixPath("etc/config/uhttpd"):
        raise ValueError("запрещённый путь LuCI/uhttpd: /etc/config/uhttpd")
    if any(_under(relative, parent) for parent in _LEGACY_APK_PATHS):
        raise ValueError(f"запрещённый путь прежнего пакетного репозитория: /{relative}")
    if relative.as_posix().endswith(".apk") or relative.name == "packages.adb":
        raise ValueError(f"запрещённый артефакт прежнего пакетного репозитория в payload: /{relative}")


def _walk(root: Path) -> Iterator[tuple[Path, PurePosixPath]]:
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        base = Path(current)
        retained: list[str] = []
        for name in sorted(directories):
            source = base / name
            relative = _relative(source, root)
            _check_path(relative)
            if any(_under(relative, excluded) for excluded in _USER_DATA):
                continue
            if source.is_symlink():
                yield source, relative
            else:
                retained.append(name)
                yield source, relative
        directories[:] = retained
        for name in sorted(files):
            source = base / name
            relative = _relative(source, root)
            _check_path(relative)
            if any(_under(relative, excluded) for excluded in _USER_DATA):
                continue
            if source.is_symlink():
                yield source, relative
            else:
                yield source, relative


def _tar_info(relative: PurePosixPath, source: Path) -> tarfile.TarInfo:
    info = tarfile.TarInfo(relative.as_posix())
    mode = source.lstat().st_mode
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    info.mode = stat.S_IMODE(mode)
    if stat.S_ISDIR(mode):
        info.type = tarfile.DIRTYPE
        info.name += "/"
    elif stat.S_ISLNK(mode):
        target = os.readlink(source)
        if (
            target.startswith("/")
            or "\\" in target
            or "//" in target
            or any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in target)
        ):
            raise ValueError(f"небезопасная цель символической ссылки: {relative} -> {target}")
        normalized = PurePosixPath(relative.parent, target)
        depth = 0
        for part in normalized.parts:
            if part == "..":
                depth -= 1
                if depth < 0:
                    raise ValueError(f"небезопасная цель символической ссылки: {relative} -> {target}")
            elif part not in ("", "."):
                depth += 1
        info.type = tarfile.SYMTYPE
        info.linkname = target
    elif stat.S_ISREG(mode):
        info.type = tarfile.REGTYPE
        info.size = source.stat().st_size
    else:
        raise ValueError(f"неподдерживаемый тип подготовленного файла: {relative}")
    return info


def build_rootfs_bundle(staged_root: Path, output: Path) -> None:
    """Упаковка подготовленного полного rootfs без пакетного менеджера."""
    root = Path(staged_root).resolve()
    output = Path(output).resolve()
    if not root.is_dir():
        raise ValueError(f"подготовленный rootfs не существует: {root}")
    output.parent.mkdir(parents=True, exist_ok=True)
    entries = list(_walk(root))
    if not entries:
        raise ValueError("подготовленный rootfs пуст")

    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=output.name + ".", suffix=".tmp", delete=False) as raw:
        temporary = Path(raw.name)
    try:
        with temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for source, relative in sorted(entries, key=lambda item: item[1].as_posix()):
                        info = _tar_info(relative, source)
                        if stat.S_ISREG(source.lstat().st_mode):
                            with source.open("rb") as stream:
                                archive.addfile(info, stream)
                        else:
                            archive.addfile(info)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="корень подготовленной файловой системы")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        build_rootfs_bundle(args.root, args.output)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"архив rootfs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
