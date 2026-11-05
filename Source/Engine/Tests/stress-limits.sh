#!/bin/zsh
# Runs with a tiny code cache and shadow pool, so the reset and reclaim paths fire constantly. Results must not change.
here=${0:A:h}
images=$here/../.build/images
engine=$here/../.build/release/engine-run
small=300000
fail=0
for image in t_corpus_O2 t_corpus_O0 fuzz t_smc t_rep t_callret; do
    a=$(ENGINE_CC_BYTES= "$engine" "$images/$image" 2>&1 | grep -vE '^time|sites|^depth' | shasum)
    b=$(ENGINE_CC_BYTES=$small ENGINE_POOL_PAGES=64 "$engine" "$images/$image" 2>&1 | grep -vE '^time|sites|^depth' | shasum)
    if [[ "$a" == "$b" ]]; then echo "pass $image"; else echo "FAIL $image"; fail=1; fi
done
if ENGINE_CC_BYTES=$small ENGINE_POOL_PAGES=${1:-512} ENGINE_STATS=1 "$engine" --kernel "$images/kernel" 2>&1 | grep -E 'FAIL|^done|^exits|engine stop' | cut -c1-260; then :; fi
exit $fail
