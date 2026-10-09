#!/usr/bin/env python3
"""Приёмка точного rootfs-кандидата через начальный установщик и движок релизов."""

from __future__ import annotations

import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]


def run(args: Sequence[str], env: dict[str, str], label: str, expected: bool = True) -> str:
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != expected:
        raise RuntimeError(f"{label}: код {result.returncode}\n{result.stdout}")
    print(f"ПРОЙДЕНО: {label}")
    return result.stdout


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass


class PanelHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - имя обработчика задано стандартной библиотекой
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"test panel ready\n")

    def log_message(self, _format: str, *_args: object) -> None:
        pass


def serve(directory: Path | None, handler: type[http.server.BaseHTTPRequestHandler]) -> tuple[http.server.ThreadingHTTPServer, threading.Thread]:
    if directory is not None:
        class CandidateHandler(QuietHandler):
            def __init__(self, *args: object, **kwargs: object) -> None:
                super().__init__(*args, directory=str(directory), **kwargs)

        actual_handler = CandidateHandler
    else:
        actual_handler = handler
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), actual_handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def check_state(path: Path, tag: str, seq: int, label: str) -> None:
    values = dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines() if "=" in line)
    if values != {"tag": tag, "seq": str(seq)}:
        raise RuntimeError(f"{label}: неверная запись состояния: {values!r}")


def main() -> int:
    if len(sys.argv) != 3:
        print("Использование: accept_release_candidate.py UPDATES.json openwrt-rootfs.tar.gz", file=sys.stderr)
        return 2
    manifest_source, artifact_source = map(Path, sys.argv[1:])
    manifest = json.loads(manifest_source.read_text(encoding="utf-8"))
    tag = str(manifest["current"])
    seq = int(manifest["seq"])
    if manifest.get("platform") != "openwrt" or manifest.get("artifact", {}).get("filename") != "openwrt-rootfs.tar.gz":
        raise RuntimeError("кандидат не является архивом полного релиза OpenWrt")
    artifact_data = artifact_source.read_bytes()
    original_manifest_hash = hashlib.sha256(manifest_source.read_bytes()).hexdigest()
    original_artifact_hash = hashlib.sha256(artifact_data).hexdigest()

    with tempfile.TemporaryDirectory(prefix="z2kow-candidate-acceptance-") as temp_name:
        work = Path(temp_name)
        served = work / "http"
        bin_dir = work / "bin"
        sysroot = work / "sysroot"
        bootstrap_tmp = work / "bootstrap-tmp"
        release_tmp = work / "release-tmp"
        for directory in (
            served,
            bin_dir,
            sysroot / "usr/lib",
            sysroot / "usr/bin",
            sysroot / "usr/sbin",
            sysroot / "etc/z2k/state",
            sysroot / "etc/config",
            sysroot / "etc/init.d",
            sysroot / "www/cgi-bin",
            bootstrap_tmp,
            release_tmp,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        key = work / "acceptance.key"
        pubkey = work / "acceptance.pub"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(pubkey)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        public_der = subprocess.run(["openssl", "pkey", "-pubin", "-in", str(pubkey), "-outform", "DER"], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        test_key_id = hashlib.sha256(public_der).hexdigest()

        # Использовать утилиты роутера, если BusyBox доступен на проверочном хосте.
        busybox = os.environ.get("Z2K_TEST_BUSYBOX") or shutil.which("busybox")
        if busybox:
            for applet in ("awk", "tar", "xargs", "tr"):
                (bin_dir / applet).symlink_to(busybox)

        served_artifact = served / "openwrt-rootfs.tar.gz"
        served_artifact.write_bytes(artifact_data)
        manifest["signing"] = {"key_id": test_key_id}
        manifest["artifact"] = {
            "filename": "openwrt-rootfs.tar.gz",
            "url": "http://127.0.0.1/openwrt-rootfs.tar.gz",
            "sha256": hashlib.sha256(artifact_data).hexdigest(),
            "size_bytes": len(artifact_data),
        }
        (served / "UPDATES.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        httpd, http_thread = serve(served, QuietHandler)
        base_url = f"http://127.0.0.1:{httpd.server_port}"
        manifest["artifact"]["url"] = f"{base_url}/openwrt-rootfs.tar.gz"
        (served / "UPDATES.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        signature = served / "UPDATES.json.sig"
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-in", str(served / "UPDATES.json"), "-out", str(signature)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        panel, panel_thread = serve(None, PanelHandler)
        panel_url = f"http://127.0.0.1:{panel.server_port}/"

        write_executable(bin_dir / "id", '#!/bin/sh\n[ "${1:-}" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n')
        write_executable(bin_dir / "apk", '#!/bin/sh\ncase "${1:-}" in info) exit 1 ;; update|add|del) exit 0 ;; *) exit 2 ;; esac\n')
        write_executable(
            bin_dir / "jsonfilter",
            "#!/usr/bin/env python3\nimport json,sys\na=sys.argv[1:]; f=e=None\nwhile a:\n x=a.pop(0)\n if x=='-i': f=a.pop(0)\n elif x=='-e': e=a.pop(0).removeprefix('@.')\n else: raise SystemExit(2)\nv=json.load(open(f,encoding='utf-8'))\nfor k in e.split('.'): v=v[k]\nif v is not None: print(v)\n",
        )
        service_log = work / "service-calls.log"
        write_executable(
            work / "service-helper",
            '''#!/bin/sh
printf "%s|%s\\n" "$1" "$2" >> "$Z2K_TEST_SERVICE_LOG"
case "${2:-}" in
    enable)
        service=${1##*/}
        case "$service" in z2k) order=22 ;; z2k-webpanel) order=95 ;; *) exit 2 ;; esac
        mkdir -p "$Z2K_TEST_SYSROOT/etc/rc.d" || exit 1
        ln -sf "../init.d/$service" "$Z2K_TEST_SYSROOT/etc/rc.d/S$order$service" || exit 1
        ;;
    stop|start|restart|status|running) exit 0 ;;
    *) exit 2 ;;
esac
''',
        )
        write_executable(
            work / "http-probe",
            '#!/bin/sh\nif [ -n "${Z2K_TEST_FAIL_HTTP_PROBES:-}" ]; then\n n=$(cat "$Z2K_TEST_HTTP_COUNT" 2>/dev/null || echo 0)\n n=$((n + 1)); printf "%s\\n" "$n" > "$Z2K_TEST_HTTP_COUNT"\n [ "$n" -le "$Z2K_TEST_FAIL_HTTP_PROBES" ] && exit 1\nfi\nexec curl --fail --silent --show-error --connect-timeout 2 --max-time 4 -o /dev/null "$Z2K_TEST_PANEL_URL"\n',
        )
        release_file = work / "openwrt_release"
        release_file.write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.5'\nDISTRIB_ARCH='x86_64'\n", encoding="utf-8")
        (sysroot / "etc/z2k/config").write_text("ENABLED=0\n# сохраняемый пользовательский параметр\n", encoding="utf-8")
        (sysroot / "etc/z2k/user-lists/custom.txt").parent.mkdir(parents=True, exist_ok=True)
        (sysroot / "etc/z2k/user-lists/custom.txt").write_text("user-domain.example\n", encoding="utf-8")
        (sysroot / "www/cgi-bin/luci").write_text("# точка входа LuCI должна сохраниться\n", encoding="utf-8")
        (sysroot / "etc/config/uhttpd").write_text("# конфигурация uhttpd должна сохраниться\n", encoding="utf-8")
        (release_tmp / "user-file.txt").write_text("не удалять соседние пользовательские данные\n", encoding="utf-8")

        env = os.environ.copy()
        for name in list(env):
            if name.startswith("Z2K_") or name.startswith("Z2KOW_"):
                env.pop(name, None)
        env.update(
            {
                "PATH": f"{bin_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TMPDIR": str(bootstrap_tmp),
                "Z2K_OPENWRT_RELEASE_FILE": str(release_file),
                "Z2K_OW_OPENWRT_RELEASE_FILE": str(release_file),
                "Z2KOW_MANIFEST_URL": f"{base_url}/UPDATES.json",
                "Z2KOW_TRUST_KEY": str(pubkey),
                "Z2K_OW_SYSROOT": str(sysroot),
                "Z2K_OW_INSTALL_TMP": str(release_tmp),
                "Z2K_OW_INSTALL_WORK": "/usr/lib/.z2k-install",
                "Z2K_OW_TESTING": "1",
                "Z2K_OW_TEST_HEALTHCHECK": "1",
                "Z2K_OW_TEST_SERVICE_HELPER": str(work / "service-helper"),
                "Z2K_OW_TEST_HTTP_PROBE": str(work / "http-probe"),
                "Z2K_TEST_SERVICE_LOG": str(service_log),
                "Z2K_TEST_SYSROOT": str(sysroot),
                "Z2K_TEST_PANEL_URL": panel_url,
                "Z2K_TEST_HTTP_COUNT": str(work / "http-probe-count"),
                "Z2K_TEST_FAIL_HTTP_PROBES": "",
            }
        )
        run(["sh", str(ROOT / "scripts/openwrt/install.sh")], env, "точный кандидат установлен через начальный установщик")
        state = sysroot / "etc/z2k/state/installed-release"
        check_state(state, tag, seq, "после свежей установки")

        def check_bootstrap(label: str) -> None:
            # Реальная инициализация payload выполняется в изолированном rootfs;
            # только службы и пакетный менеджер остаются заглушками.
            bootstrap_env = env.copy()
            bootstrap_env.update({
                "Z2K_ROOT": str(sysroot / "usr/lib/z2k"),
                "Z2K_ADAPTER_DIR": str(sysroot / "usr/lib/z2k/platform/openwrt"),
                "Z2K_ETC": str(sysroot / "etc/z2k"),
                "Z2K_TMP": str(sysroot / "tmp/z2k"),
                "Z2K_ZAPRET2_RUNTIME": str(sysroot / "opt/zapret2"),
                "Z2K_OW_LEGACY_DETECT_INIT": str(sysroot / "etc/init.d/z2k-detect"),
                "Z2K_OW_PROC_ROOT": str(sysroot / "proc"),
            })
            run(["sh", "-eu", "-c", '. "$Z2K_ADAPTER_DIR/paths.sh"; . "$Z2K_ADAPTER_DIR/bootstrap.sh"; z2k_ow_bootstrap'], bootstrap_env, label)
            for pair in ("nfq2/nfqws2", "ip2net/ip2net", "mdig/mdig"):
                link = sysroot / "opt/zapret2" / pair
                binary = sysroot / "opt/zapret2/binaries/linux-x86_64" / pair.split("/")[1]
                if not link.is_symlink() or not link.is_file() or not os.access(link, os.X_OK) or link.resolve() != binary.resolve():
                    raise RuntimeError(f"bootstrap создал неверную runtime-ссылку: {link}")

        check_bootstrap("настоящий bootstrap и runtime-ссылки после свежей установки")

        installed_binary = sysroot / "usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client"
        if not installed_binary.is_file() or not os.access(installed_binary, os.X_OK):
            raise RuntimeError("в свежей установке отсутствует исполняемый файл x86_64")
        binary_hash = hashlib.sha256(installed_binary.read_bytes()).hexdigest()
        engine = sysroot / "usr/sbin/install_release"
        engine_env = env.copy()
        engine_env.update(
            {
                "Z2K_ROOT": str(sysroot / "usr/lib/z2k"),
                "Z2K_ADAPTER_DIR": str(sysroot / "usr/lib/z2k/platform/openwrt"),
                "Z2K_LIB": str(sysroot / "usr/lib/z2k/lib"),
                "Z2K_OW_MANIFEST_PATH": str(served / "UPDATES.json"),
                "Z2K_OW_ARTIFACT_PATH": str(served_artifact),
                "Z2K_OW_BOOTSTRAP_MANIFEST": str(served / "UPDATES.json"),
                "Z2K_OW_BOOTSTRAP_SIGNATURE": str(signature),
                "Z2K_OW_BOOTSTRAP_ARTIFACT": str(served_artifact),
                "Z2K_OW_BOOTSTRAP_PUBLIC_KEY": str(pubkey),
            }
        )
        no_op = run([str(engine), tag], engine_env, "повторный запуск распознан как no-op")
        if f"none {tag}" not in no_op or hashlib.sha256(installed_binary.read_bytes()).hexdigest() != binary_hash:
            raise RuntimeError("no-op изменил установленный payload")

        old_tag, old_seq = "p-86.15", 999
        state.write_text(f"tag={old_tag}\nseq={old_seq}\n", encoding="utf-8")
        run([str(engine), tag], engine_env, "обновление с прежней записью релиза")
        check_state(state, tag, seq, "после обновления")
        check_bootstrap("настоящий bootstrap и runtime-ссылки после обновления")

        run([str(engine), "--reinstall", tag], engine_env, "повторная установка той же версии")
        check_state(state, tag, seq, "после повторной установки")
        check_bootstrap("настоящий bootstrap и runtime-ссылки после повторной установки")

        state.write_text(f"tag={old_tag}\nseq={old_seq}\n", encoding="utf-8")
        installed_binary.write_text("previous payload\n", encoding="utf-8")
        installed_binary.chmod(0o755)
        failing_env = engine_env.copy()
        failing_env["Z2K_TEST_FAIL_HTTP_PROBES"] = "15"
        rollback_output = run([str(engine), tag], failing_env, "неуспешная HTTP-проверка вызвала откат", expected=False)
        check_state(state, old_tag, old_seq, "после отката")
        if installed_binary.read_text(encoding="utf-8") != "previous payload\n" or "Z2KOW_ROLLBACK=complete" not in rollback_output:
            raise RuntimeError("откат не восстановил прежний payload или не подтвердил завершение")
        if (sysroot / "usr/lib/.z2k-install/transaction-active").exists():
            raise RuntimeError("после успешного отката остался активный журнал транзакции")

        engine_env["Z2K_TEST_FAIL_HTTP_PROBES"] = ""
        run([str(engine), tag], engine_env, "повторная попытка после отката")
        check_state(state, tag, seq, "после повторной попытки")
        check_bootstrap("настоящий bootstrap и runtime-ссылки после повторной попытки")
        for path, expected in (
            (sysroot / "etc/z2k/config", "сохраняемый пользовательский параметр"),
            (sysroot / "etc/z2k/user-lists/custom.txt", "user-domain.example"),
            (sysroot / "www/cgi-bin/luci", "точка входа LuCI должна сохраниться"),
            (sysroot / "etc/config/uhttpd", "конфигурация uhttpd должна сохраниться"),
            (release_tmp / "user-file.txt", "не удалять соседние пользовательские данные"),
        ):
            if expected not in path.read_text(encoding="utf-8"):
                raise RuntimeError(f"установка изменила пользовательские данные: {path}")

        if not service_log.exists() or not any("|restart" in line for line in service_log.read_text(encoding="utf-8").splitlines()):
            raise RuntimeError("реальный entrypoint не прошёл через проверочный обработчик служб")
        print("ПРОЙДЕНО: настройки, пользовательские списки, LuCI, uhttpd и соседний временный файл сохранены")
        print("СТЕНД: временный rootfs Linux; apk, procd и приложение WebPanel заменены заглушками; проверка роутера не выполнялась.")
        receipt = {
            "schema": 1,
            "result": "passed",
            "environment": "staged-linux-rootfs",
            "router_verified": False,
            "tag": tag,
            "seq": seq,
            "manifest_sha256": original_manifest_hash,
            "artifact_sha256": original_artifact_hash,
        }
        (manifest_source.parent / "candidate-acceptance.json").write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print("ПРОЙДЕНО: квитанция приёмки связана с исходными манифестом и архивом кандидата")

        panel.shutdown()
        httpd.shutdown()
        panel.server_close()
        httpd.server_close()
        panel_thread.join(timeout=2)
        http_thread.join(timeout=2)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # noqa: BLE001 - короткий диагностический вывод для CI
        print(f"ОШИБКА ПРИЁМКИ КАНДИДАТА: {error}", file=sys.stderr)
        raise SystemExit(1)
