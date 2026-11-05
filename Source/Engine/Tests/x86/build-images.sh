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
for prog in t_sanity t_smc t_callret t_rep; do
    clang "${flags[@]}" -c "$here/$prog.c" -o "$out/$prog.o"
    link "$prog" "$out/$prog.o" "$out/flatlibc.o"
done
clang -target x86_64-apple-macos11 -O1 "$here/flatrun.c" -o "$out/flatrun"

# The same algorithms at every optimisation level. flags already holds -O2; a later -O wins.
for level in 0 1 2 3 s; do
    clang "${flags[@]}" -O$level -c "$here/t_corpus.c" -o "$out/t_corpus_O$level.o"
    link "t_corpus_O$level" "$out/t_corpus_O$level.o" "$out/flatlibc.o"
done
clang "${flags[@]}" -mssse3 -O3 -c "$here/t_corpus.c" -o "$out/t_corpus_ssse3.o"
link t_corpus_ssse3 "$out/t_corpus_ssse3.o" "$out/flatlibc.o"

# QEMU's test-i386 in 64-bit mode.
qemu_tests=$here/../../../vendor/qemu/tests/tcg/i386
sed -e 's/"initcall"/"__DATA,initcall"/' -e 's/"loopl"/".byte 0x67; loop"/' -e 's/"loopzl"/".byte 0x67; loopz"/' -e 's/"loopnzl"/".byte 0x67; loopnz"/' -e 's/"enter" size " /size "enter /' -e 's/TEST_ENTER("q"/TEST_ENTER(""/' -e 's/TEST_ENTER("w"/TEST_ENTER(".byte 0x66;"/' -e 's/uc->uc_mcontext.gregs\[[A-Z_]*\]/0/g' \
    "$qemu_tests/test-i386.c" > "$out/test-i386-macho.c"
clang "${flags[@]}" -w -I"$out" -I"$qemu_tests" -c "$here/t_i386.c" -o "$out/t_i386.o"
clang "${flags[@]}" -w -c "$here/t_i386_stubs.c" -o "$out/t_i386_stubs.o"
link t_i386 "$out/t_i386.o" "$out/t_i386_stubs.o" "$out/flatlibc.o"

# The freestanding kernel, linked in the high half.
kflags=(-target x86_64-apple-macos10.9 -march=x86-64 -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-unwind-tables
    -fno-asynchronous-unwind-tables -mno-red-zone -static -w)
clang "${kflags[@]}" -c "$here/kernel/kernel.c" -o "$out/kernel.o"
clang -target x86_64-apple-macos10.9 -c "$here/kernel/kstubs.s" -o "$out/kstubs.o"
clang -target x86_64-apple-macos10.9 -c "$here/kernel/kentry.s" -o "$out/kentry.o"
ld -arch x86_64 -preload -e _kstart -no_uuid -pagezero_size 0 -segaddr __TEXT 0xFFFF800000100000 -segaddr __DATA 0xFFFF800000800000 \
    -o "$out/kernel" "$out/kentry.o" "$out/kernel.o" "$out/kstubs.o"

# The checks for hybrid mode: the same entry, no ring 3, no stubs of its own beyond its traps.
clang "${kflags[@]}" -mno-implicit-float -fno-vectorize -fno-slp-vectorize -c "$here/kernel/hybrid.c" -o "$out/hybrid.o"
ld -arch x86_64 -preload -e _kstart -no_uuid -pagezero_size 0 -segaddr __TEXT 0xFFFF800000100000 -segaddr __DATA 0xFFFF800000800000 \
    -o "$out/hybrid" "$out/kentry.o" "$out/hybrid.o"

# lc-bench's arithmetic.
clang "${flags[@]}" -w -I"$here/../../../probes" -c "$here/t_lcbench.c" -o "$out/t_lcbench.o"
clang "${flags[@]}" -w -c "$here/t_lcbench_stubs.c" -o "$out/t_lcbench_stubs.o"
link t_lcbench "$out/t_lcbench.o" "$out/t_lcbench_stubs.o" "$out/flatlibc.o"
xcrun clang -arch arm64 -O2 "$here/../../../probes/lc-bench.c" -o "$out/lc-bench-arm64"
xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O2 -w "$here/../../../probes/lc-bench.c" -o "$out/lc-bench-x86"

# The differential fuzz image.
python3 "$here/gen_fuzz.py" "$out/fuzz_forms.s"
clang -target x86_64-apple-macos10.9 -c "$out/fuzz_forms.s" -o "$out/fuzz_forms.o"
clang -target x86_64-apple-macos10.9 -c "$here/fuzz_support.s" -o "$out/fuzz_support.o"
clang "${flags[@]}" -c "$here/fuzz_driver.c" -o "$out/fuzz_driver.o"
link fuzz "$out/fuzz_driver.o" "$out/fuzz_forms.o" "$out/fuzz_support.o" "$out/flatlibc.o"
