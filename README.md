# portsh

portsh is a small Lisp in a single file which is *both* a valid POSIX `sh`
script and a Windows `.cmd` batch file. There's no runtime to install and no
machine code, so the same file runs anywhere there's a `/bin/sh` or a
`cmd.exe`, on any CPU. It's meant as a portable build/installer scripting
language — one script that runs commands, checks for files, and computes text
identically on Unix and Windows.

```sh
sh build-polyglot.sh          # build the single-file artifact, portsh.cmd
sh   portsh.cmd prog.lisp     # run a program on Unix
cmd /c portsh.cmd prog.lisp   # run it on Windows (real cmd.exe)
sh   portsh.cmd               # REPL (Unix)
cmd /c portsh.cmd             # REPL (Windows)
```

Programs produce byte-identical output on both platforms.

## How it executes

Both halves compile to their host shell — the Lisp is translated to `sh`
functions / batch files and *that* runs, not a tree-walker:

* **sh**: always JIT. Each run (and each REPL input) compiles and executes
  immediately; compilation is fast on sh.
* **cmd**: batch is too slow to recompile every run, so cmd is two-tier. The
  first run of this build self-extracts the compiler toolchain to
  `%LOCALAPPDATA%\portsh\<build>` (once). A cold program runs on a resumable
  interpreter while a background process compiles it into a per-program cache
  (keyed by content hash — editing the file invalidates it); the running
  interpreter switches to the compiled code function-by-function as it appears,
  mid-run. Warm runs execute compiled from the first call. The REPL warms the
  same way: definitions compile in the background and later calls use them.

Interpreted and compiled code interoperate live on one execution substrate
(shared frames, return stack, heap), so the switch is just a dispatch change at
a call boundary — no restarts, no replays, every side effect happens exactly
once.

## The language

```lisp
(if (file-exists? "Makefile")
    (run make)
    (run cc -o app main.c))              ; run a command, returns its exit code

(define me (car (run-capture whoami)))   ; capture stdout as a list of lines
(write-lines "hello.txt"
  (list (str "hello, " me)))             ; compute strings, line-oriented file I/O
```

Special forms: `define`, `lambda`, `if`, `quote`, `let`, `let*`, `cond`,
`and`, `or`, `when`, `unless`, `case`, `begin`, `list`, `str`. Primitives:
`cons`/`car`/`cdr`, `eq?`/`null?`/`pair?`/`atom?`/`number?`/`not`, `+ - * < =`,
`type-of`, `eval`, `read`, `print`; `run`/`run-capture` and `file-exists?` for
the host; `string-append`/`string-length`/`substring`/`split` plus the
`symbol`/`number`/`string` converters; `read-lines`/`write-lines`/
`append-lines`. The stdlib (`map`, `filter`, `foldl`, …) is ordinary Lisp on
top.

Two things are worth knowing, both forced by `cmd`: a **string is a single
line** (a batch variable can't hold a newline), so multi-line text is a *list
of line-strings* and file/command I/O is line-oriented; and functions are
values (`(map double xs)`, closures, `(define f (compose g h))`) compiled the
same way on both hosts.

## The polyglot trick

`sh` and `cmd.exe` each see a valid program in their own language: `:` is a
no-op in `sh` and a label in `cmd`; a `:<<'::CMDLITERAL'` heredoc hides the
batch half from `sh`; `@echo off` + `goto` steers `cmd` past the shell half.
The whole file is CRLF (which `cmd` needs to recognize labels), so line 1
re-execs `sh` on a CR-stripped temp copy of itself — a temp *file*, not a
pipe, so the REPL's stdin stays yours. The batch parsing quirks this project
ran into are catalogued in [`docs/batch-quirks.md`](docs/batch-quirks.md).

## The bootstrap kernel

`src/kernel.{sh,cmd}` is a tiny dual-implemented evaluator with a
`vau`/operative core — the trust root that can run the compiler from readable
source, and the substrate (reader, heap, driver) everything else is woven
from. `sh build.sh` weaves it into `portsh-kernel.cmd` (bare) and
`portsh-full.cmd` (with the stdlib bundled). These also support pack-by-
concatenation: `cat portsh-full.cmd myprog.lisp > myapp.cmd` makes a
self-contained app (`copy /b` on Windows).

## Testing

The same Lisp fixtures (`tests/lisp/*.lisp`, each with a golden `.out`) run on
every engine — the sh JIT, the cmd JIT, both resumable interpreters, and the
bootstrap kernels — and are diffed; differential testing across hosts and
engines is the conformance metric. All fixtures are byte-identical on
`dash`/`bash`/`mksh`/`zsh`/`ksh93` and real Windows `cmd.exe`.

```sh
sh tests/kernel.sh                             # bootstrap kernel, across every shell found
sh tests/weave.sh                              # the woven kernel, run as sh
PORTSH_WIN_SSH=user@vm sh tests/kernel-cmd.sh  # batch engines on a Windows VM
```

## Authorship

The design and implementation of portsh — the polyglot scaffolding, both
kernels, the compilers, the OSR execution model, the tests, and these docs —
are the work of **Claude** (Anthropic's Claude Opus 4.8), over an extended
pair-programming session. I, Akhil Indurti, directed the exploration and stood
up the Windows test VM, but the engineering is Claude's, and I'm not claiming
credit for it.
