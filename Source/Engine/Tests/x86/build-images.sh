#!/bin/zsh
# Usage: build-images.sh <output directory>. Builds flat x86-64 test images and the x86-64 runner used under Rosetta.
set -eu
here=${0:A:h}
out=${1:?output directory}
mkdir -p "$out"

flags=(-target x86_64-apple-macos10.9 -march=x86-64 -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-unwind-tables
    -fno-asynchronous-unwind-tables -fno-exceptions -mno-red-zone -I"$here" -Wno-incompatible-library-redeclaration -Wno-format)

link() { # name objects...
    local name=$1
    shift
    ld -arch x86_64 -preload -e _flat_start -no_uuid -pagezero_size 0 \
        -segaddr __TEXT 0x100000000000 -segaddr __DATA 0x100010000000 -o "$out/$name" "$@"
}

clang "${flags[@]}" -c "$here/flatlibc.c" -o "$out/flatlibc.o"
for prog in t_sanity; do
    clang "${flags[@]}" -c "$here/$prog.c" -o "$out/$prog.o"
    link "$prog" "$out/$prog.o" "$out/flatlibc.o"
done
clang -target x86_64-apple-macos11 -O1 "$here/flatrun.c" -o "$out/flatrun"

# The differential fuzz image.
python3 "$here/gen_fuzz.py" "$out/fuzz_forms.s"
clang -target x86_64-apple-macos10.9 -c "$out/fuzz_forms.s" -o "$out/fuzz_forms.o"
clang -target x86_64-apple-macos10.9 -c "$here/fuzz_support.s" -o "$out/fuzz_support.o"
clang "${flags[@]}" -c "$here/fuzz_driver.c" -o "$out/fuzz_driver.o"
link fuzz "$out/fuzz_driver.o" "$out/fuzz_forms.o" "$out/fuzz_support.o" "$out/flatlibc.o"
