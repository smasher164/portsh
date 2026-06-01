#!/bin/sh
# Weave src/kernel.sh + src/kernel.cmd into a single polyglot `portsh.cmd`
# that is BOTH a valid POSIX sh script AND a Windows batch file.
#
# Why it works:
#   * The whole file is CRLF — cmd.exe needs CR to recognise line breaks/labels.
#   * sh would choke on trailing CRs, so LINE 1 re-execs sh on a CR-stripped
#     copy of the file (guarded by $PORTSH_COOKED to avoid infinite recursion);
#     the trailing `#` swallows line 1's own CR on the first (raw) pass.
#   * cmd sees lines 1-2 as `:` labels (skipped), runs `@echo off` + `goto
#     :CMDSCRIPT`, jumping over the sh kernel to the batch kernel.
#   * sh hides the cmd dispatch in a `:<<'::CMDLITERAL'` heredoc, runs the sh
#     kernel, then `exit`s before reaching the batch section.
set -eu
cd "$(dirname "$0")"

tmp=$(mktemp)
cat > "$tmp" <<'HDR'
:;[ -n "${PORTSH_COOKED-}" ]||{ tr -d '\r'<"$0"|PORTSH_COOKED=1 PORTSH_SELF="$0" sh -s -- "$@";exit $?; } #
:<<'::CMDLITERAL'
@echo off
goto :CMDSTART
::CMDLITERAL
HDR
tail -n +2 src/kernel.sh >> "$tmp"        # sh kernel (drop its #!/bin/sh)
printf 'exit $?\n:CMDSTART\n' >> "$tmp"   # sh exits here; cmd's goto lands here
cat src/kernel.cmd >> "$tmp"              # batch kernel
printf '__PORTSH_PAYLOAD__\n' >> "$tmp"   # marker as the final line; pack = append Lisp after it

perl -pe 's/\r?\n/\r\n/' "$tmp" > portsh.cmd   # normalise everything to CRLF (bare interpreter)
rm -f "$tmp"
echo "built portsh.cmd ($(wc -c < portsh.cmd) bytes)"

# full distribution = bare interpreter + stdlib appended past the marker (loads at boot)
if [ -f src/stdlib.lisp ]; then
  { cat portsh.cmd; cat src/stdlib.lisp; } | perl -pe 's/\r?\n/\r\n/' > portsh-full.cmd
  echo "built portsh-full.cmd ($(wc -c < portsh-full.cmd) bytes)"
fi
