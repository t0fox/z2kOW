#!/usr/bin/env python3
"""Проверяет обновление OpenWrt движком install_release при малом объёме памяти."""

from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import threading
import tarfile
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parents[2]
MEM_AVAILABLE_KB = 23_000
MEM_TOTAL_KB = 131_072
DISK_RESERVE_BYTES = 4 * 1024 * 1024


def run(args: Sequence[str], *, env: dict[str, str] | None = None, expected: bool = True, label: str) -> str:
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != expected:
        raise RuntimeError(f"{label}: код {result.returncode}\n{result.stdout}")
    print(f"ПРОЙДЕНО: {label}")
    return result.stdout


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def verify_signature(manifest_path: Path, signature_path: Path, public_key: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    key_id = manifest.get("signing", {}).get("key_id")
    if not isinstance(key_id, str) or len(key_id) != 64:
        raise RuntimeError(f"{manifest_path}: отсутствует signing.key_id")
    public_der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    if hashlib.sha256(public_der).hexdigest() != key_id:
        raise RuntimeError(f"{manifest_path}: SHA-256 доверенного ключа не совпадает с key_id")
    subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(public_key),
         "-rawin", "-in", str(manifest_path), "-sigfile", str(signature_path)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )


def selected_record(manifest: dict[str, Any], arch: str, *, previous: bool = False) -> dict[str, Any]:
    artifacts = manifest.get("artifacts")
    if isinstance(artifacts, dict) and arch in artifacts:
        return artifacts[arch]
    artifact = manifest.get("artifact")
    if isinstance(artifact, dict):
        return artifact
    which = "предыдущий релиз" if previous else "целевой релиз"
    raise RuntimeError(f"{which}: в подписанном манифесте нет архива для {arch}")


def verify_archive(path: Path, record: dict[str, Any], label: str) -> None:
    if not path.is_file():
        raise RuntimeError(f"{label}: архив не найден: {path}")
    if path.stat().st_size != record.get("size_bytes"):
        raise RuntimeError(f"{label}: размер архива не совпадает с подписанным манифестом")
    if digest(path) != record.get("sha256"):
        raise RuntimeError(f"{label}: SHA-256 архива не совпадает с подписанным манифестом")
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            entry = PurePosixPath(member.name)
            if entry.is_absolute() or ".." in entry.parts:
                raise RuntimeError(f"{label}: архив содержит небезопасный путь {member.name!r}")
        names = set(archive.getnames())
    required = {
        "usr/lib/z2k/platform/openwrt/release.sh",
        "usr/lib/z2k/platform/openwrt/manifest.sh",
        "usr/sbin/install_release",
    }
    if not required <= names:
        raise RuntimeError(f"{label}: архив не содержит исходный движок install_release")
    print(f"ПРОЙДЕНО: {label}: размер={path.stat().st_size}, sha256={digest(path)}")


def persistent_storage(path: Path) -> bool:
    command = '. "$1"; z2k_ow_storage_persistent "$2"'
    result = subprocess.run(
        ["sh", "-c", command, "sh", str(ROOT / "platform/openwrt/release.sh"), str(path)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return result.returncode == 0


def previous_uses_tmpfs_install_staging(paths_text: str) -> bool:
    """Определяет требования к хранилищу независимо от поколения установщика."""
    return "Z2K_OW_INSTALL_TMP:-/tmp/z2kow-install-stage" in paths_text


class CandidateServer:
    def __init__(self, manifest: Path, signature: Path, archive: Path, filename: str):
        self.manifest = manifest
        self.signature = signature
        self.archive = archive
        self.filename = filename

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - стандартный HTTP API
                if self.path == "/UPDATES.json":
                    body = self.server.owner.manifest.read_bytes()  # type: ignore[attr-defined]
                elif self.path == "/UPDATES.json.sig":
                    body = self.server.owner.signature.read_bytes()  # type: ignore[attr-defined]
                elif self.path == f"/{self.server.owner.filename}":  # type: ignore[attr-defined]
                    source = self.server.owner.archive  # type: ignore[attr-defined]
                    self.send_response(200)
                    self.send_header("Content-Length", str(source.stat().st_size))
                    self.end_headers()
                    with source.open("rb") as stream:
                        shutil.copyfileobj(stream, self.wfile, 64 * 1024)
                    return
                else:
                    body = b"panel ready\n"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.owner = self  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def make_helpers(directory: Path, server_url: str) -> tuple[Path, Path, Path, Path]:
    bindir = directory / "bin"
    bindir.mkdir()
    apk = bindir / "apk"
    apk.write_text(
        '''#!/bin/sh
action=${1:-}; shift || true
case "$action" in
    info)
        mode=${1:-}; shift || true
        package=${1:-}
        case "$mode" in
            -e) grep -Fxq "$package" "$Z2K_TEST_APK_PACKAGES" ;;
            --contents)
                grep -Fxq "$package" "$Z2K_TEST_APK_PACKAGES" || exit 1
                printf '%s\\n' ./usr/lib/z2k ./usr/sbin/install_release ./etc/init.d/z2k ./etc/init.d/z2k-webpanel
                ;;
            *) exit 2 ;;
        esac
        ;;
    del)
        [ "${1:-}" = --no-scripts ] || exit 2
        shift
        tmp="${Z2K_TEST_APK_PACKAGES}.new.$$"
        awk -v remove="$*" 'BEGIN {n=split(remove, a, " "); for(i=1;i<=n;i++) gone[a[i]]=1} !gone[$0]' \\
            "$Z2K_TEST_APK_PACKAGES" > "$tmp" || exit 1
        mv "$tmp" "$Z2K_TEST_APK_PACKAGES"
        ;;
    add) exit 0 ;;
    *) exit 2 ;;
esac
''',
        encoding="utf-8",
    )
    apk.chmod(0o755)
    jsonfilter = bindir / "jsonfilter"
    jsonfilter.write_text(
        "#!/usr/bin/env python3\nimport json,sys\na=sys.argv[1:]; f=e=None; t=False\n"
        "while a:\n x=a.pop(0)\n if x=='-i': f=a.pop(0)\n elif x=='-e': e=a.pop(0).removeprefix('@.')\n"
        " elif x=='-t': t=True; e=a.pop(0).removeprefix('@.')\n"
        "v=json.load(open(f,encoding='utf-8'))\nfor k in e.split('.'): v=v[k]\n"
        "print(('object' if isinstance(v,dict) else 'array' if isinstance(v,list) else 'string' if isinstance(v,str) else 'number') if t else v)\n",
        encoding="utf-8",
    )
    jsonfilter.chmod(0o755)
    df = bindir / "df"
    real_df = shutil.which("df")
    if real_df is None:
        raise RuntimeError("не найдена системная df для upgrade acceptance")
    df.write_text(
        "#!/bin/sh\n"
        "if [ \"${Z2K_TEST_LOW_SPACE:-0}\" = 1 ]; then\n"
        "  _p=; for _arg in \"$@\"; do _p=$_arg; done\n"
        "  case \"$_p\" in \"$Z2K_TEST_LOW_SPACE_PATH\"*)\n"
        "    printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\\nlow 100 99 1 99%% %s\\n' \"$_p\"; exit 0;;\n"
        "  esac\nfi\n"
        f"exec {real_df!r} \"$@\"\n",
        encoding="utf-8",
    )
    df.chmod(0o755)
    wget = bindir / "wget"
    real_curl = shutil.which("curl")
    if real_curl is None:
        raise RuntimeError("не найдена системная curl для upgrade acceptance")
    curl = bindir / "curl"
    curl.write_text(
        "#!/bin/sh\n_out= _url= _next=0\n"
        "for _arg in \"$@\"; do\n"
        "  if [ \"$_next\" = 1 ]; then _out=$_arg; _next=0; continue; fi\n"
        "  case \"$_arg\" in -o) _next=1 ;; http://*|https://*) _url=$_arg ;; esac\n"
        "done\n"
        "case \"$_url\" in */openwrt-rootfs*.tar.gz) printf '%s\\n' \"$_out\" >> \"$Z2K_TEST_DOWNLOAD_LOG\" ;; esac\n"
        f"exec {real_curl!r} \"$@\"\n",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    wget.write_text(
        "#!/bin/sh\n_out= _url=\nwhile [ $# -gt 0 ]; do\n"
        "  case \"$1\" in -O) shift; _out=$1 ;; http://*|https://*) _url=$1 ;; esac\n"
        "  shift\ndone\n"
        "[ -n \"$_out\" ] && [ -n \"$_url\" ] || exit 2\n"
        "printf '%s\\n' \"$_out\" >> \"$Z2K_TEST_DOWNLOAD_LOG\"\n"
        f"exec {real_curl!r} --fail --location --silent --show-error --connect-timeout 5 --max-time 180 -o \"$_out\" \"$_url\"\n",
        encoding="utf-8",
    )
    wget.chmod(0o755)
    service_helper = directory / "service-helper"
    service_helper.write_text(
        '''#!/bin/sh
service=${1##*/}; action=${2:-}
printf '%s|%s\\n' "$service" "$action" >> "$Z2K_TEST_SERVICE_LOG"
case "$service" in z2k|z2k-webpanel) ;; *) exit 2 ;; esac
state="$Z2K_TEST_SERVICE_STATE.$service"
case "$action" in
    stop) printf 'stopped\\n' > "$state" ;;
    start|restart)
        if [ "$service" = z2k ] && [ "${Z2K_TEST_FAIL_Z2K_STARTS:-0}" -gt 0 ]; then
            n=$(cat "$Z2K_TEST_FAILURE_COUNT" 2>/dev/null || echo 0); n=$((n+1)); printf '%s\\n' "$n" > "$Z2K_TEST_FAILURE_COUNT"
            [ "$n" -gt "$Z2K_TEST_FAIL_Z2K_STARTS" ] || exit 1
        fi
        printf 'running\\n' > "$state" ;;
    enable) ;;
    status|running) [ "$(cat "$state" 2>/dev/null)" = running ] ;;
    *) exit 2 ;;
esac
''', encoding="utf-8",
    )
    service_helper.chmod(0o755)
    init_probe = directory / "init-probe"
    init_probe.write_text(
        '''#!/bin/sh
[ "${1:-}" = running ] || exit 2
[ "$(cat "$Z2K_TEST_SERVICE_STATE.z2k" 2>/dev/null)" = running ]
''',
        encoding="utf-8",
    )
    init_probe.chmod(0o755)
    http_probe = directory / "http-probe"
    http_probe.write_text(f"#!/bin/sh\nexec curl --fail --silent --show-error --connect-timeout 2 --max-time 4 -o /dev/null '{server_url}/'\n", encoding="utf-8")
    http_probe.chmod(0o755)
    return bindir, service_helper, init_probe, http_probe, wget


def seed_previous_root(previous_archive: Path, sysroot: Path) -> None:
    sysroot.mkdir(parents=True)
    subprocess.run(["tar", "-xzf", str(previous_archive), "-C", str(sysroot)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    etc = sysroot / "etc/z2k"
    (etc / "state").mkdir(parents=True, exist_ok=True)
    (etc / "webpanel").mkdir(parents=True, exist_ok=True)
    (etc / "config").write_text("ENABLED=1\n# upgrade acceptance user data\n", encoding="utf-8")
def state_record(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines() if "=" in line)


def archive_member(archive: Path, member: str) -> bytes:
    return subprocess.run(["tar", "-xOzf", str(archive), member], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-manifest", type=Path, required=True)
    parser.add_argument("--previous-signature", type=Path, required=True)
    parser.add_argument("--previous-archive", type=Path, required=True)
    parser.add_argument("--candidate-manifest", type=Path, required=True)
    parser.add_argument("--candidate-archive", type=Path, required=True)
    parser.add_argument("--candidate-signature", type=Path)
    parser.add_argument("--receipt-output", type=Path)
    parser.add_argument("--architecture", default="x86_64")
    parser.add_argument("--legacy-tmpfs-transition", action="store_true",
                        help="also prove the old p-86.17 default tmpfs preflight fails before the disk override succeeds")
    args = parser.parse_args()

    previous_manifest = json.loads(args.previous_manifest.read_text(encoding="utf-8"))
    candidate_manifest = json.loads(args.candidate_manifest.read_text(encoding="utf-8"))
    key_id = previous_manifest.get("signing", {}).get("key_id", "")
    trusted_key = ROOT / "scripts/openwrt/release-keys" / f"{key_id}.pub"
    if not trusted_key.is_file():
        raise RuntimeError(f"нет закреплённого ключа предыдущего релиза: {trusted_key}")
    verify_signature(args.previous_manifest, args.previous_signature, trusted_key)
    print(f"ПРОЙДЕНО: подпись предыдущего манифеста {previous_manifest.get('current')} проверена")
    previous_record = selected_record(previous_manifest, args.architecture, previous=True)
    verify_archive(args.previous_archive, previous_record, "rootfs предыдущего опубликованного релиза")

    with tarfile.open(args.previous_archive, "r:gz") as previous_tar:
        previous_release_source = previous_tar.extractfile("usr/lib/z2k/platform/openwrt/release.sh")
        if previous_release_source is None:
            raise RuntimeError("предыдущий rootfs не содержит release.sh")
        previous_release_text = previous_release_source.read().decode("utf-8", errors="replace")
        previous_paths_source = previous_tar.extractfile("usr/lib/z2k/platform/openwrt/paths.sh")
        if previous_paths_source is None:
            raise RuntimeError("предыдущий rootfs не содержит paths.sh")
        previous_paths_text = previous_paths_source.read().decode("utf-8", errors="replace")
    legacy_installer = "z2k_ow_manifest_select_artifact" not in previous_release_text
    # Выбор архива по архитектуре не делает /tmp безопасным. Для предыдущего
    # установщика с временными данными в tmpfs сначала нужно задать постоянный
    # каталог Z2K_OW_INSTALL_TMP, иначе проверка при малом объёме памяти не пройдёт.
    previous_requires_disk_transition = previous_uses_tmpfs_install_staging(previous_paths_text)
    use_generic_candidate = legacy_installer and isinstance(candidate_manifest.get("artifact"), dict)
    if use_generic_candidate:
        candidate_record = candidate_manifest["artifact"]
    else:
        candidate_record = selected_record(candidate_manifest, args.architecture)
    verify_archive(args.candidate_archive, candidate_record, "rootfs целевого кандидата")
    if args.candidate_signature:
        verify_signature(args.candidate_manifest, args.candidate_signature, trusted_key)
        print("ПРОЙДЕНО: подпись целевого манифеста проверена закреплённым ключом")

    previous_tag = str(previous_manifest["current"])
    previous_seq = int(previous_manifest["seq"])
    candidate_tag = str(candidate_manifest["current"])
    candidate_seq = int(candidate_manifest["seq"])
    if candidate_manifest.get("platform") != "openwrt" or previous_manifest.get("platform") != "openwrt":
        raise RuntimeError("upgrade acceptance работает только с манифестами OpenWrt")
    if candidate_tag == previous_tag and candidate_seq == previous_seq:
        print("Кандидат повторно устанавливает тот же tag/seq; переход выполняется по новому SHA-256 payload")

    storage_parent = Path(os.environ.get("RUNNER_TEMP", "/var/tmp")).resolve()
    storage_parent.mkdir(parents=True, exist_ok=True)
    if not persistent_storage(storage_parent):
        storage_parent = Path("/var/tmp").resolve()
    if not persistent_storage(storage_parent):
        raise RuntimeError(f"upgrade acceptance требует проверенную постоянную файловую систему: {storage_parent}")
    for archive_path in (args.previous_archive, args.candidate_archive):
        if not persistent_storage(archive_path.resolve().parent):
            raise RuntimeError(f"интеграционные rootfs-архивы должны находиться на постоянной файловой системе: {archive_path}")
    required_bytes = args.previous_archive.stat().st_size + args.candidate_archive.stat().st_size
    if shutil.disk_usage(storage_parent).free < required_bytes + DISK_RESERVE_BYTES:
        raise RuntimeError("на постоянном разделе недостаточно места для интеграционного upgrade-сценария")

    with tempfile.TemporaryDirectory(prefix="z2kow-release-upgrade-", dir=storage_parent) as temp_name:
        workspace = Path(temp_name)
        sysroot = workspace / "sysroot"
        seed_previous_root(args.previous_archive, sysroot)
        state_path = sysroot / "etc/z2k/state/installed-release"
        state_path.write_text(f"tag={previous_tag}\nseq={previous_seq}\n", encoding="utf-8")
        old_installer = (sysroot / "usr/sbin/install_release").read_bytes()
        expected_installer = archive_member(args.candidate_archive, "usr/sbin/install_release")
        candidate_paths = archive_member(args.candidate_archive, "usr/lib/z2k/platform/openwrt/paths.sh").decode(
            "utf-8", errors="replace")
        candidate_has_persistent_default = "Z2K_OW_INSTALL_TMP=/usr/lib/.z2kow-install-stage" in candidate_paths
        config_path = sysroot / "etc/z2k/config"
        old_config = config_path.read_bytes()
        old_release = sysroot / "usr/lib/z2k/platform/openwrt/release.sh"
        old_release_text = old_release.read_text(encoding="utf-8", errors="replace")
        old_installer_sha = digest(old_release)
        if args.legacy_tmpfs_transition and (previous_tag, previous_seq) != ("p-86.17", 140):
            raise RuntimeError("--legacy-tmpfs-transition требует именно опубликованный p-86.17 / seq 140")
        if args.legacy_tmpfs_transition and not previous_requires_disk_transition:
            raise RuntimeError("архив p-86.17 не содержит ожидаемый временный staging в /tmp")
        print(f"Источник upgrade: {previous_tag} seq {previous_seq}; SHA движка {old_installer_sha}")
        insufficient_space_passed = False
        rollback_passed = False
        tmpfs_refusal_passed = False
        panel_update_default_persistent = False

        filename = str(candidate_record["filename"])
        candidate_for_server = dict(candidate_manifest)
        if isinstance(candidate_for_server.get("artifacts"), dict) and args.architecture in candidate_for_server["artifacts"]:
            candidate_for_server["artifacts"][args.architecture] = dict(candidate_record)
        else:
            candidate_for_server["artifact"] = dict(candidate_record)
        # Старые движки принимают только заданный формат URL GitHub, если только
        # начальный манифест не указывает этот точный URL как ожидаемый адрес.
        # HTTP-адрес должен существовать до подписи манифеста с URL архива.
        # Сначала резервируем порт, затем запускаем сервер повторно.
        reserved = ThreadingHTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
        port = reserved.server_port
        reserved.server_close()
        base_url = f"http://127.0.0.1:{port}"
        if not use_generic_candidate and "artifacts" in candidate_for_server and args.architecture in candidate_for_server["artifacts"]:
            candidate_for_server["artifacts"][args.architecture]["url"] = f"{base_url}/{filename}"
        if use_generic_candidate:
            candidate_for_server["artifact"]["url"] = f"{base_url}/{filename}"
        # Сервер самостоятельно занимает свободный порт. После запуска пересобираем
        # манифест, чтобы URL точно совпадал с адресом сервера.
        first_key = workspace / "candidate-first.key"
        first_public = workspace / "candidate-first.pub"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(first_key)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "pkey", "-in", str(first_key), "-pubout", "-out", str(first_public)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        first_der = subprocess.run(["openssl", "pkey", "-pubin", "-in", str(first_public), "-outform", "DER"],
                                   check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        candidate_for_server["signing"] = {"key_id": hashlib.sha256(first_der).hexdigest()}
        signed_manifest = workspace / "candidate-UPDATES.json"
        signed_manifest.write_text(json.dumps(candidate_for_server, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        signed_signature = workspace / "candidate-UPDATES.json.sig"
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(first_key),
                        "-in", str(signed_manifest), "-out", str(signed_signature)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server = CandidateServer(signed_manifest, signed_signature, args.candidate_archive, filename)
        # Подписываем локальный URL после привязки к порту. Если временный порт
        # изменился при создании сервера, пересоздаём подпись до первого запроса.
        actual_url = f"{server.base_url}/{filename}"
        if candidate_for_server.get("artifacts", {}).get(args.architecture, {}).get("url") != actual_url:
            if not use_generic_candidate and "artifacts" in candidate_for_server and args.architecture in candidate_for_server["artifacts"]:
                candidate_for_server["artifacts"][args.architecture]["url"] = actual_url
            if use_generic_candidate:
                candidate_for_server["artifact"]["url"] = actual_url
            signed_manifest.write_text(json.dumps(candidate_for_server, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(first_key),
                            "-in", str(signed_manifest), "-out", str(signed_signature)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        try:
            bindir, service_helper, init_probe, http_probe, _wget = make_helpers(workspace, server.base_url)
            if args.candidate_signature:
                signature_env = os.environ.copy()
                signature_env.update({
                    "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                    "Z2K_ROOT": str(sysroot / "usr/lib/z2k"),
                    "Z2K_ADAPTER_DIR": str(sysroot / "usr/lib/z2k/platform/openwrt"),
                    "Z2K_LIB": str(sysroot / "usr/lib/z2k/lib"),
                    "Z2K_OW_SYSROOT": str(sysroot),
                    "Z2K_TEST_CANDIDATE_MANIFEST": str(args.candidate_manifest),
                    "Z2K_TEST_CANDIDATE_SIGNATURE": str(args.candidate_signature),
                })
                for name in ("Z2K_OW_TESTING", "Z2K_OW_BOOTSTRAP_PUBLIC_KEY", "Z2K_OW_BOOTSTRAP_MANIFEST",
                             "Z2K_OW_BOOTSTRAP_SIGNATURE", "Z2KOW_MANIFEST_URL", "Z2K_OW_INSTALL_TMP"):
                    signature_env.pop(name, None)
                run(["sh", "-c",
                     '. "$Z2K_ADAPTER_DIR/paths.sh"; . "$Z2K_LIB/utils.sh"; '
                     '. "$Z2K_LIB/auto_update.sh"; . "$Z2K_ADAPTER_DIR/manifest.sh"; '
                     'z2k_ow_manifest_verify_signature "$Z2K_TEST_CANDIDATE_MANIFEST" "$Z2K_TEST_CANDIDATE_SIGNATURE"',
                     "sh"], env=signature_env,
                     label="предыдущий опубликованный движок проверяет точную production-подпись кандидата")
            meminfo = workspace / "meminfo"
            meminfo.write_text(f"MemTotal: {MEM_TOTAL_KB} kB\nMemAvailable: {MEM_AVAILABLE_KB} kB\n", encoding="utf-8")
            mountinfo = workspace / "mountinfo"
            disk_tmp_parent = workspace / "disk-tmp"
            disk_tmp_parent.mkdir()
            mountinfo.write_text(
                f"36 25 0:32 / / rw - ext4 /dev/test-root rw\n"
                f"37 36 0:33 / /tmp rw - tmpfs tmpfs rw\n"
                f"38 36 0:34 / {workspace} rw - ext4 /dev/test-overlay rw\n",
                encoding="utf-8",
            )
            (sysroot / "etc/z2k/webpanel/port").write_text(str(server.server.server_port), encoding="utf-8")
            (sysroot / "etc/z2k/webpanel/bind").write_text("127.0.0.1\n", encoding="utf-8")
            failure_count = workspace / "service-failure-count"
            service_state = workspace / "service-state"
            service_log = workspace / "service-calls.log"
            apk_packages = workspace / "apk-packages"
            apk_packages.write_text("z2k-adapter\n", encoding="utf-8")
            for service in ("z2k", "z2k-webpanel"):
                Path(f"{service_state}.{service}").write_text("running\n", encoding="utf-8")
            Path(f"{service_state}.unused").unlink(missing_ok=True)
            release_file = workspace / "openwrt_release"
            release_file.write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.5'\nDISTRIB_ARCH='x86_64'\n", encoding="utf-8")
            runtime = workspace / "runtime"
            runtime.mkdir()
            (runtime / "core-ready").write_text("ready\n", encoding="utf-8")
            (runtime / "nfqws2.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
            nfqueue_proc = workspace / "nfqueue"
            nfqueue_proc.write_text(f"200 {os.getpid()} 1 65535 0 0 0 0 0 0\n", encoding="utf-8")
            tool_path = f"{bindir}:{os.environ.get('PATH', '')}"

            base_env = os.environ.copy()
            for name in list(base_env):
                if name.startswith("Z2K_") or name.startswith("Z2KOW_"):
                    base_env.pop(name, None)
            base_env.update({
                "PATH": tool_path,
                "Z2K_ROOT": str(sysroot / "usr/lib/z2k"),
                "Z2K_ADAPTER_DIR": str(sysroot / "usr/lib/z2k/platform/openwrt"),
                "Z2K_LIB": str(sysroot / "usr/lib/z2k/lib"),
                "Z2K_OW_SYSROOT": str(sysroot),
                "Z2K_OW_INSTALL_WORK": "/usr/lib/.z2k-install",
                "Z2K_OW_INSTALLED_RELEASE_FILE": "/etc/z2k/state/installed-release",
                "Z2K_OW_BOOTSTRAP_MANIFEST": str(signed_manifest),
                "Z2K_OW_BOOTSTRAP_SIGNATURE": str(signed_signature),
                "Z2K_OW_BOOTSTRAP_PUBLIC_KEY": str(first_public),
                "Z2KOW_MANIFEST_URL": f"{server.base_url}/UPDATES.json",
                "Z2K_OW_TESTING": "1",
                "Z2K_OW_TEST_HEALTHCHECK": "1",
                "Z2K_OW_TEST_SERVICE_HELPER": str(service_helper),
                "Z2K_RUN": str(runtime),
                "Z2K_CORE_READY": str(runtime / "core-ready"),
                "Z2K_NFQUEUE_PROC": str(nfqueue_proc),
                "INIT_SCRIPT": str(init_probe),
                "Z2K_OW_TEST_HTTP_PROBE": str(http_probe),
                "Z2K_OW_MEMINFO_FILE": str(meminfo),
                "Z2K_OW_MOUNTINFO_FILE": str(mountinfo),
                "Z2K_OW_OPENWRT_RELEASE_FILE": str(release_file),
                "Z2K_TEST_SERVICE_LOG": str(service_log),
                "Z2K_TEST_DOWNLOAD_LOG": str(workspace / "download-destinations.log"),
                "Z2K_TEST_SERVICE_STATE": str(service_state),
                "Z2K_TEST_FAILURE_COUNT": str(failure_count),
                "Z2K_TEST_APK_PACKAGES": str(apk_packages),
                "Z2K_TEST_LOW_SPACE_PATH": str(sysroot / "usr/lib/.z2k-install"),
                "Z2K_TEST_LOW_SPACE": "0",
                "Z2K_TEST_FAIL_Z2K_STARTS": "0",
            })

            def invoke(temp_parent: Path | None, label: str, *, low_space: bool = False, fail_starts: int = 0,
                       reinstall: bool = False, expected: bool = True, requested_tag: str | None = None,
                       bootstrap_manifest: Path | None = None,
                       bootstrap_signature: Path | None = None) -> str:
                env = base_env.copy()
                if temp_parent is None:
                    # Проверяем обычную среду панели без заданного пути:
                    # установленный paths.sh должен выбрать постоянный каталог
                    # после однократного перехода с p-86.17.
                    env.pop("Z2K_OW_INSTALL_TMP", None)
                else:
                    env["Z2K_OW_INSTALL_TMP"] = str(temp_parent)
                env["Z2K_OW_BOOTSTRAP_MANIFEST"] = str(bootstrap_manifest or signed_manifest)
                env["Z2K_OW_BOOTSTRAP_SIGNATURE"] = str(bootstrap_signature or signed_signature)
                env["Z2K_TEST_LOW_SPACE"] = "1" if low_space else "0"
                env["Z2K_TEST_FAIL_Z2K_STARTS"] = str(fail_starts)
                env.pop("Z2K_OW_BOOTSTRAP_ARTIFACT", None)
                env.pop("Z2K_OW_ARTIFACT_PATH", None)
                service_log.write_text("", encoding="utf-8")
                failure_count.unlink(missing_ok=True)
                current_tag = state_record(state_path).get("tag")
                verifier = ("движок предыдущего релиза" if current_tag == previous_tag
                            else "движок установленного кандидата")
                run(["sh", "-c",
                     '. "$Z2K_ADAPTER_DIR/paths.sh"; . "$Z2K_LIB/utils.sh"; '
                     '. "$Z2K_LIB/auto_update.sh"; . "$Z2K_ADAPTER_DIR/manifest.sh"; '
                     'z2k_ow_manifest_verify_signature "$Z2K_OW_BOOTSTRAP_MANIFEST" "$Z2K_OW_BOOTSTRAP_SIGNATURE"',
                     "sh"], env=env, label=f"{verifier} проверяет подпись кандидата перед {label}")
                return run(["sh", str(sysroot / "usr/sbin/install_release"),
                            *( ["--reinstall"] if reinstall else [] ), requested_tag or candidate_tag],
                           env=env, expected=expected, label=label)

            def configured_default_tmp() -> Path:
                env = base_env.copy()
                env.pop("Z2K_OW_INSTALL_TMP", None)
                configured = subprocess.run(
                    ["sh", "-c", '. "$Z2K_ADAPTER_DIR/paths.sh"; printf "%s\\n" "$Z2K_OW_INSTALL_TMP"'],
                    env=env, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                ).stdout.strip()
                expected = str(sysroot / "usr/lib/.z2kow-install-stage")
                if configured != expected:
                    raise RuntimeError(f"обычная среда панели выбрала непостоянный staging: {configured!r}")
                return Path(configured)

            if previous_requires_disk_transition:
                ram_tmp_parent = workspace / "previous-default-tmpfs"
                ram_tmp_parent.mkdir()
                with mountinfo.open("a", encoding="utf-8") as mounts:
                    mounts.write(f"39 36 0:35 / {ram_tmp_parent} rw - tmpfs tmpfs rw\n")
                try:
                    original_meminfo = meminfo.read_text(encoding="utf-8")
                    meminfo.write_text(
                        f"MemTotal: {MEM_TOTAL_KB} kB\nMemAvailable: 8000 kB\n",
                        encoding="utf-8",
                    )
                    try:
                        output = invoke(
                            ram_tmp_parent,
                            f"предыдущий {previous_tag} updater отказывает на tmpfs при 8 МиБ MemAvailable",
                            expected=False,
                        )
                    finally:
                        meminfo.write_text(original_meminfo, encoding="utf-8")
                    calls = service_log.read_text(encoding="utf-8") if service_log.exists() else ""
                    if "stop" in calls:
                        raise RuntimeError("предыдущий установщик останавливал службы до RAM-preflight")
                    if state_record(state_path) != {"tag": previous_tag, "seq": str(previous_seq)}:
                        raise RuntimeError("отказ tmpfs изменил запись установленного релиза")
                    if "недостаточно" not in output.lower() and "memory" not in output.lower():
                        raise RuntimeError(f"предыдущий установщик отказал не на проверке RAM: {output}")
                    download_log = workspace / "download-destinations.log"
                    legacy_downloads = download_log.read_text(encoding="utf-8").splitlines() if download_log.exists() else []
                    if legacy_downloads:
                        raise RuntimeError(f"предыдущий установщик скачал архив до RAM-preflight: {legacy_downloads}")
                    tmpfs_refusal_passed = True
                finally:
                    shutil.rmtree(ram_tmp_parent)
                print(f"ПРОЙДЕНО: переход {previous_tag} требует Z2K_OW_INSTALL_TMP на постоянном разделе")
            elif not legacy_installer:
                # Следующий опубликованный установщик должен выявить нехватку
                # постоянного места до загрузки кандидата и остановки служб.
                output = invoke(None, "недостаток ext4-места отклонён до остановки службы",
                                low_space=True, expected=False)
                calls = service_log.read_text(encoding="utf-8") if service_log.exists() else ""
                if "stop" in calls:
                    raise RuntimeError("отказ по месту остановил службу")
                if state_record(state_path) != {"tag": previous_tag, "seq": str(previous_seq)}:
                    raise RuntimeError("отказ по месту изменил release state")
                if "недостаточно места" not in output.lower():
                    raise RuntimeError(f"отказ не объясняет нехватку постоянного места: {output}")
                insufficient_space_passed = True

            if not previous_requires_disk_transition:
                output = invoke(None, "сбой после stop выполняет rollback предыдущего релиза",
                                fail_starts=2, expected=False)
                calls = service_log.read_text(encoding="utf-8") if service_log.exists() else ""
                if "z2k|stop" not in calls or "z2k|restart" not in calls:
                    raise RuntimeError(f"fault injection не прошёл после остановки службы: {calls}")
                if state_record(state_path) != {"tag": previous_tag, "seq": str(previous_seq)}:
                    raise RuntimeError("rollback не восстановил прежний tag/seq")
                current_installer = (sysroot / "usr/sbin/install_release").read_bytes()
                if current_installer != old_installer:
                    raise RuntimeError("rollback не восстановил прежний install_release")
                if any(Path(f"{service_state}.{service}").read_text(encoding="utf-8").strip() != "running"
                       for service in ("z2k", "z2k-webpanel")):
                    raise RuntimeError("rollback оставил службу остановленной")
                rollback_passed = True

            output = invoke(disk_tmp_parent if previous_requires_disk_transition else None,
                            "штатный install_release устанавливает целевой rootfs при 128/23 000 КиБ")
            if state_record(state_path) != {"tag": candidate_tag, "seq": str(candidate_seq)}:
                raise RuntimeError(f"после upgrade записано неверное состояние: {state_record(state_path)}")
            if config_path.read_bytes() != old_config:
                raise RuntimeError("upgrade потерял пользовательскую конфигурацию")
            if (sysroot / "usr/sbin/install_release").read_bytes() != expected_installer:
                raise RuntimeError("после upgrade install_release не совпадает с файлом целевого архива")
            if any(Path(f"{service_state}.{service}").read_text(encoding="utf-8").strip() != "running"
                   for service in ("z2k", "z2k-webpanel")):
                raise RuntimeError("после upgrade служба или панель не запущена")
            if (disk_tmp_parent / "z2kow-release").exists():
                raise RuntimeError("после успеха остался временный рабочий каталог")
            if not legacy_installer:
                if not candidate_has_persistent_default:
                    raise RuntimeError("release candidate does not default panel staging to persistent storage")
                default_parent = configured_default_tmp()
                if (default_parent / "z2kow-release").exists():
                    raise RuntimeError("обычный staging панели не очищен после обновления")
                panel_update_default_persistent = True

            if previous_requires_disk_transition:
                if args.legacy_tmpfs_transition and not use_generic_candidate:
                    raise RuntimeError("p-86.17 upgrade acceptance требует подписанный generic transition fallback")
                    # Предыдущий установщик с tmpfs по умолчанию не может проверить
                    # новую проверку места и откат. После реального перехода запускаем
                    # установленный движок кандидата на тех же байтах с тестовыми
                    # следующим номером последовательности и тегом.
                next_tag = f"{candidate_tag}.1"
                next_manifest_data = dict(candidate_for_server)
                if use_generic_candidate:
                    next_manifest_data.pop("artifacts", None)
                next_manifest_data["current"] = next_tag
                next_manifest_data["seq"] = candidate_seq + 1
                next_manifest_data["upstream"] = dict(next_manifest_data["upstream"])
                next_manifest_data["upstream"]["tag"] = next_tag
                next_manifest_data["history"] = [dict(entry) for entry in next_manifest_data["history"]]
                next_manifest_data["history"][-1]["v"] = next_tag
                next_manifest = workspace / "candidate-next-UPDATES.json"
                next_manifest.write_text(json.dumps(next_manifest_data, ensure_ascii=False, indent=2) + "\n",
                                         encoding="utf-8")
                next_signature = workspace / "candidate-next-UPDATES.json.sig"
                subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(first_key),
                                "-in", str(next_manifest), "-out", str(next_signature)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                next_tmp_parent = None if candidate_has_persistent_default else disk_tmp_parent
                output = invoke(next_tmp_parent, "движок кандидата отклоняет нехватку места до остановки служб",
                                low_space=True, expected=False, requested_tag=next_tag,
                                bootstrap_manifest=next_manifest, bootstrap_signature=next_signature)
                calls = service_log.read_text(encoding="utf-8") if service_log.exists() else ""
                if "stop" in calls:
                    raise RuntimeError("отказ по месту после перехода остановил службу")
                if state_record(state_path) != {"tag": candidate_tag, "seq": str(candidate_seq)}:
                    raise RuntimeError("отказ по месту после перехода изменил release state")
                if "недостаточно места" not in output.lower():
                    raise RuntimeError(f"отказ после перехода не объясняет нехватку места: {output}")
                if any(Path(f"{service_state}.{service}").read_text(encoding="utf-8").strip() != "running"
                       for service in ("z2k", "z2k-webpanel")):
                    raise RuntimeError("отказ по месту после перехода изменил состояние работающих служб")
                insufficient_space_passed = True

                invoke(next_tmp_parent, "движок кандидата выполняет rollback после stop",
                       fail_starts=2, expected=False, requested_tag=next_tag,
                       bootstrap_manifest=next_manifest, bootstrap_signature=next_signature)
                calls = service_log.read_text(encoding="utf-8") if service_log.exists() else ""
                if "z2k|stop" not in calls or "z2k|restart" not in calls:
                    raise RuntimeError(f"fault injection после перехода не прошёл через stop/rollback: {calls}")
                if state_record(state_path) != {"tag": candidate_tag, "seq": str(candidate_seq)}:
                    raise RuntimeError("rollback движка кандидата не восстановил tag/seq")
                if (sysroot / "usr/sbin/install_release").read_bytes() != expected_installer:
                    raise RuntimeError("rollback движка кандидата не сохранил install_release")
                if any(Path(f"{service_state}.{service}").read_text(encoding="utf-8").strip() != "running"
                       for service in ("z2k", "z2k-webpanel")):
                    raise RuntimeError("rollback движка кандидата оставил службы остановленными")
                rollback_passed = True

                if candidate_has_persistent_default:
                    # При каждом следующем обновлении WebPanel подключает paths.sh
                    # без переопределения пути. Проверяем, что обычный путь остаётся
                    # постоянным и позволяет завершить следующую транзакцию.
                    invoke(None, "следующее обновление панели использует постоянный путь по умолчанию",
                           requested_tag=next_tag, bootstrap_manifest=next_manifest,
                           bootstrap_signature=next_signature)
                    if state_record(state_path) != {"tag": next_tag, "seq": str(candidate_seq + 1)}:
                        raise RuntimeError("обычное обновление без Z2K_OW_INSTALL_TMP не завершилось")
                    if config_path.read_bytes() != old_config:
                        raise RuntimeError("обычное обновление панели потеряло пользовательскую конфигурацию")
                    if any(Path(f"{service_state}.{service}").read_text(encoding="utf-8").strip() != "running"
                           for service in ("z2k", "z2k-webpanel")):
                        raise RuntimeError("обычное обновление панели оставило службу остановленной")
                    default_tmp = configured_default_tmp()
                    if (default_tmp / "z2kow-release").exists():
                        raise RuntimeError("обычный путь staging не очищен после обновления")
                    panel_update_default_persistent = True
                else:
                    print("ПРОПУЩЕНО: исторический целевой архив не содержит новый persistent-default paths.sh")

            downloads = (workspace / "download-destinations.log").read_text(encoding="utf-8").splitlines()
            if not downloads:
                raise RuntimeError("upgrade не скачал архив через обычный release endpoint")
            expected_download_roots = [sysroot / "usr/lib/.z2k-install"]
            if previous_requires_disk_transition:
                expected_download_roots.append(disk_tmp_parent / "z2kow-release")
            if any(not any(Path(destination).is_relative_to(root) for root in expected_download_roots)
                   for destination in downloads):
                raise RuntimeError(f"архив релиза скачивался вне постоянного workspace: {downloads}")
            installed_archive = sysroot / "usr/lib/.z2k-install/openwrt-rootfs.tar.gz"
            if installed_archive.exists() and persistent_storage(installed_archive.parent) is False:
                raise RuntimeError("архив релиза попал в tmpfs")
            if args.receipt_output:
                receipt = {
                    "schema": 1,
                    "result": "passed",
                    "environment": "previous-published-installer",
                    "architecture": args.architecture,
                    "previous_tag": previous_tag,
                    "previous_seq": previous_seq,
                    "previous_manifest_sha256": digest(args.previous_manifest),
                    "previous_signature_sha256": digest(args.previous_signature),
                    "previous_archive_sha256": digest(args.previous_archive),
                    "installer_source_sha256": old_installer_sha,
                    "candidate_tag": candidate_tag,
                    "candidate_seq": candidate_seq,
                    "candidate_manifest_sha256": digest(args.candidate_manifest),
                    "candidate_archive_sha256": digest(args.candidate_archive),
                    "candidate_signature_verified_by_previous_engine": bool(args.candidate_signature),
                    "candidate_test_signature_verified_by_previous_engine": True,
                    "candidate_signature_sha256": digest(args.candidate_signature) if args.candidate_signature else None,
                    "previous_stage_default": "tmpfs" if previous_requires_disk_transition else "persistent",
                    "mem_total_kb": MEM_TOTAL_KB,
                    "mem_available_kb": MEM_AVAILABLE_KB,
                    "scenarios": {
                        "legacy_tmpfs_refusal": tmpfs_refusal_passed,
                        "panel_update_default_persistent": panel_update_default_persistent,
                        "insufficient_persistent_space": insufficient_space_passed,
                        "rollback_after_service_stop": rollback_passed,
                        "successful_upgrade": True,
                        "user_configuration_preserved": True,
                        "services_running_after_upgrade": True,
                    },
                }
                args.receipt_output.parent.mkdir(parents=True, exist_ok=True)
                args.receipt_output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"ПРОЙДЕНО: пользовательская конфигурация, службы, SHA-256 и cleanup; MemTotal={MEM_TOTAL_KB} КиБ, MemAvailable={MEM_AVAILABLE_KB} КиБ")
            print(f"ИТОГ upgrade acceptance: {previous_tag} -> {candidate_tag}; installer={old_installer_sha}")
        finally:
            server.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError, ValueError) as error:
        raise SystemExit(f"ОТКАЗ upgrade acceptance: {error}") from error
