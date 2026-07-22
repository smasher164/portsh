#!/bin/sh
# The sshd-context repro ladder (finding 1). HOST is a Windows
# OpenSSH server whose default shell is cmd.exe (here: Windows 11
# ARM64 build 10.0.26200, a UTM VM on Apple Silicon). Ship the
# interpreter and the trivial program first:
#
#   scp portsh.cmd repro/hi.lisp "$HOST":C:/kaya/
#
# Observed results, 2026-07-21, portsh @ 395371d:
#
#   cmd /c C:\kaya\mini.cmd                              -> plaincmd-ok   (baseline: plain .cmd fine)
#   cmd /c C:\kaya\portsh.cmd C:\kaya\hi.lisp            -> "The syntax of the command is incorrect."
#   cmd /c call C:\kaya\portsh.cmd C:\kaya\hi.lisp       -> same failure
#   cmd /e:on /d /c C:\kaya\portsh.cmd C:\kaya\hi.lisp   -> same failure
#   cmd /c C:\kaya\portsh.cmd C:\kaya\hi.lisp <nul       -> hi            (stdin nulled: WORKS)
#   cmd /c cd /d C:\kaya & C:\kaya\portsh.cmd C:\kaya\hi.lisp
#                                                        -> hi            (the & splits at sshd's
#                                                                          outer cmd, so portsh runs
#                                                                          WITHOUT the nested cmd /c)
#
# The same portsh.cmd + hi.lisp runs fine from a schtasks
# interactive-desktop session on the same machine, so the failure is
# specific to the sshd non-interactive context; the two working forms
# differ from the failing ones by stdin (ssh channel vs nul) and by
# cmd-nesting depth. File hashes were verified identical on both
# sides before any of this.
HOST="${1:?usage: ssh-ladder.sh user@host}"
for form in \
    'cmd /c C:\kaya\mini.cmd' \
    'cmd /c C:\kaya\portsh.cmd C:\kaya\hi.lisp' \
    'cmd /c call C:\kaya\portsh.cmd C:\kaya\hi.lisp' \
    'cmd /e:on /d /c C:\kaya\portsh.cmd C:\kaya\hi.lisp' \
    'cmd /c C:\kaya\portsh.cmd C:\kaya\hi.lisp <nul' \
    'cmd /c cd /d C:\kaya & C:\kaya\portsh.cmd C:\kaya\hi.lisp'; do
    printf '== %s\n' "$form"
    ssh -o BatchMode=yes "$HOST" "$form" 2>&1 | head -2
done
