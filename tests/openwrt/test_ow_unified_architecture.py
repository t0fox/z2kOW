#!/usr/bin/env python3
"""Regression gates for the single OpenWrt release/deployment architecture."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class UnifiedArchitectureTests(unittest.TestCase):
    def test_public_bootstrap_delegates_to_the_canonical_openwrt_installer(self) -> None:
        launcher = (ROOT / "z2kow.sh").read_text(encoding="utf-8")
        self.assertIn("scripts/openwrt/install.sh", launcher)
        self.assertNotIn("package/openwrt/keys", launcher)
        self.assertNotIn("z2k-feed.pem", launcher)
        self.assertNotIn("SHA256SUMS", launcher)
        self.assertIn('exec /usr/bin/z2kow "$@"', launcher)
        self.assertIn('INSTALLER="$TMP_DIR/install.sh"', launcher)
        self.assertIn('sh "$INSTALLER" "$@"', launcher)

    def test_production_bootstrap_accepts_technical_release_tags_independent_of_current(self) -> None:
        installer = (ROOT / "scripts/openwrt/install.sh").read_text(encoding="utf-8")
        manifest = (ROOT / "platform/openwrt/manifest.sh").read_text(encoding="utf-8")
        self.assertIn("openwrt-[0-9a-f]{40}", installer)
        self.assertIn("openwrt-[0-9a-f]{40}", manifest)
        self.assertNotIn('releases/download/$_tag/openwrt-rootfs.tar.gz', installer)
        self.assertNotIn('releases/download/$(z2k_ow_manifest_value "$1" current)', manifest)

    def test_legacy_component_package_and_provenance_authorities_are_gone(self) -> None:
        removed = (
            "package/openwrt/Makefile",
            "package/openwrt/make-seed.sh",
            "package/openwrt/ownership.map",
            "package/openwrt/ADAPTER_API",
            "package/openwrt/PANEL_API",
            "package/openwrt/z2k-feed-bootstrap.sh",
            "package/z2k-runtime/Makefile",
            "package/z2k-warp-runtime/Makefile",
            "scripts/openwrt/release-assets.py",
            "scripts/openwrt/package-version.sh",
            "scripts/openwrt/create-feed-key.ps1",
            "scripts/openwrt/write-provenance.sh",
            "UPSTREAM.json",
        )
        present = [path for path in removed if (ROOT / path).exists()]
        self.assertEqual(present, [], f"obsolete release infrastructure remains: {present}")

    def test_root_manifest_is_the_single_current_openwrt_release_authority(self) -> None:
        manifest = json.loads((ROOT / "UPDATES.json").read_text(encoding="utf-8"))
        expected_fields = {"schema", "branch", "platform", "seq", "current", "upstream", "history", "artifact"}
        if "signing" in manifest:
            expected_fields.add("signing")
        self.assertEqual(set(manifest), expected_fields)
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["branch"], "main")
        self.assertEqual(manifest["platform"], "openwrt")
        self.assertIsInstance(manifest["seq"], int)
        self.assertGreater(manifest["seq"], 0)
        self.assertRegex(manifest["current"], r"^[pr]-[0-9]+(?:\.[0-9]+)+$")
        self.assertEqual(manifest["upstream"]["repository"], "necronicle/z2k")
        self.assertEqual(manifest["upstream"]["branch"], "z2k-enhanced")
        self.assertEqual(manifest["upstream"]["tag"], manifest["current"])
        self.assertRegex(manifest["upstream"]["commit"], r"^[0-9a-f]{40}$")
        self.assertGreater(len(manifest["history"]), 0)
        self.assertEqual(manifest["history"][-1]["v"], manifest["current"])
        artifact = manifest["artifact"]
        self.assertEqual(set(artifact), {"filename", "url", "sha256", "size_bytes"})
        self.assertEqual(artifact["filename"], "openwrt-rootfs.tar.gz")
        self.assertRegex(
            artifact["url"],
            r"^https://github\.com/t0fox/z2kOW/releases/download/(?:openwrt-[0-9a-f]{40}|[pr]-[0-9]+(?:\.[0-9]+)+)/openwrt-rootfs\.tar\.gz$",
        )
        self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
        self.assertIsInstance(artifact["size_bytes"], int)
        self.assertGreater(artifact["size_bytes"], 0)
        history_versions = [record["v"] for record in manifest["history"]]
        self.assertEqual(len(history_versions), len(set(history_versions)))
        self.assertNotIn("seq", manifest["history"][-1], "keep upstream's per-entry history schema unchanged")
        if "signing" in manifest:
            self.assertRegex(manifest["signing"]["key_id"], r"^[0-9a-f]{64}$")
            self.assertTrue((ROOT / "UPDATES.json.sig").is_file(), "published manifest must have its detached signature")
        else:
            self.assertFalse((ROOT / "UPDATES.json.sig").exists(), "candidate remains unsigned until trusted signing")

    def test_owned_paths_are_disjoint_from_luci_and_uhttpd(self) -> None:
        paths = [
            line.strip()
            for line in (ROOT / "platform/openwrt/owned-paths.txt").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        protected = {
            "/www/cgi-bin/luci",
            "/www/luci-static",
            "/etc/config/uhttpd",
        }
        self.assertEqual(len(paths), len(set(paths)), "owned-path list contains duplicates")
        for path in paths:
            self.assertTrue(path.startswith("/"), f"owned path is not absolute: {path}")
            self.assertFalse(path == "/www" or path.startswith("/www/"), path)
            self.assertNotIn(path, protected)

    def test_candidate_and_ci_have_no_component_apk_build_or_secondary_manifest(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github/workflows/release-openwrt.yml").read_text(encoding="utf-8")
        publisher = (ROOT / "scripts/openwrt/publish_release.sh").read_text(encoding="utf-8")
        sync = (ROOT / ".github/workflows/sync-upstream.yml").read_text(encoding="utf-8")
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
        for text in (workflow, release, publisher, sync, builder):
            self.assertNotRegex(text, r"(?i)z2k-(?:adapter|webpanel|zapret2-runtime|warp-runtime).*\.apk")
            self.assertNotIn("openwrt-UPDATES.json", text)
        self.assertIn("stage-rootfs.sh", builder)
        self.assertIn("install_release.sh", (ROOT / "scripts/openwrt/stage-rootfs.sh").read_text(encoding="utf-8"))
        self.assertIn("mipsle:mipsel", builder)
        self.assertIn("arm64:arm64", builder)
        self.assertIn("openwrt-rootfs.tar.gz", builder)
        self.assertIn("copy_unsigned_candidate_manifest", builder)
        self.assertIn("openwrt-candidate/", workflow)
        self.assertIn("workflow_dispatch:", release)
        self.assertIn("openwrt-production", release)
        self.assertIn("sign_release.py", release)
        self.assertIn("gh release create", publisher)
        self.assertIn("gh release upload", publisher)
        self.assertIn("UPDATES.json.sig", release)
        self.assertNotIn("UPSTREAM.json", release)

    def test_openwrt_runtime_has_one_payload_update_path(self) -> None:
        runtime = (ROOT / "platform/openwrt/warp.sh").read_text(encoding="utf-8")
        release = (ROOT / "platform/openwrt/release.sh").read_text(encoding="utf-8")
        manifest = (ROOT / "platform/openwrt/manifest.sh").read_text(encoding="utf-8")
        openwrt_map = (ROOT / "lib/release_map.sh").read_text(encoding="utf-8")
        self.assertIn("z2k_ow_install_release", release)
        self.assertNotIn("z2k_ow_manifest_file_url", runtime + manifest)
        self.assertNotIn("z2k_ow_manifest_file_sha", runtime + manifest)
        self.assertNotIn("files/z2k-warp.sh", openwrt_map.split("_z2k_install_paths_openwrt()", 1)[1])
        env = (ROOT / "platform/openwrt/env.sh").read_text(encoding="utf-8")
        self.assertIn("https://raw.githubusercontent.com/t0fox/z2kOW/${Z2K_AU_BRANCH}", env)
        self.assertIn('Z2K_AU_BRANCH="${Z2K_AU_BRANCH:-main}"', env)

    def test_openwrt_upstream_apply_entry_routes_to_the_full_release_installer(self) -> None:
        updater = (ROOT / "lib/auto_update.sh").read_text(encoding="utf-8")
        apply_body = updater.split("au_run_apply() {", 1)[1].split("\n}", 1)[0]
        self.assertTrue('Z2K_PLATFORM:-keenetic' in apply_body, "au_run_apply must gate OpenWrt")
        self.assertTrue("platform/openwrt/update.sh" in apply_body, "OpenWrt must enter the canonical updater")
        self.assertTrue("exec" in apply_body, "the legacy patch/reinstall engine must not continue")

    def test_installed_release_state_contains_tag_and_upstream_seq_once(self) -> None:
        release = (ROOT / "platform/openwrt/release.sh").read_text(encoding="utf-8")
        updater = (ROOT / "platform/openwrt/update.sh").read_text(encoding="utf-8")
        panel = (ROOT / "platform/openwrt/webpanel.sh").read_text(encoding="utf-8")
        cli = (ROOT / "platform/openwrt/z2kow.sh").read_text(encoding="utf-8")
        reader = (ROOT / "platform/openwrt/release_state.sh").read_text(encoding="utf-8")
        self.assertTrue("z2k_ow_release_state_write()" in release, "installer needs one atomic state writer")
        self.assertTrue('printf \'tag=%s\\nseq=%s\\n\'' in release, "state must carry only tag and upstream seq")
        self.assertIn("z2k_ow_release_state_read", release, "installer must validate the same state format")
        self.assertIn("z2k_ow_release_state_read \"$STATE\"", updater,
                      "updater must refuse absent/corrupt state before comparing versions")
        self.assertNotIn("z2k_ow_release_state_write \"$STATE\"", updater,
                         "resync must not register an installation without full convergence")
        self.assertIn("z2k_ow_release_state_read", reader, "canonical parser is required")
        self.assertIn("z2k_ow_release_state_payload_tag", panel,
                      "WebPanel update checker must read the canonical tag accessor")
        self.assertIn("z2k_ow_release_state_read", reader,
                      "WebPanel status and CLI must share the strict canonical parser")
        self.assertIn("z2k_ow_release_state_read", cli, "CLI must read the same canonical record")

    def test_webpanel_cannot_bind_luci_ports_and_warp_scopes_selected_devices(self) -> None:
        panel = (ROOT / "platform/openwrt/webpanel.sh").read_text(encoding="utf-8")
        warp = (ROOT / "platform/openwrt/warp.sh").read_text(encoding="utf-8")
        ui = (ROOT / "webpanel/www/js/pages/warp.js").read_text(encoding="utf-8")
        self.assertTrue('80|443)' in panel, "panel must refuse the two LuCI listener ports")
        self.assertTrue("warp_devices_selected()" in warp, "selection intent must survive an offline client")
        self.assertTrue("warp_full_device_mode()" in warp, "p-86.13 full-device mode must be explicit")
        self.assertTrue("ip daddr != 192.168.0.0/16" in warp, "local LAN destinations must stay direct")
        self.assertTrue('ip saddr "@$WARP_SET_SRC" ip daddr "@$WARP_SET"' in warp,
                        "list mode must intersect selected devices with enabled destinations")
        self.assertNotIn('ip saddr "@$WARP_SET_SRC" meta mark set', warp,
                         "full-device mode must still exclude non-tunnel destinations")
        self.assertTrue("выбранным устройствам" in ui, "existing UI must retain list-scoping guidance")

    def test_bootstrap_and_payload_support_multiple_router_architectures(self) -> None:
        bootstrap = (ROOT / "scripts/openwrt/install.sh").read_text(encoding="utf-8")
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
        stage = (ROOT / "scripts/openwrt/stage-rootfs.sh").read_text(encoding="utf-8")
        self.assertNotIn("DISTRIB_ARCH:-}", bootstrap)
        self.assertNotIn("нужен OpenWrt 25.12", bootstrap)
        self.assertIn("apk add", bootstrap)
        self.assertIn("apk add", (ROOT / "platform/openwrt/release.sh").read_text(encoding="utf-8"))
        self.assertIn("mipsle:mipsel", builder)
        self.assertIn("arm64:arm64", builder)
        self.assertIn("riscv64:riscv64", builder)
        self.assertIn("runtime/binaries", stage)

    def test_full_payload_contains_arch_selected_runtime_and_diagnostic_binaries(self) -> None:
        builder = (ROOT / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
        stage = (ROOT / "scripts/openwrt/stage-rootfs.sh").read_text(encoding="utf-8")
        arch = (ROOT / "platform/openwrt/arch.sh").read_text(encoding="utf-8")
        self.assertIn("fetch_upstream_tg.py", builder, "TG binaries must come from the pinned upstream release")
        self.assertIn("rt-proxy", builder)
        self.assertIn("z2k-detect", builder)
        self.assertIn("RT_DIR", stage)
        self.assertIn("DETECT_DIR", stage)
        self.assertIn("usr/lib/z2k/bin/linux-$_arch/z2k-rt-proxy", stage)
        self.assertIn("usr/lib/z2k/bin/linux-$_arch/z2k-detect", stage)
        self.assertIn("DISTRIB_ARCH", arch)
        self.assertIn("z2k_ow_arch_bin_path", arch)

    def test_sync_job_checks_the_live_upstream_branch_frequently_without_pinning_a_tag(self) -> None:
        sync = (ROOT / ".github/workflows/sync-upstream.yml").read_text(encoding="utf-8")
        self.assertIn("*/15 * * * *", sync)
        self.assertIn("api.github.com/repos/necronicle/z2k/branches/z2k-enhanced", sync)
        self.assertIn("Cache-Control: no-cache", sync)
        self.assertIn("controlled_release.py check-upstream", sync)
        self.assertNotRegex(sync, r"\b[pr]-86\.\d+\b")
        self.assertIn("GITHUB_STEP_SUMMARY", sync)


if __name__ == "__main__":
    unittest.main()
