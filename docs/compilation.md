# Compiling portsh — and the Futamura projections

## Why compile at all

`cmd.exe` executes roughly one command per ~2ms, and a tree-walking interpreter
runs *hundreds* of commands per form — dispatch on tag, look up each symbol in
the environment, cons up argument lists. That's the batch ceiling: ~2.9s to
*parse* a line, ~2.4s to *evaluate* a single function call (measured on the test
VM). No micro-optimization escapes it; it's inherent to interpreting.

But the same function, hand-compiled to a batch subroutine, runs in ~0.002s — a
**~1000× gap**. Interpretation is the wall; compilation is the only way through.
So the plan for a genuinely fast Windows host is a **Lisp→batch compiler (JIT)**.

## The approach: JIT the hot path, interpret the dynamic core

portsh's `vau`/operative core is what makes it elegant (a tiny kernel, the rest
userspace) and *also* what resists full compilation: operatives (fexprs) receive
their operands unevaluated plus the dynamic environment and decide at runtime
what to evaluate — the antithesis of compilation. So:

- **Compile** applicative functions (`lambda`) over arithmetic, `if`, comparisons,
  and calls — the iterative/numeric guts of a build script.
- **Interpret** the dynamic remainder (`vau`, `eval`, fexprs). It stays correct;
  it just isn't fast — and that's fine, because the hot path is compiled.

A compiled call resolves dispatch, variable lookups (lexical addressing →
`%1`/temps), and argument shape **at compile time**, not per call.

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
so compiled functions are **files**. A per-run temp dir holds one generated
`.cmd` (all compiled functions as labels, dispatched by `goto %1`); the
interpreter binds a compiled function to a `C:label` tag and dispatches it with
`call …\compiled.cmd label args`. External calls measured ~2.7ms — as cheap as
an internal `call :label`, so this is free.

## The compiler is a portsh program

The codegen (`form → batch lines`) is written in portsh Lisp itself
(`src/compile.lisp`), developed on the fast `sh` kernel. "Written once" — and it
sets up the genuinely beautiful part.

## The Futamura projections

Let `interp` be portsh's evaluator and `comp` the Lisp→batch compiler (a portsh
program). The classic projections describe a ladder portsh can actually climb:

1. **`comp(P)` = compiled P.** Specializing the interpreter to a program yields a
   compiled program. This is the JIT: the interpreter runs and compiles hot
   functions as it meets them. *(Where we are.)*

2. **`comp(comp)` = a standalone compiler.** Because `comp` is itself a portsh
   program, it can compile *itself* into a batch program — call it `portshc.cmd`
   — that turns Lisp into batch **with no interpreter involved**. That is exactly
   "invoke the compiler without first running the interpreter": you've compiled
   the compiler. portsh becomes **self-hosting**.

3. **A compiler-generator** (`comp` applied to itself once more) — the deep end,
   aspirational.

The discipline the 2nd projection demands: `comp` must be written in the
**compilable subset**, so it can compile itself. That bootstrap constraint is the
through-line back to where this project began — a tiny dual kernel and a
bootstrapping tower, with as much as possible lifted into shared Lisp.

## Status

- ✅ codegen (`src/compile.lisp`) for arithmetic, comparisons, `if`
  (goto-based), params, value return, and **tail self-recursion** (loops →
  `goto`, TCO for free). Quote-free batch, developed on `sh`.
- ✅ verified on **real cmd.exe**: a compiled `loop(1000)` returns the right
  answer, runs ~8× faster per iteration than the interpreter, and — unlike the
  interpreter — does **not** hit the recursion-stack crash at large N. (Absolute
  times are inflated by the battery/emulated test VM; relative win holds, and
  closes most of the gap to bash on real hardware.)
- ✅ **kernel integration**: `C:<label>` dispatch in `combine` (eval operands →
  call the generated sub → `R` back), `make-compiled` to bind a name to its
  label. A `(define f (make-compiled …))` + `(f …)` runs native compiled batch;
  all fixtures still interpret correctly.
- ✅ **the driver + full AOT flow**: `compile-program` (with a Lisp `show`
  printer) rewrites a program — each compilable `(define f (lambda …))` becomes a
  compiled sub in `compiled.cmd` plus a `make-compiled` binding in the residual;
  everything else passes through. Verified end-to-end: **compiled on the fast sh
  kernel, the residual runs on real cmd.exe** and returns the right answer by
  executing compiled batch. This is "compile on sh, run on batch."
- ▢ broaden codegen: calls to *other* functions; cons/list/string via direct
  primitive calls (toward covering what `comp` itself needs).
- ▢ self-hosting: compile `comp` with `comp` → `portshc.cmd`.
