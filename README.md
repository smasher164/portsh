# portsh

portsh is a small Lisp in a single file which is *both* a valid POSIX `sh`
script and a Windows `.cmd` batch file. There's no runtime to install and no
machine code, so the same file runs anywhere there's a `/bin/sh` or a
`cmd.exe`, on any CPU. It's meant as a portable build/installer scripting
language — one script that runs commands, checks for files, and computes text
identically on Unix and Windows.

```sh
./portsh.cmd prog.lisp        # run a program on Unix
portsh.cmd prog.lisp          # run it on Windows (real cmd.exe)
./portsh.cmd                  # REPL (Unix)
portsh.cmd                    # REPL (Windows)
```

Programs produce byte-identical output on both platforms.

`portsh.cmd` is committed prebuilt (rebuild it with `sh build-polyglot.sh`).
`./portsh.cmd` works because a shebang is impossible in a file `cmd.exe` must
also parse, and POSIX shells run an executable that isn't a binary as an `sh`
script. Invoking it from something that isn't a shell needs `sh portsh.cmd`.
A clone keeps the execute bit; a `curl`/browser fetch of the single file does
not — `chmod +x portsh.cmd` once, or just use `sh portsh.cmd`. On Windows
it's a `.cmd`; it just runs.

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

## Packing an app

The quickest way, needing nothing but `portsh.cmd` itself (no repo, no tools):

```sh
./portsh.cmd pack prog.lisp app.cmd      # on Unix
portsh.cmd pack prog.lisp app.cmd        # on Windows
```

`app.cmd` is a byte-exact copy of `portsh.cmd` with `prog.lisp` embedded — one
self-contained polyglot that runs `prog.lisp` with any arguments. When you pack
**on Windows**, it AOT-compiles the program at pack time, so the app is **warm
on its very first run** (no interpreter, no background compile); packed **on
Unix** (no cmd compiler available there) it embeds the source and is warm-after-
cold on Windows, JIT on Unix. Either app runs on either host.

The app always carries the full engine — interpreter, compiler, and the source
— so it stays inspectable and recompilable, not an opaque blob.

To produce a warm-first-run app **from Unix**, use the repo tool, which
AOT-compiles via the sh-hosted cmd emitter:

```sh
sh tools/pack-app.sh prog.lisp app.cmd
```

(The bootstrap kernel has a slower low-tech cousin: `cat portsh-full.cmd
prog.lisp > app.cmd` — see "The bootstrap kernel".)

## The language

```lisp
(if (file-exists? "Makefile")
    (run make)
    (run cc -o app main.c))              ; run a command, returns its exit code

(define me (car (run-capture whoami)))   ; capture stdout as a list of lines
(write-lines "hello.txt"
  (list (str "hello, " me)))             ; compute strings, line-oriented file I/O

(run-argv (list tool "--in" my-file))    ; run a COMPUTED command: each element is exactly
                                         ; one child argument, spaces preserved, quoted per host
(define here                             ; the directory containing this program (argv0 is
  (join "/" (reverse (cdr (reverse      ;  absolute; a packed app sees the app file itself)
    (split (argv0) "/"))))))
(define exe (if (eq? (host) (quote cmd)) ; (host) = the executing host layer, sh or cmd --
              "tool.exe" "tool"))        ;  a baked constant, not environment sniffing
```

Special forms: `define`, `lambda` (fixed-arity or variadic — `(lambda args
body)` binds all arguments as a list), `if`, `quote`, `let`, `let*`, `cond`,
`and`, `or`, `when`, `unless`, `case`, `begin`, `list`, `str`. Primitives:
`cons`/`car`/`cdr`, `eq?`/`null?`/`pair?`/`atom?`/`number?`/`not`, `apply`,
arithmetic `+ - *` (n-ary, left fold; `(- x)` negates) and comparisons
`< <= = > >=` (chained, each operand evaluated once: `(< 1 3 2)` is nil),
`type-of`, `eval`, `read`, `print`, `exit`; `run`/`run-capture` (literal
tokens), `run-argv`/`run-capture-argv` (a *computed* list of tokens — each
element reaches the child as exactly one argument, spaces preserved), `argv`,
`argv0` (the invoked program's path — a packed app sees itself),
`host` (which host layer is executing: the symbol `sh` or `cmd` — a baked
constant per engine, not environment sniffing),
`getenv`/`setenv`, `file-exists?`, `make-dir`/`delete-file`/`copy-file` for the
host (file paths use forward slashes everywhere — normalized per host); `string-append`/`string-length`/`substring`/`split`/
`string-downcase`/`string-upcase` (ASCII) plus the
`symbol`/`number`/`string` converters; `read-lines`/`write-lines`/
`append-lines`. The stdlib (`map`, `filter`, `foldl`, …) is ordinary Lisp on
top.

Two things are worth knowing, both forced by `cmd`: a **string is a single
line** (a batch variable can't hold a newline), so multi-line text is a *list
of line-strings* and file/command I/O is line-oriented; and functions are
values (`(map double xs)`, closures, `(define f (compose g h))`) compiled the
same way on both hosts.

## A real example: the Gradle wrapper

The Gradle wrapper ships as a *pair* — `gradlew` plus `gradlew.bat` — checked
into millions of repositories, and the two halves are maintained (and drift)
separately. [`examples/gradlew.lisp`](examples/gradlew.lisp) is that wrapper as
one ~35-line portsh program: it resolves its own directory from `(argv0)`
(works from any cwd), locates `java` via `JAVA_HOME` — with the binary's name
as host data, the program's only host-sensitive line — and hands the user's
arguments through `run-argv`, so paths and arguments containing spaces survive
on both hosts. Packed once with `./portsh.cmd pack`, it becomes a single
`gradlew.cmd` replacing the pair.

```sh
./portsh.cmd pack examples/gradlew.lisp gradlew.cmd
```

## Another: an installer bootstrap

The other place the "one file, both hosts" niche shows up is tool installers,
where the convention today is a `curl | sh` script for unix and a separate
PowerShell one-liner or `.exe` for Windows.
[`examples/install-jq.lisp`](examples/install-jq.lisp) is one file doing that
whole job: it detects the OS and architecture (`(host)` plus `uname` /
`PROCESSOR_ARCHITECTURE`), downloads the right jq release binary with `curl`
(which Windows 10+ ships), fetches the release's published `sha256sum.txt`,
verifies the download (`sha256sum`/`shasum` on unix, `certutil` on Windows —
digests case-normalized with `string-downcase`), and installs the verified
binary. Refuses to install on a hash mismatch. Packed, it is a standalone
installer a Windows user can double-click.

## And a third: a diagnostics collector

[`examples/collect-diagnostics.lisp`](examples/collect-diagnostics.lisp) is
the "run this and send support the file" story: it gathers OS, environment,
and tool-availability facts into one identically-shaped report on both hosts.
It also demonstrates when to use which command form: `run`/`run-capture`
(literal tokens) for cmd *internal* commands like `ver` — they parse their raw
command line and reject quoted switches — and `run-argv`/`run-capture-argv`
(computed tokens) for external tools like `where`/`which`, which parse quoted
argv fine. Packed as `diagnose.cmd`, a Windows user double-clicks it and mails
back `diagnostics.txt`.

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

The same Lisp fixtures (`tests/engines/*.lisp`, each with a golden `.out`) run
on every engine — the sh JIT, the sh interpreter, the shipped polyglot, the
cmd JIT, and the cmd interpreter — and must be byte-identical to the golden;
differential testing across hosts and engines is the conformance metric. The
bootstrap kernels have their own fixture suite (`tests/lisp/`), byte-identical
across `dash`/`bash`/`mksh`/`zsh`/`ksh93` and real Windows `cmd.exe`.

```sh
sh tests/engines.sh                            # every engine, local legs
PORTSH_WIN_SSH=user@vm sh tests/engines.sh     # + the batch engines on a Windows VM
sh tests/kernel.sh                             # bootstrap kernel, across every shell found
```

## Authorship

The design and implementation of portsh — the polyglot scaffolding, both
kernels, the compilers, the OSR execution model, the tests, and these docs —
are the work of **Claude** (Anthropic's Claude Opus 4.8), over an extended
pair-programming session. I, Akhil Indurti, directed the exploration and stood
up the Windows test VM, but the engineering is Claude's, and I'm not claiming
credit for it.
