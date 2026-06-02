# Limitations & possible future work

What portsh deliberately doesn't do yet, why, and what it would take. None of
these block its purpose (short-lived build/installer scripts); they'd matter for
longer-running or more demanding programs.

## No garbage collection

The cons heap is **append-only**. `cons` only ever increments the next-cell
counter (`HEAP_N` in sh, `HN` in batch); nothing is ever reclaimed, so a program
that allocates in a loop grows memory without bound. This is fine for a build
script that runs once and exits, but it rules out long-running processes.

A real GC is possible but awkward in this substrate: cells live in shell
variables (`H_i_a`/`CAR_i`), so collection means tracing from the roots (the
global env + the active call frames) and *unsetting* the dead cells' variables —
plus a free list or compaction to reuse the names. Mark-and-sweep is the natural
fit. Until then, the heap is a bump allocator with no free.

## No REPL

portsh runs a program — a file argument, or the Lisp packed after the marker —
straight through to completion. There's no interactive read-eval-print loop.

Now that `read` (string → datum) and `eval` are primitives, a REPL is just
userspace Lisp: loop over `read-lines`/stdin, `read` each line, `eval` it in the
global env, `print` the result. The likely path is a small `examples/repl.lisp`
rather than anything in the kernel.

## Recursion is bounded by the host

There's no tail-call optimization; Lisp recursion uses host-shell recursion. On
**batch** that hits a hard wall fast — `****** BATCH RECURSION exceeds STACK
limits ******` at a few hundred frames (see `docs/batch-quirks.md`). `sh` goes
much deeper but is still bounded. Deeply recursive algorithms should be written
iteratively, or wait for trampolining/TCO in the evaluator.

## Integers only, and the widths differ across hosts

Arithmetic is the host shell's: `$(( ))` on sh (64-bit on most shells) and
`set /a` on batch (**32-bit signed**). So a computation that overflows 32 bits
agrees on the two hosts only below that threshold — a real cross-host divergence
for large numbers, currently unguarded. There are no floats and no bignums. A
portable fixed-width contract (or software bignums) is future work.

## Speed, on Windows

The `sh` kernel is fast (the reader is O(n); a build script's stdlib loads in
well under a second). The **batch** kernel is the slow host: every `cons`/`car`/
`cdr` is several `cmd` `call`s/`set`s, and the reader still advances the source
one char at a time (O(n²)). Optimizing the batch reader and cutting per-op
overhead is the open perf frontier; cmd's fundamental per-command cost bounds how
far it can go.
