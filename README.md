# portsh

portsh is a small Lisp interpreter that lives in a single file which is *both* a
valid POSIX `sh` script and a Windows `.cmd` batch file. There's no runtime to
install and no machine code, so the same file runs anywhere there's a `/bin/sh`
or a `cmd.exe`, on any CPU. It's meant as a portable build/installer scripting
language — one script that runs commands, checks for files, and computes text
identically on Unix and Windows.

```sh
sh build.sh                  # weave src/kernel.{sh,cmd} into portsh.cmd
sh   portsh.cmd prog.lisp    # run on Unix
cmd /c portsh.cmd prog.lisp  # run on Windows (real cmd.exe)
```

`build.sh` also writes `portsh-full.cmd`, which is `portsh.cmd` with the standard
library bundled in.

## Packing a self-contained app

`portsh.cmd` ends with a marker line, and everything after the marker is Lisp
that's evaluated at startup. So bundling a program with the interpreter is just
concatenation — no flag, no tool:

```sh
cat portsh.cmd      myprog.lisp > myapp.cmd   # bare interpreter + your program
cat portsh-full.cmd myprog.lisp > myapp.cmd   # + the standard library
```

On Windows that's `copy /b portsh.cmd + myprog.lisp myapp.cmd`. Either way
`myapp.cmd` runs `myprog.lisp` with no arguments (`sh myapp.cmd`, or a
double-click on Windows), and mixed line endings in the result are fine. It's
plain concatenation, so you can keep stacking: interpreter + stdlib + program.

## The language

A homoiconic Lisp with a `vau`/operative core (à la Kernel): the only special
forms baked into the interpreter are `vau`, `define`, and `if` — `lambda`,
`quote`, `list`, and the whole standard library (`let`, `cond`, `map`, `filter`,
`foldl`, …) are ordinary Lisp on top of it.

```lisp
(if (file-exists? "Makefile")
    (run make)
    (run cc -o app main.c))              ; run a command, returns its exit code

(define me (car (run-capture whoami)))   ; capture stdout as a list of lines
(write-lines "hello.txt"
  (list (str "hello, " me)))             ; compute strings, line-oriented file I/O
```

The interpreter provides `cons`/`car`/`cdr`, `eq?`/`null?`/`atom?`, `+ - * < =`,
`wrap`/`unwrap`/`eval`, `type-of`, `read`, `print`; `run`/`run-capture` and
`file-exists?` for the host; `string-append`/`string-length`/`substring`/`split`
plus the `symbol`/`number`/`string` converters; and `read-lines`/`write-lines`.
Anything derivable from those lives in the stdlib.

Two things are worth knowing, both forced by `cmd`: a **string is a single line**
(a batch variable can't hold a newline), so multi-line text is a *list of
line-strings* and file/command I/O is line-oriented; and `read` exposes the
interpreter's own reader, so things like string interpolation are libraries, not
language syntax — see `examples/interp.lisp`, which turns
`"i have (+ 0 5) fingers"` into `"i have 5 fingers"` using only `read` + a vau.

## How it runs

The file is a polyglot: `sh` and `cmd.exe` each see a valid program in their own
language, hidden from each other by the usual tricks — `:` is a no-op in `sh` and
a label in `cmd`; a `:<<'::CMDLITERAL'` heredoc hides the batch half from `sh`;
`@echo off` + `goto` steers `cmd` past the shell half. The one genuinely unusual
move: the whole file is CRLF (which `cmd` needs to recognize labels), so line 1
re-execs `sh` on a CR-stripped copy of itself so the shell half parses clean.

The cmd half is the harder one; the parsing quirks it imposes (and how portsh
works around them) are catalogued in [`docs/batch-quirks.md`](docs/batch-quirks.md).

Both halves implement the *same* tiny kernel — the only code written twice.
Everything above the kernel is Lisp, written once and run identically by both.
Cons cells are scalar shell variables (`eval`'d `H_i_a` names in `sh`,
`CAR_i`/`CDR_i` in batch). Speed isn't a goal, and that's the point: it keeps the
interpreter pure — no JScript, no awk, no bundled runtime, just the two shells.

## Testing

The same Lisp fixtures (`tests/lisp/*.lisp`, each with a golden `.out`) run on
both kernels and are diffed — differential testing across hosts is the
conformance metric. All fixtures are byte-identical on `dash`/`bash` and real
Windows `cmd.exe`.

```sh
sh tests/kernel.sh                             # sh kernel, across every shell found
sh tests/weave.sh                              # the woven portsh.cmd, run as sh
PORTSH_WIN_SSH=user@vm sh tests/kernel-cmd.sh  # batch kernel on a Windows VM
```

## Authorship

The design and implementation of portsh — the polyglot scaffolding, both kernels,
the tests, and these docs — are the work of **Claude** (Anthropic's Claude Opus
4.8), over an extended pair-programming session. I, Akhil Indurti, directed the
exploration and stood up the Windows test VM, but the engineering is Claude's,
and I'm not claiming credit for it.
