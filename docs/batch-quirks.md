# cmd.exe quirks we hit (and how portsh handles them)

There is no single canonical list of cmd's lexical/runtime quirks. The best
external references are dbenham's [*How does the Windows Command Interpreter
(CMD.EXE) parse scripts?*](https://stackoverflow.com/q/4094699) (the definitive
phase-by-phase breakdown), [SS64's CMD reference](https://ss64.com/nt/), and the
StackOverflow `[batch-file]` canonical Q&As. But most of what bites portsh is the
*interaction* of cmd parsing with our design (a cons heap in variables, a Lisp
reader, line-oriented I/O), which those don't cover — so this file is our own
running catalog. Each entry: the quirk, why it happens, and how we deal with it.

## Variables

- **A variable can't hold a newline or a NUL.** This is the load-bearing
  constraint: it's why a portsh *string is a single line*, multi-line text is a
  *list of line-strings*, and all I/O is line-oriented.

- **`set "x="` deletes the variable** — there is no "defined but empty" string;
  empty == undefined. Worse, `%x:~0,1%` on an *undefined* var never expands to
  empty, so a `string-length` loop that scans `%s:~i,1%` until it's `""` spins
  forever on `""`. Fix: special-case the empty string (`string-length ""` → 0)
  rather than relying on the scan to terminate. (`kernel.cmd` `:pa_strlen`.)

- **Delayed expansion eats `!` (and `^`).** Any string content containing `!`
  is mangled while delayed expansion is on. We accept this as a known limit for
  string *content*; it's not worth disabling delayed expansion (the whole heap
  relies on it).

- **`setlocal`/`endlocal` revert all variable changes.** Since the cons heap
  *is* variables (`CAR_i`/`CDR_i`), `endlocal` anywhere in the eval path would
  wipe it. So there is **no `setlocal` in the evaluator**; recursion-safe locals
  use call-depth frame ids (`set /a ND=%1+1 & call :fn !ND!`, values held across
  a sub-call stored as `_%1_name`).

## Reader / lexing

- **`-1` is not a number by default.** `read_atom` classified tokens by their
  first character, so `-1` (first char `-`) became the *symbol* `S:-1` — an
  unbound symbol when evaluated — while the sh reader reads it as `I:-1`. Any
  negative literal worked on Unix and broke on Windows. Fix: `-` followed by a
  digit is a number (bare `-` and `-foo` stay symbols). (`kernel.cmd`
  `:read_atom`; `tests/lisp/negnum.lisp`.)

- **`;` is `for /f`'s default end-of-line.** A line whose first char is `;` is
  skipped, and a naive `for /f "tokens=1 delims=;"` comment-strip isn't
  string-aware (it cuts at a `;` *inside* a `"..."`). Fix: strip comments
  char-by-char tracking string state, so a `;` inside a literal survives — and
  match the sh reader. (`kernel.cmd` `:addsrc`; `tests/lisp/semistr.lisp`.)

## I/O and redirection

- **`for /f` silently drops blank lines** (and `;`-leading lines). Reading a file
  or command output back as lines therefore loses blanks. Fix: pipe through
  `find /v /n ""`, which prefixes *every* line (blanks included) with `[N]`, then
  strip the prefix. (`kernel.cmd` `:pa_rdlines` / `:po_runcap`.)

- **A pipe *inside* `for /f` deadlocks** in our deep call+redirect context
  (`for /f ... in ('type x ^| find y')` hangs, though it works standalone). Fix:
  run the pipe as a **standalone** redirect to a temp file first, then iterate
  the temp file with a plain `for /f`.

- **`cmd /c "X" 2>&1 | …` absorbs the space before the trailing token** into the
  command line, so `echo foo` emits a *trailing space*. Same root as the classic
  `echo foo > file` writing `"foo "` (the space before `>` is echoed). Fix: use
  the **redirect-first** form so nothing follows the quoted command:
  `> out 2>&1 cmd /c "X"`. (`kernel.cmd` `:po_runcap`.)

- **`echo(` is the reliable blank-line idiom** (`echo.` is fragile). But `echo(`
  *inside a parenthesized block* unbalances the parens — emit via a helper
  subroutine instead. And echoing a value containing `<`/`>`/`&`/`|` re-scans for
  redirection unless the value comes from a **delayed `!var!`**, so write content
  through delayed expansion. (`kernel.cmd` `:wl_emit`.)

- **`findstr "^"` can report "No search strings" or block on stdin** in nested
  contexts (a findstr with no valid pattern waits on stdin forever, and such a
  hung findstr can't be `taskkill`'d — see below). We avoid `findstr "^"`
  entirely in favor of `find /v /n ""`.

## Processes / limits

- **Batch recursion has a hard stack limit** (~a few hundred frames):
  `****** BATCH RECURSION exceeds STACK limits ******`. Deeply recursive Lisp
  (or a non-terminating recursion from a bug, like the `-1` one above) aborts
  rather than overflowing silently.

- **`taskkill /f` can't kill a process blocked on I/O** ("the operation
  attempted is not supported"). A `findstr`/`cmd` hung reading stdin survives
  taskkill and holds file locks; the only clean recovery is a VM reboot. This is
  why a stray hang during testing can wedge later `scp`s onto a locked file.

## Polyglot / line endings

- **cmd needs CR to recognize line breaks and labels; sh chokes on trailing CR.**
  The whole file is CRLF (for cmd), and line 1 re-execs `sh` on a CR-stripped
  copy of itself (`tr -d '\r'`, guarded by `$PORTSH_COOKED`) so the shell half
  parses clean. (`build.sh` header.)

- **`cmd /c "..."` quote-stripping is arcane** — whether the outer quotes are
  stripped depends on what else is on the line. Keep the quoted command the last
  thing on the line (redirect-first) to stay in the predictable case.
