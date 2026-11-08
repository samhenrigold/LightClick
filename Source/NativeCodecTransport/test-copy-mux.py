#!/usr/bin/env python3
"""Build/run only the libc/pthread mux unit and fake delegate; never load GL."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    source = Path(__file__).resolve().parent
    build = Path(tempfile.mkdtemp(prefix="lightclick-copy-mux-unit-", dir="/private/tmp"))
    common = ["/usr/bin/nice", "-n", "10", "/usr/bin/clang", "-std=c11", "-O1", "-g",
              "-Wall", "-Wextra", "-Werror", "-pthread"]

    def run(args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=20)
        if result.stdout:
            sys.stdout.write(result.stdout[:65536])
        if result.stderr:
            sys.stderr.write(result.stderr[:65536])
        if result.returncode:
            raise RuntimeError("command failed ({0}): {1}".format(result.returncode, args))

    run(common + ["-dynamiclib", "-undefined", "dynamic_lookup", str(source / "copy-mux.c"),
                  "-o", str(build / "mux.dylib")])
    variants = {"fake": None, "no-notify": "LC_FAKE_NO_NOTIFY",
                "missing-getter": "LC_FAKE_NO_GETTER", "bad-abi": "LC_FAKE_BAD_ABI",
                "null-callback": "LC_FAKE_NULL_CALLBACK", "recursive": "LC_FAKE_RECURSIVE"}
    for name, macro in variants.items():
        run(common + ["-Wno-unused-function", "-dynamiclib"] +
            (["-D" + macro] if macro else []) + [str(source / "fake-gl-delegate.c"),
                                               "-o", str(build / (name + ".dylib"))])
    run(common + ["-Wl,-export_dynamic", str(source / "test-copy-mux.c"),
                  "-o", str(build / "test-copy-mux")])
    os.link(build / "mux.dylib", build / "same-inode.dylib")
    print("build_dir=" + str(build), flush=True)
    for name in ("mux.dylib", "test-copy-mux"):
        print(name + " sha256=" + hashlib.sha256((build / name).read_bytes()).hexdigest(), flush=True)
    run(["/usr/bin/nice", "-n", "10", str(build / "test-copy-mux"), str(build / "mux.dylib"), str(build)])


if __name__ == "__main__":
    main()
