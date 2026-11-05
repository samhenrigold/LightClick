#!/bin/zsh
# Usage: build.sh <output directory>. Builds the flat x86 image, the spike, and the two comparison drivers.
set -eu
here=${0:A:h}
out=${1:?output directory}
mkdir -p "$out"

x86="-target x86_64-apple-macos10.9 -O2 -ffreestanding -fno-builtin -fno-vectorize -fno-slp-vectorize \
     -fno-jump-tables -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables"
clang ${=x86} -c "$here/workload.c" -o "$out/workload-x86.o"
clang ${=x86} -c "$here/entry.c" -o "$out/entry-x86.o"
ld -arch x86_64 -preload -e __start -no_uuid -segaddr __TEXT 0x100000 -pagezero_size 0 \
    -o "$out/flat.macho" "$out/entry-x86.o" "$out/workload-x86.o"
# __TEXT,__text only: the workload has no data, so a flat copy of the section is the whole image.
segedit "$out/flat.macho" -extract __TEXT __text "$out/flat.bin"

# The same x86 object runs under Rosetta. The arm64 build uses the same flags but its own target.
clang -target x86_64-apple-macos11 -O2 "$here/driver.c" "$out/workload-x86.o" -o "$out/driver-x86"
clang -target arm64-apple-macos11 -O2 -ffreestanding -fno-builtin -fno-vectorize -fno-slp-vectorize \
    -fno-jump-tables -fno-stack-protector -c "$here/workload.c" -o "$out/workload-arm64.o"
clang -target arm64-apple-macos11 -O2 "$here/driver.c" "$out/workload-arm64.o" -o "$out/driver-arm64"

clang -O2 -Wall -Wextra -framework Hypervisor "$here/spike.c" -o "$out/spike"
codesign --force --sign - --entitlements "$here/spike.entitlements" "$out/spike"
