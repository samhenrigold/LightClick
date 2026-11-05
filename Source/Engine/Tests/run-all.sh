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
check_same corpus-O0 t_corpus_O0
check_same corpus-O1 t_corpus_O1
check_same corpus-O2 t_corpus_O2
check_same corpus-O3 t_corpus_O3
check_same corpus-Os t_corpus_Os
check_same fuzz fuzz
ENGINE_FAST_FLAGS=1 check_same fuzz-fast-flags fuzz
zsh "$here/diff-i386.sh" 4 | tail -1 | grep -q 'differences: 0$' && echo "pass test-i386" || { echo "FAIL test-i386"; fail=1; }

"$engine" --kernel "$images/kernel" > /dev/null && echo "pass kernel" || { echo "FAIL kernel"; fail=1; }
exit $fail
