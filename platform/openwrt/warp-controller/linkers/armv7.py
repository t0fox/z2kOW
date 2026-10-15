#!/usr/bin/env python3
import os
import sys

zig = os.environ.get("ZIG", "/usr/bin/zig")
start_files = {"crt1.o", "rcrt1.o", "Scrt1.o", "crti.o", "crtbegin.o", "crtbeginS.o", "crtbeginT.o", "crtend.o", "crtendS.o", "crtn.o"}
args = [
    arg
    for arg in sys.argv[1:]
    if not arg.startswith("--target=")
    and arg not in ("-nostartfiles", "-nostdlib")
    and arg.rsplit("/", 1)[-1] not in start_files
]
os.execv(zig, [zig, "cc", "-target", "arm-linux-musleabihf", "-mcpu=cortex_a7", "-static", *args])
