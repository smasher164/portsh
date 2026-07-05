# Limitations & possible future work

What portsh doesn't do, why, and what it would take. None of these block its
purpose (build/installer scripts); they'd matter for longer-running or more
demanding programs.

## The host layer carries host caveats

`(argv)` returns the arguments after the program path (a packed app sees all of
its arguments); `(argv0)` returns the invoked program's path, absolute with
forward slashes on both hosts — for a packed or concat app that is the app file
itself (the temp-extracted program is an implementation detail), for
`portsh.cmd PROG.lisp` it is PROG.lisp, and in the REPL it is nil;
`(run-argv LIST)`/`(run-capture-argv LIST)` are the applicative counterparts of
the `run`/`run-capture` operatives — the single argument is a computed list of
tokens, and each element reaches the child as exactly one argument (quoted per
host, so spaces survive; `!`/`%` remain best-effort on cmd, and a portsh string
cannot contain `"` so quote-escaping never arises);
`(getenv "NAME")`/`(setenv "NAME" "v")` read and write the
process environment (inherited by `run` children); `(exit n)` sets the script's
exit code; `make-dir`/`delete-file`/`copy-file` are the portable file ops
(mkdir -p / rm -f / overwrite semantics, t/nil results, forward-slash paths
normalized per host). The caveats are the hosts': cmd cannot store an empty
environment variable, so **empty == unset == nil on both hosts** and setting a
variable to `""` unsets it; environment names are case-insensitive on cmd and
case-sensitive on sh (use exact-case names); names are restricted to
`A-Za-z0-9_`; engine-internal names (and `PATH`, which the cmd runtime
resolves its own primitives through — it re-prepends its cache dirs after any
`PATH` set) are best left alone except through `setenv`; and argument/value
text containing cmd metacharacters (`!`, `%`) is best-effort on Windows -- the
portable subset is plain tokens, which the conformance suite pins
byte-identical across every engine.

## Stdlib edges: the control forms are forms, not values

The applicative stdlib (`map`/`foldl`/`filter`/`member?`/`->string`/`str`/...)
is AOT-compiled into every engine and works as both operators and first-class
values; the arithmetic/comparison/test primitives (`+ - * < <= = > >=`,
`number?`/`string?`/... ) have value-position wrappers; and `(define f g)`
aliases a function by evaluating `g` at define time. What you cannot pass as a
value are the control forms — `and`/`or`/`when`/`unless`/`cond`/`let`/`case`
(and `if`/`define` themselves) — which expand at compile time, as in any Lisp
with macros.

## Strings are single lines

A batch variable can't hold a newline, so a portsh string is always one line and
multi-line text is a *list of line-strings*; file and command I/O are
line-oriented (`read-lines`, `write-lines`, `run-capture`). This is a design
contract, not a bug, but it surprises people.

## Integers only, and the widths differ across hosts

Arithmetic is the host shell's: `$(( ))` on sh (64-bit on most shells) and
`set /a` on batch (**32-bit signed**). A computation that overflows 32 bits
agrees on the two hosts only below that threshold — a real cross-host divergence
for large numbers, currently unguarded. No floats, no bignums.

## Garbage collection is asymmetric

The **sh** engines have a real mark-sweep GC (free-list reuse, triggered on
heap growth; frames and an index-slot root stack make the root set precise), so
allocate-in-a-loop programs run in bounded memory. The **cmd** heap is
file-backed (two small files per cell) and effectively append-only within a
run: nothing reclaims cells, so a cmd program that allocates unboundedly grows
its heap directory until the process exits (the per-run heap dir is deleted on
exit, so nothing persists). File-backed cells don't slow down as the heap grows
— this is a disk-space ceiling, not a speed one — but a long-running allocating
loop on cmd will eventually feel it.

## Recursion is unbounded, but cmd recursion is slow

Both engines run on an explicit-control-stack trampoline: logical recursion
depth is bounded by memory, not the host call stack (cmd's native `call` dies
at ~341 frames; compiled portsh recurses hundreds of thousands deep). Deep
non-tail recursion on cmd still costs file-heap I/O per frame, so prefer
iteration/tail calls for hot loops there.

## Speed, on Windows

The asymmetry between hosts is permanent — cmd executes roughly one command per
millisecond and every heap access is file I/O — but the architecture works
around it: programs are compiled (never tree-walked) once warm, caches are
keyed by content hash, and a cold run interprets while a background process
compiles, flipping function-by-function as artifacts land. Current shape, on
an emulated test VM: a packed app (AOT, `tools/pack-app.sh`) starts in ~1s; a
warm cached run ~4s; a first-contact cold run of a small script ~2min with
output streaming as it executes; the REPL prompts in under half a second and
costs a few seconds per input. sh runs everything in about a second. The
remaining cold floor is the resumable interpreter's per-step file I/O —
architectural, and only paid until the cache warms.

## Mid-call OSR

A function flips from interpreted to compiled at its next *call*, not in the
middle of an in-flight activation. A long-running single call (one giant loop
in one function) therefore never flips within that call. Call-boundary flips
cover recursion and repeated calls, which is why this hasn't mattered in
practice; true on-stack replacement (translating a live interpreter frame to a
compiled frame mid-activation) is designed but unimplemented.
