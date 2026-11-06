#!/bin/zsh
# The engine's regression suite: sanity, the fuzz and test-i386 transcripts against Rosetta, SMC, the freestanding kernel.
here=${0:A:h}
images=$here/../.build/images
engine=$here/../.build/release/engine-run
fail=0

check_same() { # name image [args]
    local name=$1 image=$2
    shift 2
    if [[ "$(arch -x86_64 "$images/flatrun" "$images/$image" "$@" 2>&1 | grep -v '^time')" == "$("$engine" "$images/$image" "$@" 2>&1 | grep -v '^time')" ]]; then
        echo "pass $name"
    else
        echo "FAIL $name"
        fail=1
    fi
}

check_same sanity t_sanity
check_same smc t_smc
check_same rep t_rep
check_same x87 t_x87
check_same corpus-O0 t_corpus_O0
check_same corpus-O1 t_corpus_O1
check_same corpus-O2 t_corpus_O2
check_same corpus-O3 t_corpus_O3
check_same corpus-Os t_corpus_Os
check_same corpus-ssse3 t_corpus_ssse3
check_same fuzz fuzz
ENGINE_FAST_FLAGS=1 check_same fuzz-fast-flags fuzz
zsh "$here/diff-i386.sh" 4 | tail -1 | grep -q 'differences: 0$' && echo "pass test-i386" || { echo "FAIL test-i386"; fail=1; }

"$engine" --kernel "$images/kernel" > /dev/null && echo "pass kernel" || { echo "FAIL kernel"; fail=1; }
"$engine" --kernel-capi "$images/kernel" > /dev/null 2>&1 && echo "pass kernel through the C API" || { echo "FAIL kernel through the C API"; fail=1; }
"$engine" --hybrid "$images/hybrid" > /dev/null && echo "pass hybrid" || { echo "FAIL hybrid"; fail=1; }
ENGINE_HYBRID_SMP=1 ENGINE_ALARM=120 "$engine" --hybrid "$images/hybrid" > /dev/null && echo "pass hybrid, a second vCPU joining" || { echo "FAIL hybrid, a second vCPU joining"; fail=1; }
LC_HVDBT_NO_SHARE=1 "$engine" --hybrid "$images/hybrid" > /dev/null && echo "pass hybrid, no sharing" || { echo "FAIL hybrid, no sharing"; fail=1; }
LC_HVDBT_NO_REUSE=1 LC_HVDBT_NO_AHEAD=1 "$engine" --hybrid "$images/hybrid" > /dev/null && echo "pass hybrid, no reuse or translating ahead" || { echo "FAIL hybrid, no reuse or translating ahead"; fail=1; }

# 32-bit code in compatibility mode, in its own kernel. The transcript's hash is TCG's: Tests/diff-compat.sh --update writes it, after comparing with QEMU itself.
compat=$here/x86/compat
if ENGINE_TZCNT=1 ENGINE_ALARM=120 "$engine" --kernel "$images/compat" 2>/dev/null | python3 "$compat/transcript.py" "$compat/tcg-known.txt" | shasum | cut -d' ' -f1 | grep -qf "$compat/tcg-transcript.sha"; then
    echo "pass compat, as TCG's transcript"
else
    echo "FAIL compat: see Tests/diff-compat.sh"
    fail=1
fi
ENGINE_TZCNT=1 "$engine" --kernel-capi "$images/compat" >/dev/null 2>&1 && echo "pass compat through the C API" || { echo "FAIL compat through the C API"; fail=1; }
for vcpus in 2 4 8; do
    ENGINE_ALARM=60 "$engine" --smp $vcpus "$images/smp" > /dev/null && echo "pass $vcpus vCPUs" || { echo "FAIL $vcpus vCPUs"; fail=1; }
    ENGINE_SHARE=1 ENGINE_ALARM=60 "$engine" --smp $vcpus "$images/smp" > /dev/null && echo "pass $vcpus vCPUs, keeper rule" || { echo "FAIL $vcpus vCPUs, keeper rule"; fail=1; }
done
exit $fail
