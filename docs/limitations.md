# Limitations & possible future work

What portsh doesn't do, why, and what it would take. None of these block its
purpose (build/installer scripts); they'd matter for longer-running or more
demanding programs.

## Variadic lambda

`(lambda args body)` — a rest-parameter binding all arguments as a list — works
only on the bootstrap kernel, not on the shipped engines (the compilers and the
resumable interpreters use fixed-arity frames). `apply` exists and is the
workaround in the other direction (spreading a list into a fixed-arity call).
Supporting rest-args needs a dynamic argument count in the calling convention;
`apply`'s spread machinery is the natural starting point.

## No argv

A program can't see its command-line arguments yet; `./app.cmd foo bar` ignores
`foo bar`. Build scripts mostly read their environment via `run-capture`, but an
`(argv)` primitive is an obvious gap.

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
