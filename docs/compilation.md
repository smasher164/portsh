# Compiling portsh — and the Futamura projections

## Why compile at all

`cmd.exe` executes roughly one command per ~2ms, and a tree-walking interpreter
runs *hundreds* of commands per form — dispatch on tag, look up each symbol in
the environment, cons up argument lists. That's the batch ceiling: ~2.9s to
*parse* a line, ~2.4s to *evaluate* a single function call (measured on the test
VM). No micro-optimization escapes it; it's inherent to interpreting.

But the same function, hand-compiled to a batch subroutine, runs in ~0.002s — a
**~1000× gap**. Interpretation is the wall; compilation is the only way through.
That observation became the architecture: today **everything that runs, runs
compiled** — `eval` *is* compile-then-execute on both hosts. The `vau`/operative
core survives only as the stage-0 bootstrap kernel (the trust root that can run
the compiler from readable source); the shipped engines never tree-walk.

What replaced "JIT the hot path" is the two-tier OSR model (see the README):
on sh, every run compiles immediately (sub-second); on cmd, a cold program runs
on a *resumable interpreter* — itself a segment machine on the same execution
substrate as compiled code — while a background process compiles it into a
content-hash-keyed cache, and the running program switches to compiled code
function-by-function, mid-run, at call boundaries. Warm runs execute compiled
from the first call. `tools/pack-app.sh` goes one further: it AOT-compiles a
program at pack time and embeds the artifacts, so a packed app starts warm on
its first run.

A compiled call resolves dispatch, variable lookups (lexical addressing →
frame slots/temps), and argument shape **at compile time**, not per call.

### Generated code is quote-free

portsh strings have no `\"` escape, so the codegen literally cannot emit a `"`.
That's turned into a virtue: generated batch uses **no quotes** — line-oriented
output (a list of lines, written with `write-lines`), `set /a` into a temp, and
`set R=I:!_r!` on its own line (no trailing `&`, so no spurious space). Example,
`(lambda (n) (if (< n 0) (- 0 n) n))`:

```bat
:abs_1
set /a _a=%~2,_b=0
if !_a! LSS !_b! (set /a _r=(0-%~2)) else (set /a _r=%~2)
set R=I:!_r!
goto :eof
```

### Where generated code lives

You can't add labels to a running batch script, and cmd has no in-memory code —
so compiled functions are **files**: one tiny `.cmd` *per resumable segment*
(`<fn>_pc<N>.cmd`), dispatched by a driver loop. Per-segment files matter twice
over on cmd: `call :label` inside a big file costs O(label-offset) — it re-scans
the file — while `call file.cmd` opens a small file at a flat ~0.3ms; and the
driver `call`s every segment at host depth 1, which is what makes recursion
unbounded (cmd's native call stack dies at ~341 frames). The same explicit
control stack (CURFN/PC, return stack, frame slots) is shared with the
resumable interpreter — that shared substrate is what lets a running program
flip from interpreted to compiled at a call boundary with no restart.

## The compiler is a portsh program

The codegen (`form → batch lines`) is written in portsh Lisp itself
(`src/compile.lisp`), developed on the fast `sh` kernel. "Written once" — and it
sets up the genuinely beautiful part.

## The Futamura projections

Let `interp` be portsh's evaluator and `comp` the Lisp→batch compiler (a portsh
program). The classic projections describe a ladder portsh can actually climb:

1. **`comp(P)` = compiled P.** Specializing the interpreter to a program yields
   a compiled program. *Done, both hosts* — this is every warm run, and
   `tools/pack-app.sh` makes it a shippable artifact.

2. **`comp(comp)` = a standalone compiler.** Because `comp` is itself a portsh
   program, it compiles *itself*. *Done, both hosts*: `comp.sh` (the compiler
   compiled to sh — it also cross-emits the batch backend) and `comp-cmd/`
   (compiled to batch) are exactly this, validated byte-identical to the
   interpreted compiler's output. portsh is **self-hosting**; the shipped
   toolchain contains no interpreter in the compile path.

3. **A compiler-generator** (`comp` applied to itself once more) — the deep end,
   still aspirational.

The discipline the 2nd projection demands: `comp` must be written in the
**compilable subset**, so it can compile itself. That bootstrap constraint is the
through-line back to where this project began — a tiny dual kernel and a
bootstrapping tower, with as much as possible lifted into shared Lisp.

## Measured performance

Numbers from the (emulated, so inflated) Windows test VM, current architecture:

| path | time |
|---|---|
| packed app (`tools/pack-app.sh`), any run | ~1s |
| warm cached run (`portsh.cmd prog.lisp`, cache hit) | ~4s |
| cold first-contact run (interp + background compile, flips mid-run) | ~2min |
| REPL first prompt / per input | ~0.4s / 2–4s |
| sh, everything | ~1s |

The compiled-vs-interpreted gap that motivated all of this held up: the
resumable interpreter's floor is file-heap I/O per step (~6ms), while compiled
code runs the same step in microseconds-to-millis — which is why every tier of
the system exists to get programs onto compiled code and keep them there.

## Status

The ladder got climbed. The compiler (`src/compile.lisp` for batch,
`src/compile-sh.lisp` for sh) covers the whole language — closures via
lambda-lifting, first-class functions, the full primitive set, n-ary
arithmetic/chained comparisons, `apply` — and is self-hosted on both backends
with byte-identical-output guards (`tests/native-comp.sh`, `tests/cmd-parity.sh`).
The conformance bar is `tests/engines.sh`: every fixture, byte-identical across
five engines (sh JIT, sh interpreter, the shipped polyglot, cmd JIT, cmd
interpreter) plus `tests/pack.sh` for packed apps. What's deliberately *not*
here anymore: the record/replay bridge (retired for live OSR) and any
interpreter in the production compile path.
