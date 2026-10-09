from __future__ import annotations

import importlib.util
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "openwrt" / "rootfs_bundle.py"
SPEC = importlib.util.spec_from_file_location("rootfs_bundle", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class PayloadBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.stage = self.root / "rootfs"
        self.stage.mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def add(self, relative: str, data: bytes = b"payload") -> None:
        target = self.stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def build(self, name: str = "openwrt-rootfs.tar.gz") -> Path:
        output = self.root / name
        MODULE.build_rootfs_bundle(self.stage, output)
        return output

    def test_bundle_is_deterministic_and_built_from_staged_rootfs(self) -> None:
        self.add("usr/lib/z2k/platform/openwrt/update.sh", b"#!/bin/sh\n")
        (self.stage / "usr/lib/z2k/platform/openwrt/update.sh").chmod(0o755)
        self.add("etc/init.d/z2k", b"#!/bin/sh\n")
        self.add("opt/zapret2/nfq2/nfqws2", b"ELF fixture")
        self.add("etc/z2k/config", b"user config")
        self.add("etc/z2k/state/installed-release", b"user state")
        self.add("etc/z2k/conf/strategies.conf", b"user strategies")

        first = self.build("one.tar.gz")
        second = self.build("two.tar.gz")

        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first, "r:gz") as bundle:
            members = {member.name: member for member in bundle.getmembers()}
            names = set(members)
        self.assertIn("usr/lib/z2k/platform/openwrt/update.sh", names)
        self.assertEqual(0o755, members["usr/lib/z2k/platform/openwrt/update.sh"].mode)
        self.assertIn("etc/init.d/z2k", names)
        self.assertIn("opt/zapret2/nfq2/nfqws2", names)
        self.assertNotIn("etc/z2k/config", names)
        self.assertNotIn("etc/z2k/state/installed-release", names)
        self.assertNotIn("etc/z2k/conf/strategies.conf", names)
        self.assertFalse(any(name.endswith(".apk") for name in names))
        self.assertTrue(all(not name.startswith("/") and ".." not in Path(name).parts for name in names))

    def test_rejects_luci_and_uhttpd_paths(self) -> None:
        for path in ("www/cgi-bin/luci", "www/luci-static/luci.js", "etc/config/uhttpd"):
            with self.subTest(path=path):
                self.add(path, b"must never ship")
                with self.assertRaisesRegex(ValueError, "запрещённый путь LuCI/uhttpd"):
                    self.build()
                (self.stage / path).unlink()

    def test_rejects_legacy_component_apk_and_feed_paths(self) -> None:
        for path in (
            "tmp/z2k-adapter-1.apk",
            "etc/apk/repositories.d/z2kow.list",
            "etc/apk/keys/z2k-feed.pem",
            "etc/opkg/customfeeds.conf",
        ):
            with self.subTest(path=path):
                self.add(path, b"legacy installation infrastructure")
                with self.assertRaisesRegex(ValueError, "запрещённый"):
                    self.build()
                (self.stage / path).unlink()

    def test_rejects_unsafe_symlink_target(self) -> None:
        link = self.stage / "usr/lib/z2k/escape"
        link.parent.mkdir(parents=True)
        try:
            link.symlink_to("../../../../etc/passwd")
        except OSError as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "небезопасная цель символической ссылки"):
            self.build()

    def test_rejects_symlink_target_with_whitespace(self) -> None:
        link = self.stage / "usr/lib/z2k/link"
        link.parent.mkdir(parents=True)
        try:
            link.symlink_to("target file")
        except OSError as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "небезопасная цель символической ссылки"):
            self.build()

    def test_rejects_symlink_target_with_repeated_separator(self) -> None:
        link = self.stage / "usr/lib/z2k/link"
        link.parent.mkdir(parents=True)
        try:
            link.symlink_to("target//file")
        except OSError as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "небезопасная цель символической ссылки"):
            self.build()


if __name__ == "__main__":
    unittest.main()
