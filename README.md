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
other with the classic tricks — `:` is a no-op in `sh` and a label in `cmd`; a
quoted heredoc `:<<'::CMDLITERAL'` hides the batch block from `sh`; `@echo off`
+ `goto :CMDSTART` steers `cmd` past the shell block — plus a re-exec on line 1
that runs `sh` on a CR-stripped copy so the all-CRLF file (which `cmd` needs for
labels) doesn't choke `sh`. Because the artifact ships **no machine code**, it
is architecture-agnostic by construction — it runs wherever there is a
`/bin/sh` or a `cmd.exe`.

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

- **Kernel (bilingual, small):** a `vau`/`eval` core — operatives instead of a
  special-form table — plus a cons heap, environment, and primitives
  (`cons`/`car`/`cdr`, arithmetic, `eval`/`wrap`, `run`/`run-capture`, strings
  (`string-append`/`substring`/…), line I/O (`read-lines`/`write-lines`),
  `file-exists?`, …).
  Cons cells are scalar shell variables: `eval`'d dynamic names (`H_i_a`) in
  `sh`, `CAR_i`/`CDR_i` in batch.
- **Userspace (shared, written once in Lisp):** apart from a tiny reader
  bootstrap, `lambda`/`quote`/`list` and the whole stdlib
  (`let`/`cond`/`and`/`or`/`map`/`filter`/`foldl`/…) are plain Lisp, evaluated
  identically on both hosts.

Cost, accepted on purpose: batch is the painful host (dynamic-name heap, no
`setlocal` in the eval path, shallow host recursion, CRLF discipline on
`sh`-parsed lines). With speed waived these are correctness/effort issues, not
performance ones, and the tiny-kernel design bounds them.

## Testing

"Same file, both worlds" is the proposition, so the same Lisp fixtures
(`tests/lisp/*.lisp`, each with a golden `*.out`) run on **both** kernels and
are diffed — differential testing across hosts is the conformance metric:

- `tests/kernel.sh` — run the fixtures on the `sh` kernel across every shell
  found (`dash`/`bash`/…). Fast, local.
- `tests/weave.sh` — build `portsh.cmd` and run the fixtures through it *as a
  sh script*, exercising the woven polyglot + the re-exec header. Local.
- `tests/kernel-cmd.sh` — run the fixtures on the **batch** kernel inside a real
  Windows VM over SSH (`PORTSH_WIN_SSH=user@vm`); see `docs/windows-vm.md`.
- CI (`.github/workflows/test.yml`) runs a Nix unix leg + a real
  `windows-latest` leg.

```sh
nix develop                                    # shells + awks + qemu + bats/shellcheck
sh tests/kernel.sh                             # sh kernel (multi-shell)
sh tests/weave.sh                              # woven portsh.cmd, run as sh
PORTSH_WIN_SSH=user@vm sh tests/kernel-cmd.sh  # batch kernel on the Windows VM
```

## Layout

```
flake.nix                 reproducible dev shell (shells, awks, qemu, wine-on-linux, bats)
build.sh                  weave the two kernels -> portsh.cmd (+ portsh-full.cmd)
portsh.cmd                built single-file polyglot interpreter (bare)
portsh-full.cmd           built interpreter + bundled stdlib
src/kernel.sh             sh-hosted vau-Lisp kernel
src/kernel.cmd            batch-hosted vau-Lisp kernel (port of kernel.sh)
src/stdlib.lisp           userspace stdlib (let/cond/and/or/map/filter/foldl/…)
tests/lisp/               NAME.lisp + NAME.out  (interpreter fixtures)
tests/kernel.sh           run fixtures on the sh kernel (local, multi-shell)
tests/weave.sh            build + run fixtures on portsh.cmd as sh (local)
tests/kernel-cmd.sh       run fixtures on the batch kernel in the VM (PORTSH_WIN_SSH)
tests/win-smoke.sh        smoke-test the Windows VM pipeline over SSH
docs/windows-vm.md        UTM Win11-ARM VM setup for real cmd.exe testing
examples/hello.cmd        minimal sh+cmd polyglot demo
examples/demo.lisp        stdlib demo (map/filter/foldl/cond/let/…)
examples/build.lisp       portable build script (run + if + file-exists?)
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

## Packing a self-contained app

`portsh.cmd` ends with a marker line, and everything after the marker is Lisp
that's evaluated at startup. So bundling a program with the interpreter is just
**concatenation** — no flag, no tool:

```sh
cat portsh.cmd      myprog.lisp > myapp.cmd   # bare interpreter + your program
cat portsh-full.cmd myprog.lisp > myapp.cmd   # + the bundled stdlib
```

On Windows the equivalent is `copy /b portsh.cmd + myprog.lisp myapp.cmd`. Both
are verified to produce a working `myapp.cmd` on both OSes (mixed line endings
are fine — the sh side strips CRs, the cmd side reads the payload by line).

`myapp.cmd` now runs `myprog.lisp` with **no arguments** — `sh myapp.cmd` on
Unix, double-click on Windows. It's layered: `portsh-full.cmd` is literally
`portsh.cmd` with `stdlib.lisp` concatenated on, and you can stack further
(interpreter + stdlib + program).

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
| string  | string literal     | hello world |
| strings | string primitives  | foobarbaz/5/world/… |
| ioline  | write/read-lines + run-capture | alpha/beta/5/cap-line |

Tests: `tests/kernel.sh` (sh kernel, local), `tests/weave.sh` (woven file as sh,
local), `tests/kernel-cmd.sh` (batch kernel on the VM, `PORTSH_WIN_SSH=...`).

Running commands: `(run tok ...)` renders its unevaluated operands into a
command line and executes it on the host shell — `(run echo hi)`, `(run gcc -o
foo foo.c)` — returning the exit code. `(file-exists? "path")` returns `t`/`()`
for build conditionals. See `examples/build.lisp`.

Text & I/O: strings are first-class — `string-append`, `string-length`,
`substring`, and the `symbol`/`number`/`string` converters compute strings
directly. Because a host shell variable can't hold a newline, **a string is a
single line** and multi-line text is a *list of line-strings*; I/O is therefore
line-oriented: `(read-lines "path")` → list of lines, `(write-lines "path"
lines)` writes them, and `(run-capture cmd …)` runs a command and returns its
stdout as a line list (vs. `run`, which streams to the console and returns the
exit code). All verified identical on `sh` and real `cmd.exe`. (Batch caveats,
both from `for /f`: a blank line and a line beginning with `;` are dropped by
`read-lines`/`run-capture` — fine for typical line data, divergent for files
that rely on either.)

Syntax parity: the readers agree on both hosts — `'x` quote-shorthand, `;`
line comments (inline and full-line), and `"..."` string literals all parse
identically on `sh` and `cmd`. (The one batch corner: a `;` *inside* a string
literal is treated as a comment; rare, and the only known reader divergence.)

Performance: the batch kernel uses a variable-based heap (O(1) `cons`/`car`/
`cdr`/`set-car`/`set-cdr`) and inlines the heap accessors in the hot paths
(`env_lookup`/`ev`/`eval_list`/`combine_oper`), with move-to-front lookup —
`fact(6)` on real `cmd` went 33s → ~18s. That's plenty for build scripts;
deeply recursive numeric code is still slow on `cmd` (each step is many `cmd`
`call`s) — fine, since speed was never the goal. The `sh` kernel is fast.

Open next: the text core landed (strings + line I/O + `run-capture`), so the
gap is now **userspace ergonomics on top of it** — a `string-split`/`string-join`
pair, `path-join`, `starts-with?`/`contains?`, and a small templating helper —
all writable in plain Lisp in `stdlib.lisp`, no kernel work. Deliberately *not*
planned: streaming, file descriptors, byte-level I/O — portsh is a line-oriented
text language and delegates binary/streaming to `(run …)` + the host shell.
