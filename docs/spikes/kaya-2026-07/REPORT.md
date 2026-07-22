# The kaya spike — 2026-07-21, portsh @ 395371d

kaya (the cross-platform GUI project) tried adopting portsh for its
Windows-VM test tooling and concluded **not viable as portsh stands**,
with the interpreter reverted out of the repo the same day. This
report is the detailed account: what the use-case is, what worked
(some of it very well), the six findings with reproducers, and what
would flip the verdict. Everything referenced sits beside this file.

## The use-case portsh was tried for

kaya's Windows suite runs 60 legs (12 scenes × 5 guest languages) on
an ARM64 Windows 11 VM (UTM, build 10.0.26200), driven from macOS by
a bash orchestrator over OpenSSH (default shell: cmd.exe) and
schtasks interactive-desktop sessions. Before the spike that meant
60 near-identical hand-cloned `.cmd` files (one per leg — a
forgotten-clone defect class with a track record) plus inline
`run_ssh 'cmd /c "..."'` strings, which had just produced a real
trap: Windows sshd re-wraps every command in its own `cmd /c "..."`,
so interior double quotes re-pair across the line and a chained
command can silently no-op with exit 0.

The portsh design that replaced them — `vm.lisp` here, ~200 lines —
is ONE program with subcommands (`leg NAME [--dry]`, `prep`,
`build-java`, `provision`, `provision-full`, `kill SCENE...`,
`legs-plan SCENE...`): the whole leg matrix as a dispatch table, all
provisioning idempotent, no inline remote strings anywhere. The
shape is exactly portsh's pitch, and most of it worked.

## What worked (worth keeping in mind as the good half)

- **The language carried the program.** vm.lisp needed nothing
  exotic: `run-argv`/`run-capture-argv`, `setenv`, `str`, `cond`,
  lists. Writing it took under an hour cold.
- **The sh half as a test harness for cmd-destined logic** is a
  genuinely great pattern: `check-winlegs.sh` (beside this file)
  asserts the composed plan for all 60 legs ON THE MAC via a
  `--dry` mode — the leg matrix became host-side-testable without a
  VM round trip. This is the pattern kaya wants back once the
  findings below are addressed.
- **Desktop-session execution was clean**: via schtasks (`/it`,
  interactive), `portsh.cmd hi.lisp` ran perfectly, including the
  LOCALAPPDATA self-extraction under that session.
- `pack` was deliberately not used (per-script bundling rejected as
  wasteful and hard to debug); the vendored-interpreter +
  plain-source model felt right and would have shipped.

## Finding 1 — the blocker: startup failure under Windows sshd's cmd

`cmd /c C:\kaya\portsh.cmd C:\kaya\hi.lisp` over OpenSSH (BatchMode,
non-interactive, default cmd shell) fails with
`The syntax of the command is incorrect.` before the program runs —
for ANY program, including `(print "hi")`. The identical file (hash
verified both sides) runs fine from a schtasks desktop session on
the same machine.

`repro/ssh-ladder.sh` is the one-command reproducer; its 2026-07-21
results:

| invocation | result |
|---|---|
| plain `mini.cmd` baseline | ok |
| `cmd /c portsh.cmd hi.lisp` | **fails** |
| `cmd /c call portsh.cmd hi.lisp` | **fails** |
| `cmd /e:on /d /c portsh.cmd hi.lisp` | **fails** |
| `cmd /c portsh.cmd hi.lisp <nul` | ok |
| `cmd /c cd /d C:\kaya & portsh.cmd hi.lisp` | ok (the `&` splits at sshd's outer cmd — portsh runs un-nested) |

Two variables separate pass from fail: stdin (ssh channel vs `nul`)
and cmd-nesting depth. Suspects: something in the bootstrap probing
stdin (REPL detection?), or `%CMDCMDLINE%`-sensitive self-parsing
meeting sshd's wrapper. Worth fixing regardless of kaya: "run a
portsh program over ssh on a Windows box" is squarely the tool's
territory.

## Finding 2 — residual failures even with `<nul` (unresolved)

With stdin nulled, `vm.lisp provision` got further (its go127
present-check printed) but the run emitted repeated
`The system cannot find the path specified.` lines and the JDK
check's branch never reported; the suite was aborted when the spike
was called off, so this one is **observed but not diagnosed** —
`repro/residual-anomaly.log` is the verbatim excerpt. Treat finding
1's fix as the prerequisite to re-diagnosing this cleanly.

## Finding 3 — sh-side per-run JIT cost

A trivial `--dry` invocation of vm.lisp costs **~26s wall** under
the sh half (bash 5.x from a nix dev shell, Apple Silicon):

    time (sh portsh.cmd vm.lisp leg entry_rust --dry)
    # 18.12s user 7.43s system 96% cpu 26.411 total

cmd got the two-tier content-hash cache precisely because batch is
slow; bash apparently needs the same mercy. kaya's workaround —
`legs-plan` printing all 60 plans in ONE invocation — worked (~30s
total) but shapes the program around the tool. Want: a warm cache
for sh, or a documented dash-class fast path if the cost is
bash-specific.

## Finding 4 — run-capture stderr asymmetry

The cmd runtime merges child stderr into the capture
(`src/runtime.cmd:459`, redirect-first `2>&1`); the sh kernel
captures stdout only (`src/kernel.sh`, `po_out=$(sh -c "$po_cmd")`).
Any program that observes a child's error text behaves differently
per host — against the byte-identical promise. kaya's leg runner
needs merged output (crash text in the captured log is how real
failures get diagnosed). Want: merge on sh too, or an explicit
merged/unmerged pair.

## Finding 5 — run-capture discards the child's exit code

`run` returns the code, `run-capture` returns the lines; a caller
needing BOTH (the leg contract: output file plus a trailing
`EXIT=n`) must route through host redirection —
`(run-argv (list "cmd" "/c" (str cmd " > " out " 2>&1")))` — which
resurrects exactly the string-assembly the tool exists to avoid.
Want: a capture form that also yields the code, or a last-exit-code
primitive.

## Finding 6 — missing small primitives

Hit twice in 200 lines: **no recursive directory delete**
(`delete-file` is `rm -f`-shaped) and **no directory listing/glob**
(vm.lisp shells out to `dir /b /ad` to find a versioned
`llvm-mingw-*` dir). Both forced host-tool fallbacks inside an
otherwise portable program. Want: `delete-tree`, `list-dir`.

## Smaller notes

- **No-quotes-in-strings** made `powershell -Command "..."`
  unwritable — which turned out fine (curl + tar ship with Windows
  and are cleaner), but a docs note steering people to that pattern
  would save the discovery.
- **Vendoring**: with a `*.cmd text eol=crlf` gitattribute in the
  consuming repo, pin the file with `portsh.cmd -text` to keep the
  vendored bytes exact.
- `%`/`!` best-effort on cmd was never hit (plain-token discipline
  held throughout).

## What would flip the verdict for kaya

Finding 1 fixed (the blocker), finding 2 re-diagnosed on top of it,
and findings 4+5 (honest captured output with exit codes) — at that
point vm.lisp and check-winlegs.sh, both preserved here verbatim,
drop back in as-is: the kaya side of the integration was finished
and its host-side gate was green when the spike was called.
