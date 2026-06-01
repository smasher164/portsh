# portsh

> One file. Runs as a POSIX `sh` script on Unix **and** as a Windows `.cmd`
> batch program — with no install, no runtime, on any CPU architecture.
> A *truly* portable shell.

## Authorship

The design and implementation of portsh — the polyglot scaffolding, both
interpreter kernels, the test harnesses, and this documentation — are the work
of **Claude** (Anthropic's Claude Opus 4.8), produced over an extended
pair-programming session. I, Akhil Indurti, directed the exploration, made the
design calls, stood up the Windows test VM, and am publishing the result — but
the engineering here is Claude's, and I'm **not** claiming credit for it.
Commits are co-authored accordingly.

## The idea

A single text file is structured as a **polyglot**: the Unix kernel/`sh` sees a
valid shell script; `cmd.exe` sees a valid batch file. The two halves hide each
other using the classic tricks (`:` is a no-op in `sh` and a label in `cmd`; a
quoted heredoc `:<<"::CMDLITERAL"` hides the batch block from `sh`;
`@echo off & goto :CMDSCRIPT` steers `cmd` past the shell block). Because the
artifact ships **no machine code**, it is architecture-agnostic by construction
— it runs wherever there is a `/bin/sh` or a `cmd.exe`.

## What it is

A small, dynamic, homoiconic **Lisp** — a build/installer language you can run
anywhere: execute commands via a `(run "...")` primitive, branch, do a little
computation, template config. The interpreter itself is written **in the
polyglot**, with **no external engine** — the only dependencies are `cmd` and
`sh`. Self-contained: bundle a user's Lisp script + the interpreter into one
polyglot executable that runs natively on Unix and double-clicks on Windows.

**Speed is an explicit non-goal.** That is precisely what lets the interpreter
be pure: no JScript, no awk, no bundled runtime — just the two shells.

## How it runs (no external engine)

The polyglot's `sh` half and its `cmd`/batch half each implement the **same
tiny Lisp kernel**. The kernel is the *only* code written twice; everything
above it is Lisp, written **once**, and run identically by both hosts:

- **Kernel (bilingual, small):** a `$vau`/`eval` core (operatives instead of a
  special-form table + macro system), a cons heap, environment lookup, char
  I/O, and a `(run ...)` primitive. Cons cells live in scalar variables
  (`CAR_i`/`CDR_i`) — `eval`'d dynamic names in `sh`, delayed expansion
  (`!CAR_%i%!`) in batch.
- **Userspace (shared, written once in Lisp):** the full reader, printer,
  macros, `let`/`cond`/`and`/`or`, the stdlib, numbers, and a trampolined
  evaluator so deep recursion doesn't blow the shells' shallow call stacks.

Cost, accepted on purpose: batch is the painful host (dynamic-name heap,
shallow recursion, CRLF discipline on `sh`-parsed lines). With speed waived,
these are correctness/effort issues, not performance ones, and the tiny-kernel
design bounds them. A pure-`awk` fast path on Unix could later hide behind the
same primitives — off by default; purity over throughput.

## Testing

The proposition is "same file, both worlds", so every fixture is run **both
ways** and diffed against golden output (`tests/run.sh`):

- **sh leg** — fan out across *every* shell we can find (`dash` = strict POSIX
  reference, `bash`, `mksh`, `busybox ash`). A portability bug is exactly
  "passes under one shell, fails another."
- **cmd leg** — needs a Windows-ish environment:
  - locally on Linux: **Wine** (`wine cmd /c …`);
  - on Apple-Silicon/darwin: **no local Windows** — the cmd leg is skipped and
    the real coverage comes from **CI on `windows-latest`** (`.github/workflows`),
    which is the trust anchor since Wine is only an approximation.
- once the interpreter exists, add **differential testing across hosts**: run a
  corpus of Lisp programs under the `sh`-hosted kernel and the `cmd`-hosted
  kernel; diff. Same program, same output, both worlds — that *is* the
  conformance metric.

```sh
nix develop          # dash bash mksh + gawk mawk (+ wine64 on linux) + bats/shellcheck
sh tests/run.sh      # run the fixtures
```

## Layout

```
flake.nix                 reproducible dev shell (shells, awks, qemu, wine-on-linux, bats)
build.sh                  weave the two kernels -> portsh.cmd
portsh.cmd                the built single-file polyglot interpreter
src/kernel.sh             sh-hosted vau-Lisp kernel
src/kernel.cmd            batch-hosted vau-Lisp kernel (port of kernel.sh)
tests/lisp/               NAME.lisp + NAME.out  (interpreter fixtures)
tests/kernel.sh           run fixtures on the sh kernel (local, multi-shell)
tests/weave.sh            build + run fixtures on portsh.cmd as sh (local)
tests/kernel-cmd.sh       run fixtures on the batch kernel in the VM (PORTSH_WIN_SSH)
docs/windows-vm.md        UTM Win11-ARM VM setup for real cmd.exe testing
examples/hello.cmd        minimal sh+cmd polyglot demo
.github/workflows/test.yml  unix (nix) + real windows legs
```

## Build & run

```sh
sh build.sh                 # weave src/kernel.{sh,cmd} -> portsh.cmd (one polyglot file)
sh   portsh.cmd prog.lisp   # run on Unix
cmd /c portsh.cmd prog.lisp # run on Windows (real cmd.exe)
```

`portsh.cmd` is a single file that is simultaneously a valid POSIX `sh` script
and a Windows batch file. The whole file is CRLF (cmd needs CR for labels); its
first line re-execs `sh` on a CR-stripped copy of itself so the sh kernel runs
clean, while cmd skips the sh half via `goto`.

## Status

**Working Lisp on both hosts, woven into one file.** A `vau`/operative core
(`define`/`if`/`vau` primitives) with `lambda`/`quote`/`list` and the rest in a
shared userspace prelude. Verified on `dash`/`bash` and on real Windows
`cmd.exe` (in a UTM Win11-ARM VM) — same fixtures, same output:

| fixture | meaning            | result |
|---------|--------------------|--------|
| arith   | nested arithmetic  | 15     |
| closure | lexical closure    | 15     |
| fact    | recursion/if/`<`   | 720    |
| rest    | rest args          | (1 2 3 4) |
| fexpr   | user-defined `vau` | 100    |

Tests: `tests/kernel.sh` (sh kernel, local), `tests/weave.sh` (woven file as sh,
local), `tests/kernel-cmd.sh` (batch kernel on the VM, `PORTSH_WIN_SSH=...`).

Open next: embed the Lisp payload in the file for a self-contained executable;
a faster batch heap (file scans make it ~15-36s/fixture); string literals + a
`run` primitive; a richer prelude (`let`/`cond`/`and`/`or`/`map`).
