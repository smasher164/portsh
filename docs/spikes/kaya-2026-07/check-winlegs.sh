#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The Windows leg matrix, asserted from the mac: vm.lisp's --dry plan
# for every scene×lang must name the right guest artifact, selftest,
# and output contract. This is the gate that replaces eyeballing 60
# cmd clones — portsh's sh half runs the SAME program the VM's cmd
# half runs, so what passes here is what deploys.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SCENES="milestone2 entry gallery todos reorder feed grow layout align window panels confirm"
LANGS="rust python go csharp java"

status=0
checked=0
# ONE portsh invocation for all plans: the sh half JIT-compiles per
# run (~26s under bash), so per-leg invocation would cost half an
# hour — legs-plan loops inside the program instead.
# shellcheck disable=SC2086
all=$(sh tools/guest/portsh.cmd tools/guest/vm.lisp legs-plan $SCENES 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
    echo "check-winlegs: legs-plan exited $code"
    printf '%s\n' "$all"
    echo "check-winlegs: FAIL"
    exit 1
fi
for s in $SCENES; do
    for l in $LANGS; do
        if [ "$s" = milestone2 ]; then name="$l"; selftest=1; else name="${s}_${l}"; selftest="$s"; fi
        out=$(printf '%s\n' "$all" | grep -A 1 "^LEG $name ")
        case "$l" in
            rust) want="C:\\kaya\\$s.exe" ;;
            python) want="python C:\\kaya\\$s.py" ;;
            go) want="go run dev.kaya/guests/go/$s" ;;
            csharp) want="dotnet run" ;;
            java) want="dev.kaya.milestone2kt.Main" ;;
        esac
        for needle in "selftest=$selftest" "$want" "> C:\\kaya\\out_$name.txt 2>&1"; do
            if ! printf '%s\n' "$out" | grep -qF "$needle"; then
                echo "check-winlegs: $name: plan lacks \"$needle\""
                printf '%s\n' "$out"
                status=1
            fi
        done
        checked=$((checked + 1))
    done
done

if [ "$status" = 0 ]; then
    echo "check-winlegs: OK ($checked legs planned and asserted)"
else
    echo "check-winlegs: FAIL"
fi
exit "$status"
