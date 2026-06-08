# src/comp-compiled.sh — compile.lisp + stdlib deps, compiled to native sh by comp-sh.sh
# (the native Lisp->sh emitter). Regenerate via tools/regen-comp.sh; validate via tests/native-comp.sh.
SIZE_not=1
not() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_not))
NP=1
case $PC in
0)
if [ "${p0}" != NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
R="S:t"; ACTION=ret; return
;;
esac; }
SIZE_cadr=1
cadr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cadr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_caddr=1
caddr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_caddr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_caar=1
caar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_caar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_append=3
append() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_append))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_reverse=2
reverse() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_reverse))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=reverse
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_car "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_assoc=2
assoc() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_assoc))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=caar
RPC=3; ACTION=call; return
;;
3)
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p1}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
5)
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_cadddr=1
cadddr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cadddr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_op_zzGbatch=1
op_zzGbatch() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_op_zzGbatch))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:+"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:-"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:*"; ACTION=ret; return
;;
6)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_cmp_zzGbatch=1
cmp_zzGbatch() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cmp_zzGbatch))
NP=1
case $PC in
0)
if [ "${p0}" = "S:<" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:LSS"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:=" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:EQU"; ACTION=ret; return
;;
4)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_arithzzQ=1
arithzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_arithzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_tpredzzQ=1
tpredzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tpredzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:eq?" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:null?" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:pair?" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="S:t"; ACTION=ret; return
;;
6)
if [ "${p0}" = "S:number?" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="S:t"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:string?" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="S:t"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:symbol?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="S:t"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:<" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="S:t"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:=" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="S:t"; ACTION=ret; return
;;
16)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_iszzQ=2
iszzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_iszzQ))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "${p1}" ]; then
sht1="S:t"
else
sht1="NIL"
fi
R="${sht1}"; ACTION=ret; return
;;
2)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_aref=1
aref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_aref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_iref=1
iref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_iref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
sht4="T:${sht3#??}!"
sht5="T:!${sht4#??}"
R="${sht5}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht6="${R}"
if [ "${sht6}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht8="${R}"
sht9="T:${sht8#??}:~2!"
sht10="T:!${sht9#??}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_vref=1
vref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_vref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
sht2="T:I:${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht3="${R}"
if [ "${sht3}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht4="${R}"
sht5="T:${sht4#??}!"
sht6="T:I:!${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht7="${R}"
if [ "${sht7}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht9="${R}"
sht10="T:${sht9#??}!"
sht11="T:!${sht10#??}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_cref=1
cref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:cst" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
sht3="I:$(( ${#sht2} - 2 ))"
sht4="I:$(( ${sht3#??} - 2 ))"
sht5="T:$(printf '%s' "${sht1#??}" | cut -c$(( 2 + 1 ))-$(( 2 + ${sht4#??} )))"
R="${sht5}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
G_B1='T:!'
G_B2='T:%'
G_B7='T:^'
G_BLT='T:<'
G_BGT='T:>'
G_BAMP='T:&'
G_BPIPE='T:|'
SIZE_mc_at=1
mc_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mc_at))
NP=1
case $PC in
0)
if [ "${p0}" = "${G_B1}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:!BANG!"; ACTION=ret; return
;;
2)
if [ "${p0}" = "${G_B2}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:!BANG2!"; ACTION=ret; return
;;
4)
if [ "${p0}" = "${G_B7}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:!BANG7!"; ACTION=ret; return
;;
6)
if [ "${p0}" = "${G_BLT}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:!LT!"; ACTION=ret; return
;;
8)
if [ "${p0}" = "${G_BGT}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:!GT!"; ACTION=ret; return
;;
10)
if [ "${p0}" = "${G_BAMP}" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:!AMP!"; ACTION=ret; return
;;
12)
if [ "${p0}" = "${G_BPIPE}" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:!PIPE!"; ACTION=ret; return
;;
14)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_enc_mc_go=8
enc_mc_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_enc_mc_go))
NP=4
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p3}"; ACTION=ret; return
;;
2)
sht0="I:$(( ${p1#??} + 1 ))"
sht1="T:$(printf '%s' "${p0#??}" | cut -c$(( ${p1#??} + 1 ))-$(( ${p1#??} + 1 )))"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=mc_at
RPC=3; ACTION=call; return
;;
3)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht2="${R}"
sht3="T:${p3#??}${sht2#??}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht0}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_enc_mc=1
enc_mc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_enc_mc))
NP=1
case $PC in
0)
sht0="I:$(( ${#p0} - 2 ))"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht0}\""
STGV="T:"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=enc_mc_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
G_BST='T:*'
SIZE_mangle_at=1
mangle_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mangle_at))
NP=1
case $PC in
0)
if [ "${p0}" = "${G_BGT}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:zzG"; ACTION=ret; return
;;
2)
if [ "${p0}" = "${G_BLT}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:zzL"; ACTION=ret; return
;;
4)
if [ "${p0}" = "${G_BAMP}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:zzA"; ACTION=ret; return
;;
6)
if [ "${p0}" = "${G_BPIPE}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:zzP"; ACTION=ret; return
;;
8)
if [ "${p0}" = "${G_BST}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:zzS"; ACTION=ret; return
;;
10)
if [ "${p0}" = "T:?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:zzQ"; ACTION=ret; return
;;
12)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_mangle_go=8
mangle_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_mangle_go))
NP=4
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p3}"; ACTION=ret; return
;;
2)
sht0="I:$(( ${p1#??} + 1 ))"
sht1="T:$(printf '%s' "${p0#??}" | cut -c$(( ${p1#??} + 1 ))-$(( ${p1#??} + 1 )))"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=mangle_at
RPC=3; ACTION=call; return
;;
3)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht2="${R}"
sht3="T:${p3#??}${sht2#??}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht0}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_mangle=1
mangle() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mangle))
NP=1
case $PC in
0)
sht0="I:$(( ${#p0} - 2 ))"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht0}\""
STGV="T:"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=mangle_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_rev=3
rev() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_rev))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht1}" "${p1}"
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_qset=1
qset() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_qset))
NP=1
case $PC in
0)
sht0="T:${p0#??}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:set ${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_lookup=2
lookup() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lookup))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_cdr "${p1}"
sht4="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lenl=1
lenl() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_lenl))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="I:0"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=lenl
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
sht2="I:$(( 1 + ${sht1#??} ))"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_maxi=2
maxi() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_maxi))
NP=2
case $PC in
0)
if [ ${p0#??} -lt ${p1#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_qset=1
qset() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_qset))
NP=1
case $PC in
0)
sht0="T:${p0#??}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:set ${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_b_blk=1
b_blk() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_blk))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_b_cur=1
b_cur() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_cur))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_b_pc=1
b_pc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_pc))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_b_npc=1
b_npc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_npc))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_b_k=1
b_k() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_k))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_b_smax=1
b_smax() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_smax))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_mkb=11
mkb() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_mkb))
NP=6
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p4}\""
eval "F$((FP+NP+1))=\"\${p3}\""
eval "F$((FP+NP+2))=\"\${p2}\""
eval "F$((FP+NP+3))=\"\${p1}\""
eval "F$((FP+NP+4))=\"\${p0}\""
hp_cons "${p5}" "NIL"
eval "p4=\"\$F$((FP+NP+0))\""
eval "p3=\"\$F$((FP+NP+1))\""
eval "p2=\"\$F$((FP+NP+2))\""
eval "p1=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${p0}\""
hp_cons "${p4}" "${sht0}"
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${p0}\""
hp_cons "${p3}" "${sht1}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "${p2}" "${sht2}"
eval "p1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p1}" "${sht3}"
eval "p0=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${p0}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_emit=7
emit() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_emit))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${p1}" "${sht1}"
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht2}\""
eval "F$((NFP+2))=\"\${sht3}\""
eval "F$((NFP+3))=\"\${sht4}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bkzzP=6
bkzzP() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bkzzP))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht4="${R}"
sht5="I:$(( ${sht4#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht3}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bsm=7
bsm() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_bsm))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=maxi
RPC=7; ACTION=call; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht3}\""
eval "F$((NFP+4))=\"\${sht4}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bnpczzP=6
bnpczzP() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bnpczzP))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
sht4="I:$(( ${sht3#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht4}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_switch=6
switch() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_switch))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht3}" "${sht4}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=5; ACTION=call; return
;;
5)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=7; ACTION=call; return
;;
7)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${sht6}\""
eval "F$((NFP+4))=\"\${sht7}\""
eval "F$((NFP+5))=\"\${sht8}\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
sht9="${R}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_tmpn=1
tmpn() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tmpn))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="T:${sht0#??}"
sht2="T:zt${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_fval=1
fval() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fval))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=vref
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_spill=3
spill() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_spill))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
sht2="T:!${G_DQ#??}"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:F!_i!=!${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!FP!+!NP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_unspill=3
unspill() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_unspill))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
sht2="T:=%%F!_i!%%${G_DQ#??}"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T: & call set ${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:set /a _i=!FP!+!NP!+${sht6#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht8="${R}"
hp_cdr "${p1}"
sht9="${R}"
sht10="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${sht9}\""
eval "F$((FP+2))=\"\${sht10}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_stage=6
stage() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_stage))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=fval
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
sht3="T:${sht2#??}${G_DQ#??}"
sht4="T:F!_i!=${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!NFP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=4; ACTION=call; return
;;
4)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_setparams=6
setparams() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_setparams))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=fval
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
sht3="T:${sht2#??}${G_DQ#??}"
sht4="T:F!_i!=${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!FP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=4; ACTION=call; return
;;
4)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_rvar=1
rvar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_rvar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:val" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_addlive=3
addlive() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_addlive))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=rvar
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht1}" "${p1}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_largs=8
largs() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_largs))
NP=4
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "${p2}" "NIL"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
sht2="${R}"
sht3="${sht2}"
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht3}"
sht5="${R}"
hp_cdr "${sht3}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht4}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=4; ACTION=call; return
;;
4)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht4=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht5}\""
eval "F$((NFP+3))=\"\${sht7}\""
CALLEE=largs
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
hp_car "${sht9}"
sht10="${R}"
hp_cdr "${sht3}"
sht11="${R}"
hp_cdr "${sht9}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "${sht11}" "${sht12}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht10}" "${sht13}"
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht14="${R}"
R="${sht14}"; ACTION=ret; return
;;
esac; }
SIZE_bargs=2
bargs() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bargs))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=bargs
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="T:${sht1#??}${sht3#??}"
sht5="T: ${sht4#??}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_lcell=11
lcell() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_lcell))
NP=5
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:${sht5#??}"
sht7="T:zi${sht6#??}"
sht8="${sht7}"
hp_car "${sht3}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=tmpn
RPC=3; ACTION=call; return
;;
3)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht10="${R}"
sht11="${sht10}"
hp_car "${sht3}"
sht12="${R}"
hp_cdr "${sht3}"
sht13="${R}"
hp_cdr "${sht13}"
sht14="${R}"
sht15="T:${sht14#??}:~2!"
sht16="T:=!${sht15#??}"
sht17="T:${sht8#??}${sht16#??}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${sht18}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht19="${R}"
sht20="${sht19}"
sht21="T:${sht8#??}!"
sht22="T: !${sht21#??}"
sht23="T:${p1#??}${sht22#??}"
sht24="T:call rdfield.cmd ${sht23#??}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht25="${R}"
sht26="${sht25}"
sht27="T:${sht11#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
CALLEE=qset
RPC=7; ACTION=call; return
;;
7)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht28}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
hp_cons "S:val" "${sht11}"
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
hp_cons "${sht30}" "${sht31}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht32="${R}"
R="${sht32}"; ACTION=ret; return
;;
esac; }
SIZE_ltagtest=10
ltagtest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltagtest))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="T:${sht3#??}"
sht5="T:zp${sht4#??}"
sht6="${sht5}"
hp_car "${sht1}"
sht7="${R}"
hp_cdr "${sht1}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht9="${R}"
sht10="T:=${sht9#??}"
sht11="T:${sht6#??}${sht10#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht13="${R}"
sht14="T:${sht6#??}:~0,1!"
sht15="T:=!${sht14#??}"
sht16="T:${sht6#??}${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=qset
RPC=6; ACTION=call; return
;;
6)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht17}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=bkzzP
RPC=8; ACTION=call; return
;;
8)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht20="${R}"
if [ "${p5}" != NIL ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
sht21="T:not "
PC=11; ACTION=jump; return
;;
10)
sht21="T:"
PC=11; ACTION=jump; return
;;
11)
sht22="T:!==${p1#??}"
sht23="T:${sht6#??}${sht22#??}"
sht24="T:!${sht23#??}"
sht25="T:${sht21#??}${sht24#??}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht20}" "${sht25}"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht26="${R}"
R="${sht26}"; ACTION=ret; return
;;
esac; }
SIZE_ctest=11
ctest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_ctest))
NP=4
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=tpredzzQ
RPC=4; ACTION=call; return
;;
2)
sht0="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht0}" != NIL ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
4)
sht2="${R}"
sht0="${sht2}"
PC=3; ACTION=jump; return
;;
5)
hp_car "${p0}"
sht3="${R}"
if [ "${sht3}" = "S:null?" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=37; ACTION=call; return
;;
7)
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=9; ACTION=call; return
;;
8)
hp_car "${p0}"
sht18="${R}"
if [ "${sht18}" = "S:eq?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
9)
sht6="${R}"
sht7="${sht6}"
hp_car "${sht7}"
sht8="${R}"
hp_cdr "${sht7}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=vref
RPC=10; ACTION=call; return
;;
10)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="T:NIL${G_DQ#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:==${sht12#??}"
sht14="T:${G_DQ#??}${sht13#??}"
sht15="T:${sht10#??}${sht14#??}"
sht16="T:${G_DQ#??}${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
hp_cons "${sht8}" "${sht16}"
eval "sht7=\"\$F$((FP+NP+0))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
11)
hp_cdr "${p0}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=13; ACTION=call; return
;;
12)
hp_car "${p0}"
sht41="${R}"
if [ "${sht41}" = "S:pair?" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
13)
sht21="${R}"
sht22="${sht21}"
hp_cdr "${p0}"
sht23="${R}"
hp_cdr "${sht23}"
sht24="${R}"
hp_car "${sht24}"
sht25="${R}"
hp_car "${sht22}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht25}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht26}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=14; ACTION=call; return
;;
14)
eval "sht22=\"\$F$((FP+NP+0))\""
sht27="${R}"
sht28="${sht27}"
hp_car "${sht28}"
sht29="${R}"
hp_cdr "${sht22}"
sht30="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht28}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
CALLEE=vref
RPC=15; ACTION=call; return
;;
15)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht28=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
sht31="${R}"
hp_cdr "${sht28}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht28}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
CALLEE=vref
RPC=16; ACTION=call; return
;;
16)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht28=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
sht33="${R}"
sht34="T:${sht33#??}${G_DQ#??}"
sht35="T:${G_DQ#??}${sht34#??}"
sht36="T:==${sht35#??}"
sht37="T:${G_DQ#??}${sht36#??}"
sht38="T:${sht31#??}${sht37#??}"
sht39="T:${G_DQ#??}${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
hp_cons "${sht29}" "${sht39}"
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
sht40="${R}"
R="${sht40}"; ACTION=ret; return
;;
17)
hp_cdr "${p0}"
sht42="${R}"
hp_car "${sht42}"
sht43="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
STGV="T:P"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=19; ACTION=call; return
;;
18)
hp_car "${p0}"
sht45="${R}"
if [ "${sht45}" = "S:atom?" ]; then PC=20; else PC=21; fi
ACTION=jump; return
;;
19)
sht44="${R}"
R="${sht44}"; ACTION=ret; return
;;
20)
hp_cdr "${p0}"
sht46="${R}"
hp_car "${sht46}"
sht47="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
STGV="T:P"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="S:t"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=22; ACTION=call; return
;;
21)
hp_car "${p0}"
sht49="${R}"
if [ "${sht49}" = "S:number?" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
22)
sht48="${R}"
R="${sht48}"; ACTION=ret; return
;;
23)
hp_cdr "${p0}"
sht50="${R}"
hp_car "${sht50}"
sht51="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
STGV="T:I"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=25; ACTION=call; return
;;
24)
hp_car "${p0}"
sht53="${R}"
if [ "${sht53}" = "S:string?" ]; then PC=26; else PC=27; fi
ACTION=jump; return
;;
25)
sht52="${R}"
R="${sht52}"; ACTION=ret; return
;;
26)
hp_cdr "${p0}"
sht54="${R}"
hp_car "${sht54}"
sht55="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht55}\""
STGV="T:T"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=28; ACTION=call; return
;;
27)
hp_car "${p0}"
sht57="${R}"
if [ "${sht57}" = "S:symbol?" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
28)
sht56="${R}"
R="${sht56}"; ACTION=ret; return
;;
29)
hp_cdr "${p0}"
sht58="${R}"
hp_car "${sht58}"
sht59="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht59}\""
STGV="T:S"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=31; ACTION=call; return
;;
30)
hp_cdr "${p0}"
sht61="${R}"
hp_car "${sht61}"
sht62="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht62}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=32; ACTION=call; return
;;
31)
sht60="${R}"
R="${sht60}"; ACTION=ret; return
;;
32)
sht63="${R}"
sht64="${sht63}"
hp_cdr "${p0}"
sht65="${R}"
hp_cdr "${sht65}"
sht66="${R}"
hp_car "${sht66}"
sht67="${R}"
hp_car "${sht64}"
sht68="${R}"
eval "F$((FP+NP+0))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht67}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht68}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=33; ACTION=call; return
;;
33)
eval "sht64=\"\$F$((FP+NP+0))\""
sht69="${R}"
sht70="${sht69}"
hp_car "${sht70}"
sht71="${R}"
hp_cdr "${sht64}"
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht71}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht72}\""
CALLEE=iref
RPC=34; ACTION=call; return
;;
34)
eval "sht71=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht64=\"\$F$((FP+NP+2))\""
sht73="${R}"
hp_car "${p0}"
sht74="${R}"
eval "F$((FP+NP+0))=\"\${sht73}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
eval "F$((FP+NP+2))=\"\${sht70}\""
eval "F$((FP+NP+3))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
CALLEE=cmp_zzGbatch
RPC=35; ACTION=call; return
;;
35)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
eval "sht70=\"\$F$((FP+NP+2))\""
eval "sht64=\"\$F$((FP+NP+3))\""
sht75="${R}"
hp_cdr "${sht70}"
sht76="${R}"
eval "F$((FP+NP+0))=\"\${sht75}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht71}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht76}\""
CALLEE=iref
RPC=36; ACTION=call; return
;;
36)
eval "sht75=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht71=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht64=\"\$F$((FP+NP+4))\""
sht77="${R}"
sht78="T: ${sht77#??}"
sht79="T:${sht75#??}${sht78#??}"
sht80="T: ${sht79#??}"
sht81="T:${sht73#??}${sht80#??}"
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht64}\""
hp_cons "${sht71}" "${sht81}"
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht64=\"\$F$((FP+NP+1))\""
sht82="${R}"
R="${sht82}"; ACTION=ret; return
;;
37)
sht83="${R}"
sht84="${sht83}"
hp_car "${sht84}"
sht85="${R}"
hp_cdr "${sht84}"
sht86="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht86}\""
CALLEE=vref
RPC=38; ACTION=call; return
;;
38)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
sht87="${R}"
sht88="T:NIL${G_DQ#??}"
sht89="T:${G_DQ#??}${sht88#??}"
sht90="T:==${sht89#??}"
sht91="T:${G_DQ#??}${sht90#??}"
sht92="T:${sht87#??}${sht91#??}"
sht93="T:${G_DQ#??}${sht92#??}"
sht94="T:not ${sht93#??}"
eval "F$((FP+NP+0))=\"\${sht84}\""
hp_cons "${sht85}" "${sht94}"
eval "sht84=\"\$F$((FP+NP+0))\""
sht95="${R}"
R="${sht95}"; ACTION=ret; return
;;
esac; }
SIZE_jumpto=1
jumpto() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_jumpto))
NP=1
case $PC in
0)
sht0="T:${p0#??}"
sht1="T:${G_DQ#??} & goto :eof"
sht2="T:ACTION=jump${sht1#??}"
sht3="T:${G_DQ#??}${sht2#??}"
sht4="T: & set ${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:PC=${sht6#??}"
sht8="T:${G_DQ#??}${sht7#??}"
sht9="T:set ${sht8#??}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_ifjump=2
ifjump() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_ifjump))
NP=2
case $PC in
0)
sht0="T:${p1#??}"
sht1="T:${G_DQ#??} & goto :eof)"
sht2="T:ACTION=jump${sht1#??}"
sht3="T:${G_DQ#??}${sht2#??}"
sht4="T: & set ${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:PC=${sht6#??}"
sht8="T:${G_DQ#??}${sht7#??}"
sht9="T: (set ${sht8#??}"
sht10="T:${p0#??}${sht9#??}"
sht11="T:if ${sht10#??}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_seg_files=7
seg_files() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_seg_files))
NP=5
case $PC in
0)
if [ ${p2#??} -eq ${p3#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
sht1="T:_pc${sht0#??}"
sht2="T:${p4#??}${sht1#??}"
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=blkget
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
sht6="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht6}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
CALLEE=seg_files
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${sht5}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_write_segs=2
write_segs() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_write_segs))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
sht2="T:${sht1#??}.cmd"
sht3="T:/${sht2#??}"
sht4="T:${p1#??}${sht3#??}"
hp_car "${p0}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
write_lines "${sht4}" "${sht6}"
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lif_val=17
lif_val() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_lif_val))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=ctest
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=b_npc
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="${sht3}"
hp_car "${sht1}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=b_npc
RPC=3; ACTION=call; return
;;
3)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht6="${R}"
sht7="I:$(( ${sht6#??} + 1 ))"
sht8="${sht7}"
hp_car "${sht1}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="I:$(( ${sht10#??} + 2 ))"
sht12="${sht11}"
hp_car "${sht1}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht4}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=tmpn
RPC=5; ACTION=call; return
;;
5)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht4=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht14="${R}"
sht15="${sht14}"
hp_car "${sht1}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=bnpczzP
RPC=6; ACTION=call; return
;;
6)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
CALLEE=bnpczzP
RPC=7; ACTION=call; return
;;
7)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
CALLEE=bnpczzP
RPC=8; ACTION=call; return
;;
8)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht20="${R}"
hp_cdr "${sht1}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
eval "F$((NFP+1))=\"\${sht4}\""
CALLEE=ifjump
RPC=10; ACTION=call; return
;;
10)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht22}\""
CALLEE=emit
RPC=11; ACTION=call; return
;;
11)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=jumpto
RPC=12; ACTION=call; return
;;
12)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=13; ACTION=call; return
;;
13)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht25="${R}"
sht26="${sht25}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht4}\""
CALLEE=switch
RPC=14; ACTION=call; return
;;
14)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht27}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=15; ACTION=call; return
;;
15)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht28="${R}"
sht29="${sht28}"
hp_car "${sht29}"
sht30="${R}"
hp_cdr "${sht29}"
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht31}\""
CALLEE=vref
RPC=16; ACTION=call; return
;;
16)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht32="${R}"
sht33="T:=${sht32#??}"
sht34="T:${sht15#??}${sht33#??}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
CALLEE=qset
RPC=17; ACTION=call; return
;;
17)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
eval "F$((NFP+1))=\"\${sht35}\""
CALLEE=emit
RPC=18; ACTION=call; return
;;
18)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=jumpto
RPC=19; ACTION=call; return
;;
19)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
eval "F$((NFP+1))=\"\${sht37}\""
CALLEE=emit
RPC=20; ACTION=call; return
;;
20)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht38="${R}"
sht39="${sht38}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=switch
RPC=21; ACTION=call; return
;;
21)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht40}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=22; ACTION=call; return
;;
22)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht41="${R}"
sht42="${sht41}"
hp_car "${sht42}"
sht43="${R}"
hp_cdr "${sht42}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht43}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht4}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
CALLEE=vref
RPC=23; ACTION=call; return
;;
23)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht43=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht4=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht45="${R}"
sht46="T:=${sht45#??}"
sht47="T:${sht15#??}${sht46#??}"
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=qset
RPC=24; ACTION=call; return
;;
24)
eval "sht43=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
eval "F$((NFP+1))=\"\${sht48}\""
CALLEE=emit
RPC=25; ACTION=call; return
;;
25)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht49}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=jumpto
RPC=26; ACTION=call; return
;;
26)
eval "sht49=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
eval "F$((NFP+1))=\"\${sht50}\""
CALLEE=emit
RPC=27; ACTION=call; return
;;
27)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht51="${R}"
sht52="${sht51}"
eval "F$((FP+NP+0))=\"\${sht52}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=switch
RPC=28; ACTION=call; return
;;
28)
eval "sht52=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht52}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht4}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
hp_cons "S:val" "${sht15}"
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht52=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht4=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht52}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
hp_cons "${sht53}" "${sht54}"
eval "sht52=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht55="${R}"
R="${sht55}"; ACTION=ret; return
;;
esac; }
SIZE_lbinds=10
lbinds() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbinds))
NP=4
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${p1}" "${p3}"
eval "p2=\"\$F$((FP+NP+0))\""
sht0="${R}"
hp_cons "${p2}" "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
sht5="${R}"
sht6="${sht5}"
hp_car "${sht6}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=tmpn
RPC=4; ACTION=call; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
hp_cdr "${p0}"
sht10="${R}"
hp_car "${p0}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
hp_cons "${sht12}" "${sht9}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
hp_cons "${sht13}" "${p1}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht14="${R}"
hp_car "${sht6}"
sht15="${R}"
hp_cdr "${sht6}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=vref
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
sht17="${R}"
sht18="T:=${sht17#??}"
sht19="T:${sht9#??}${sht18#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=6; ACTION=call; return
;;
6)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=bkzzP
RPC=8; ACTION=call; return
;;
8)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
hp_cons "${sht9}" "${p3}"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
sht23="${R}"
eval "F$((FP+0))=\"\${sht10}\""
eval "F$((FP+1))=\"\${sht14}\""
eval "F$((FP+2))=\"\${sht22}\""
eval "F$((FP+3))=\"\${sht23}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_llet=6
llet() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_llet))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lbinds
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
hp_car "${sht1}"
sht4="${R}"
hp_cdr "${sht1}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${sht4}\""
eval "F$((NFP+3))=\"\${sht6}\""
CALLEE=lval
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_lbegin=4
lbegin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbegin))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
2)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=4; ACTION=call; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht4="${R}"
sht5="${sht4}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${sht5}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht7}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lquote=3
lquote() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lquote))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "T:NIL"
eval "p1=\"\$F$((FP+NP+0))\""
sht0="${R}"
hp_cons "${p1}" "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
if [ "${p0#I:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht2="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:lit" "${sht2}"
eval "p1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${p1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
if [ "${p0#T:}" != "${p0}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
eval "F$((FP+NP+0))=\"\${p1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=enc_mc
RPC=7; ACTION=call; return
;;
6)
if [ "${p0#S:}" != "${p0}" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "p1=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:T:${sht5#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "${sht6}"
eval "p1=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${p1}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
8)
sht9="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=enc_mc
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht14="${R}"
hp_cons "${sht14}" "NIL"
sht15="${R}"
hp_cons "S:quote" "${sht15}"
sht16="${R}"
hp_cdr "${p0}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "${sht17}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "S:quote" "${sht18}"
eval "sht16=\"\$F$((FP+NP+0))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "${sht19}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
sht20="${R}"
hp_cons "${sht16}" "${sht20}"
sht21="${R}"
hp_cons "S:cons" "${sht21}"
sht22="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
STGV="NIL"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=lval
RPC=11; ACTION=call; return
;;
10)
eval "p1=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="T:S:${sht10#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "${sht11}"
eval "p1=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cons "${p1}" "${sht12}"
sht13="${R}"
R="${sht13}"; ACTION=ret; return
;;
11)
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
esac; }
SIZE_lretag=10
lretag() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_lretag))
NP=5
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=tmpn
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="${sht5}"
hp_car "${sht3}"
sht7="${R}"
hp_cdr "${sht3}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cref
RPC=3; ACTION=call; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht9="${R}"
sht10="T:${p1#??}${sht9#??}"
sht11="T:=${sht10#??}"
sht12="T:${sht6#??}${sht11#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht13}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
CALLEE=bkzzP
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "S:val" "${sht6}"
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht15}" "${sht16}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
esac; }
SIZE_lstrlen=13
lstrlen() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lstrlen))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:${sht5#??}"
sht7="${sht6}"
sht8="T:zc${sht7#??}"
sht9="${sht8}"
hp_car "${sht3}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=tmpn
RPC=3; ACTION=call; return
;;
3)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht11="${R}"
sht12="${sht11}"
sht13="T:zSL${sht7#??}"
sht14="${sht13}"
hp_car "${sht3}"
sht15="${R}"
hp_cdr "${sht3}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
eval "F$((FP+NP+6))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=cref
RPC=4; ACTION=call; return
;;
4)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
eval "sht3=\"\$F$((FP+NP+6))\""
sht17="${R}"
sht18="T:=${sht17#??}"
sht19="T:${sht9#??}${sht18#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=5; ACTION=call; return
;;
5)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht21="${R}"
sht22="${sht21}"
sht23="T:${sht12#??}=0"
sht24="T:set /a ${sht23#??}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht25="${R}"
sht26="${sht25}"
sht27="T::${sht14#??}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
eval "F$((FP+NP+6))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht27}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
eval "sht3=\"\$F$((FP+NP+6))\""
sht28="${R}"
sht29="${sht28}"
sht30="T:${sht14#??})"
sht31="T:+=1& goto ${sht30#??}"
sht32="T:${sht12#??}${sht31#??}"
sht33="T::~1!& set /a ${sht32#??}"
sht34="T:${sht9#??}${sht33#??}"
sht35="T:=!${sht34#??}"
sht36="T:${sht9#??}${sht35#??}"
sht37="T: (set ${sht36#??}"
sht38="T:${sht9#??}${sht37#??}"
sht39="T:if defined ${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht39}\""
CALLEE=emit
RPC=9; ACTION=call; return
;;
9)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
CALLEE=bkzzP
RPC=10; ACTION=call; return
;;
10)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht14}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht7}\""
eval "F$((FP+NP+8))=\"\${sht3}\""
hp_cons "S:raw" "${sht12}"
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht14=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht7=\"\$F$((FP+NP+7))\""
eval "sht3=\"\$F$((FP+NP+8))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
hp_cons "${sht41}" "${sht42}"
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht43="${R}"
R="${sht43}"; ACTION=ret; return
;;
esac; }
SIZE_lsubstr=24
lsubstr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lsubstr))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_car "${sht3}"
sht7="${R}"
hp_cdr "${sht3}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=2; ACTION=call; return
;;
2)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht7}\""
eval "F$((NFP+3))=\"\${sht9}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="${sht10}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=4; ACTION=call; return
;;
4)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht12="${R}"
hp_car "${sht11}"
sht13="${R}"
hp_cdr "${sht11}"
sht14="${R}"
hp_cdr "${sht3}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht11}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=5; ACTION=call; return
;;
5)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht11=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=addlive
RPC=6; ACTION=call; return
;;
6)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht13}\""
eval "F$((NFP+3))=\"\${sht17}\""
CALLEE=lval
RPC=7; ACTION=call; return
;;
7)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
hp_car "${sht19}"
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
CALLEE=b_k
RPC=8; ACTION=call; return
;;
8)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht21="${R}"
sht22="T:${sht21#??}"
sht23="${sht22}"
sht24="T:zc${sht23#??}"
sht25="${sht24}"
sht26="T:zsk${sht23#??}"
sht27="${sht26}"
sht28="T:ztk${sht23#??}"
sht29="${sht28}"
sht30="T:zr${sht23#??}"
sht31="${sht30}"
hp_car "${sht19}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht19}\""
eval "F$((FP+NP+6))=\"\${sht11}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
CALLEE=tmpn
RPC=9; ACTION=call; return
;;
9)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht19=\"\$F$((FP+NP+5))\""
eval "sht11=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht33="${R}"
sht34="${sht33}"
sht35="T:zSK${sht23#??}"
sht36="${sht35}"
sht37="T:zTK${sht23#??}"
sht38="${sht37}"
hp_car "${sht19}"
sht39="${R}"
hp_cdr "${sht3}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht38}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
eval "F$((FP+NP+4))=\"\${sht34}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
eval "F$((FP+NP+6))=\"\${sht29}\""
eval "F$((FP+NP+7))=\"\${sht27}\""
eval "F$((FP+NP+8))=\"\${sht25}\""
eval "F$((FP+NP+9))=\"\${sht23}\""
eval "F$((FP+NP+10))=\"\${sht19}\""
eval "F$((FP+NP+11))=\"\${sht11}\""
eval "F$((FP+NP+12))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
CALLEE=cref
RPC=10; ACTION=call; return
;;
10)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht38=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
eval "sht34=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
eval "sht29=\"\$F$((FP+NP+6))\""
eval "sht27=\"\$F$((FP+NP+7))\""
eval "sht25=\"\$F$((FP+NP+8))\""
eval "sht23=\"\$F$((FP+NP+9))\""
eval "sht19=\"\$F$((FP+NP+10))\""
eval "sht11=\"\$F$((FP+NP+11))\""
eval "sht3=\"\$F$((FP+NP+12))\""
sht41="${R}"
sht42="T:=${sht41#??}"
sht43="T:${sht25#??}${sht42#??}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht34}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht29}\""
eval "F$((FP+NP+6))=\"\${sht27}\""
eval "F$((FP+NP+7))=\"\${sht25}\""
eval "F$((FP+NP+8))=\"\${sht23}\""
eval "F$((FP+NP+9))=\"\${sht19}\""
eval "F$((FP+NP+10))=\"\${sht11}\""
eval "F$((FP+NP+11))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht34=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht29=\"\$F$((FP+NP+5))\""
eval "sht27=\"\$F$((FP+NP+6))\""
eval "sht25=\"\$F$((FP+NP+7))\""
eval "sht23=\"\$F$((FP+NP+8))\""
eval "sht19=\"\$F$((FP+NP+9))\""
eval "sht11=\"\$F$((FP+NP+10))\""
eval "sht3=\"\$F$((FP+NP+11))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht34}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht27}\""
eval "F$((FP+NP+6))=\"\${sht25}\""
eval "F$((FP+NP+7))=\"\${sht23}\""
eval "F$((FP+NP+8))=\"\${sht19}\""
eval "F$((FP+NP+9))=\"\${sht11}\""
eval "F$((FP+NP+10))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht44}\""
CALLEE=emit
RPC=12; ACTION=call; return
;;
12)
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht27=\"\$F$((FP+NP+5))\""
eval "sht25=\"\$F$((FP+NP+6))\""
eval "sht23=\"\$F$((FP+NP+7))\""
eval "sht19=\"\$F$((FP+NP+8))\""
eval "sht11=\"\$F$((FP+NP+9))\""
eval "sht3=\"\$F$((FP+NP+10))\""
sht45="${R}"
sht46="${sht45}"
hp_cdr "${sht11}"
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht46}\""
eval "F$((FP+NP+2))=\"\${sht46}\""
eval "F$((FP+NP+3))=\"\${sht38}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
eval "F$((FP+NP+5))=\"\${sht34}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
eval "F$((FP+NP+8))=\"\${sht27}\""
eval "F$((FP+NP+9))=\"\${sht25}\""
eval "F$((FP+NP+10))=\"\${sht23}\""
eval "F$((FP+NP+11))=\"\${sht19}\""
eval "F$((FP+NP+12))=\"\${sht11}\""
eval "F$((FP+NP+13))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=aref
RPC=13; ACTION=call; return
;;
13)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht46=\"\$F$((FP+NP+1))\""
eval "sht46=\"\$F$((FP+NP+2))\""
eval "sht38=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
eval "sht34=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
eval "sht27=\"\$F$((FP+NP+8))\""
eval "sht25=\"\$F$((FP+NP+9))\""
eval "sht23=\"\$F$((FP+NP+10))\""
eval "sht19=\"\$F$((FP+NP+11))\""
eval "sht11=\"\$F$((FP+NP+12))\""
eval "sht3=\"\$F$((FP+NP+13))\""
sht48="${R}"
sht49="T:=${sht48#??}"
sht50="T:${sht27#??}${sht49#??}"
sht51="T:set /a ${sht50#??}"
eval "F$((FP+NP+0))=\"\${sht46}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht34}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht29}\""
eval "F$((FP+NP+6))=\"\${sht27}\""
eval "F$((FP+NP+7))=\"\${sht25}\""
eval "F$((FP+NP+8))=\"\${sht23}\""
eval "F$((FP+NP+9))=\"\${sht19}\""
eval "F$((FP+NP+10))=\"\${sht11}\""
eval "F$((FP+NP+11))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht46}\""
eval "F$((NFP+1))=\"\${sht51}\""
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
eval "sht46=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht34=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht29=\"\$F$((FP+NP+5))\""
eval "sht27=\"\$F$((FP+NP+6))\""
eval "sht25=\"\$F$((FP+NP+7))\""
eval "sht23=\"\$F$((FP+NP+8))\""
eval "sht19=\"\$F$((FP+NP+9))\""
eval "sht11=\"\$F$((FP+NP+10))\""
eval "sht3=\"\$F$((FP+NP+11))\""
sht52="${R}"
sht53="${sht52}"
sht54="T::${sht36#??}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht46}\""
eval "F$((FP+NP+2))=\"\${sht38}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
eval "F$((FP+NP+4))=\"\${sht34}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
eval "F$((FP+NP+6))=\"\${sht29}\""
eval "F$((FP+NP+7))=\"\${sht27}\""
eval "F$((FP+NP+8))=\"\${sht25}\""
eval "F$((FP+NP+9))=\"\${sht23}\""
eval "F$((FP+NP+10))=\"\${sht19}\""
eval "F$((FP+NP+11))=\"\${sht11}\""
eval "F$((FP+NP+12))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
eval "F$((NFP+1))=\"\${sht54}\""
CALLEE=emit
RPC=15; ACTION=call; return
;;
15)
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht46=\"\$F$((FP+NP+1))\""
eval "sht38=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
eval "sht34=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
eval "sht29=\"\$F$((FP+NP+6))\""
eval "sht27=\"\$F$((FP+NP+7))\""
eval "sht25=\"\$F$((FP+NP+8))\""
eval "sht23=\"\$F$((FP+NP+9))\""
eval "sht19=\"\$F$((FP+NP+10))\""
eval "sht11=\"\$F$((FP+NP+11))\""
eval "sht3=\"\$F$((FP+NP+12))\""
sht55="${R}"
sht56="${sht55}"
sht57="T:${sht36#??})"
sht58="T:-=1& goto ${sht57#??}"
sht59="T:${sht27#??}${sht58#??}"
sht60="T::~1!& set /a ${sht59#??}"
sht61="T:${sht25#??}${sht60#??}"
sht62="T:=!${sht61#??}"
sht63="T:${sht25#??}${sht62#??}"
sht64="T:! gtr 0 (set ${sht63#??}"
sht65="T:${sht27#??}${sht64#??}"
sht66="T: if !${sht65#??}"
sht67="T:${sht25#??}${sht66#??}"
sht68="T:if defined ${sht67#??}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${sht53}\""
eval "F$((FP+NP+2))=\"\${sht46}\""
eval "F$((FP+NP+3))=\"\${sht38}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
eval "F$((FP+NP+5))=\"\${sht34}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
eval "F$((FP+NP+8))=\"\${sht27}\""
eval "F$((FP+NP+9))=\"\${sht25}\""
eval "F$((FP+NP+10))=\"\${sht23}\""
eval "F$((FP+NP+11))=\"\${sht19}\""
eval "F$((FP+NP+12))=\"\${sht11}\""
eval "F$((FP+NP+13))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht56}\""
eval "F$((NFP+1))=\"\${sht68}\""
CALLEE=emit
RPC=16; ACTION=call; return
;;
16)
eval "sht56=\"\$F$((FP+NP+0))\""
eval "sht53=\"\$F$((FP+NP+1))\""
eval "sht46=\"\$F$((FP+NP+2))\""
eval "sht38=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
eval "sht34=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
eval "sht27=\"\$F$((FP+NP+8))\""
eval "sht25=\"\$F$((FP+NP+9))\""
eval "sht23=\"\$F$((FP+NP+10))\""
eval "sht19=\"\$F$((FP+NP+11))\""
eval "sht11=\"\$F$((FP+NP+12))\""
eval "sht3=\"\$F$((FP+NP+13))\""
sht69="${R}"
sht70="${sht69}"
sht71="T:${sht31#??}="
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht56}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht46}\""
eval "F$((FP+NP+5))=\"\${sht38}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht34}\""
eval "F$((FP+NP+8))=\"\${sht31}\""
eval "F$((FP+NP+9))=\"\${sht29}\""
eval "F$((FP+NP+10))=\"\${sht27}\""
eval "F$((FP+NP+11))=\"\${sht25}\""
eval "F$((FP+NP+12))=\"\${sht23}\""
eval "F$((FP+NP+13))=\"\${sht19}\""
eval "F$((FP+NP+14))=\"\${sht11}\""
eval "F$((FP+NP+15))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht71}\""
CALLEE=qset
RPC=17; ACTION=call; return
;;
17)
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht56=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht46=\"\$F$((FP+NP+4))\""
eval "sht38=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht34=\"\$F$((FP+NP+7))\""
eval "sht31=\"\$F$((FP+NP+8))\""
eval "sht29=\"\$F$((FP+NP+9))\""
eval "sht27=\"\$F$((FP+NP+10))\""
eval "sht25=\"\$F$((FP+NP+11))\""
eval "sht23=\"\$F$((FP+NP+12))\""
eval "sht19=\"\$F$((FP+NP+13))\""
eval "sht11=\"\$F$((FP+NP+14))\""
eval "sht3=\"\$F$((FP+NP+15))\""
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht56}\""
eval "F$((FP+NP+2))=\"\${sht53}\""
eval "F$((FP+NP+3))=\"\${sht46}\""
eval "F$((FP+NP+4))=\"\${sht38}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
eval "F$((FP+NP+6))=\"\${sht34}\""
eval "F$((FP+NP+7))=\"\${sht31}\""
eval "F$((FP+NP+8))=\"\${sht29}\""
eval "F$((FP+NP+9))=\"\${sht27}\""
eval "F$((FP+NP+10))=\"\${sht25}\""
eval "F$((FP+NP+11))=\"\${sht23}\""
eval "F$((FP+NP+12))=\"\${sht19}\""
eval "F$((FP+NP+13))=\"\${sht11}\""
eval "F$((FP+NP+14))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht70}\""
eval "F$((NFP+1))=\"\${sht72}\""
CALLEE=emit
RPC=18; ACTION=call; return
;;
18)
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht56=\"\$F$((FP+NP+1))\""
eval "sht53=\"\$F$((FP+NP+2))\""
eval "sht46=\"\$F$((FP+NP+3))\""
eval "sht38=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
eval "sht34=\"\$F$((FP+NP+6))\""
eval "sht31=\"\$F$((FP+NP+7))\""
eval "sht29=\"\$F$((FP+NP+8))\""
eval "sht27=\"\$F$((FP+NP+9))\""
eval "sht25=\"\$F$((FP+NP+10))\""
eval "sht23=\"\$F$((FP+NP+11))\""
eval "sht19=\"\$F$((FP+NP+12))\""
eval "sht11=\"\$F$((FP+NP+13))\""
eval "sht3=\"\$F$((FP+NP+14))\""
sht73="${R}"
sht74="${sht73}"
hp_cdr "${sht19}"
sht75="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht74}\""
eval "F$((FP+NP+2))=\"\${sht74}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht56}\""
eval "F$((FP+NP+5))=\"\${sht53}\""
eval "F$((FP+NP+6))=\"\${sht46}\""
eval "F$((FP+NP+7))=\"\${sht38}\""
eval "F$((FP+NP+8))=\"\${sht36}\""
eval "F$((FP+NP+9))=\"\${sht34}\""
eval "F$((FP+NP+10))=\"\${sht31}\""
eval "F$((FP+NP+11))=\"\${sht29}\""
eval "F$((FP+NP+12))=\"\${sht27}\""
eval "F$((FP+NP+13))=\"\${sht25}\""
eval "F$((FP+NP+14))=\"\${sht23}\""
eval "F$((FP+NP+15))=\"\${sht19}\""
eval "F$((FP+NP+16))=\"\${sht11}\""
eval "F$((FP+NP+17))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht75}\""
CALLEE=aref
RPC=19; ACTION=call; return
;;
19)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht74=\"\$F$((FP+NP+1))\""
eval "sht74=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht56=\"\$F$((FP+NP+4))\""
eval "sht53=\"\$F$((FP+NP+5))\""
eval "sht46=\"\$F$((FP+NP+6))\""
eval "sht38=\"\$F$((FP+NP+7))\""
eval "sht36=\"\$F$((FP+NP+8))\""
eval "sht34=\"\$F$((FP+NP+9))\""
eval "sht31=\"\$F$((FP+NP+10))\""
eval "sht29=\"\$F$((FP+NP+11))\""
eval "sht27=\"\$F$((FP+NP+12))\""
eval "sht25=\"\$F$((FP+NP+13))\""
eval "sht23=\"\$F$((FP+NP+14))\""
eval "sht19=\"\$F$((FP+NP+15))\""
eval "sht11=\"\$F$((FP+NP+16))\""
eval "sht3=\"\$F$((FP+NP+17))\""
sht76="${R}"
sht77="T:=${sht76#??}"
sht78="T:${sht29#??}${sht77#??}"
sht79="T:set /a ${sht78#??}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht56}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht46}\""
eval "F$((FP+NP+5))=\"\${sht38}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht34}\""
eval "F$((FP+NP+8))=\"\${sht31}\""
eval "F$((FP+NP+9))=\"\${sht29}\""
eval "F$((FP+NP+10))=\"\${sht27}\""
eval "F$((FP+NP+11))=\"\${sht25}\""
eval "F$((FP+NP+12))=\"\${sht23}\""
eval "F$((FP+NP+13))=\"\${sht19}\""
eval "F$((FP+NP+14))=\"\${sht11}\""
eval "F$((FP+NP+15))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
eval "F$((NFP+1))=\"\${sht79}\""
CALLEE=emit
RPC=20; ACTION=call; return
;;
20)
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht56=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht46=\"\$F$((FP+NP+4))\""
eval "sht38=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht34=\"\$F$((FP+NP+7))\""
eval "sht31=\"\$F$((FP+NP+8))\""
eval "sht29=\"\$F$((FP+NP+9))\""
eval "sht27=\"\$F$((FP+NP+10))\""
eval "sht25=\"\$F$((FP+NP+11))\""
eval "sht23=\"\$F$((FP+NP+12))\""
eval "sht19=\"\$F$((FP+NP+13))\""
eval "sht11=\"\$F$((FP+NP+14))\""
eval "sht3=\"\$F$((FP+NP+15))\""
sht80="${R}"
sht81="${sht80}"
sht82="T::${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht81}\""
eval "F$((FP+NP+1))=\"\${sht74}\""
eval "F$((FP+NP+2))=\"\${sht70}\""
eval "F$((FP+NP+3))=\"\${sht56}\""
eval "F$((FP+NP+4))=\"\${sht53}\""
eval "F$((FP+NP+5))=\"\${sht46}\""
eval "F$((FP+NP+6))=\"\${sht38}\""
eval "F$((FP+NP+7))=\"\${sht36}\""
eval "F$((FP+NP+8))=\"\${sht34}\""
eval "F$((FP+NP+9))=\"\${sht31}\""
eval "F$((FP+NP+10))=\"\${sht29}\""
eval "F$((FP+NP+11))=\"\${sht27}\""
eval "F$((FP+NP+12))=\"\${sht25}\""
eval "F$((FP+NP+13))=\"\${sht23}\""
eval "F$((FP+NP+14))=\"\${sht19}\""
eval "F$((FP+NP+15))=\"\${sht11}\""
eval "F$((FP+NP+16))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht81}\""
eval "F$((NFP+1))=\"\${sht82}\""
CALLEE=emit
RPC=21; ACTION=call; return
;;
21)
eval "sht81=\"\$F$((FP+NP+0))\""
eval "sht74=\"\$F$((FP+NP+1))\""
eval "sht70=\"\$F$((FP+NP+2))\""
eval "sht56=\"\$F$((FP+NP+3))\""
eval "sht53=\"\$F$((FP+NP+4))\""
eval "sht46=\"\$F$((FP+NP+5))\""
eval "sht38=\"\$F$((FP+NP+6))\""
eval "sht36=\"\$F$((FP+NP+7))\""
eval "sht34=\"\$F$((FP+NP+8))\""
eval "sht31=\"\$F$((FP+NP+9))\""
eval "sht29=\"\$F$((FP+NP+10))\""
eval "sht27=\"\$F$((FP+NP+11))\""
eval "sht25=\"\$F$((FP+NP+12))\""
eval "sht23=\"\$F$((FP+NP+13))\""
eval "sht19=\"\$F$((FP+NP+14))\""
eval "sht11=\"\$F$((FP+NP+15))\""
eval "sht3=\"\$F$((FP+NP+16))\""
sht83="${R}"
sht84="${sht83}"
sht85="T:${sht38#??})"
sht86="T:-=1& goto ${sht85#??}"
sht87="T:${sht29#??}${sht86#??}"
sht88="T::~1!& set /a ${sht87#??}"
sht89="T:${sht25#??}${sht88#??}"
sht90="T:=!${sht89#??}"
sht91="T:${sht25#??}${sht90#??}"
sht92="T::~0,1!& set ${sht91#??}"
sht93="T:${sht25#??}${sht92#??}"
sht94="T:!!${sht93#??}"
sht95="T:${sht31#??}${sht94#??}"
sht96="T:=!${sht95#??}"
sht97="T:${sht31#??}${sht96#??}"
sht98="T:! gtr 0 (set ${sht97#??}"
sht99="T:${sht29#??}${sht98#??}"
sht100="T: if !${sht99#??}"
sht101="T:${sht25#??}${sht100#??}"
sht102="T:if defined ${sht101#??}"
eval "F$((FP+NP+0))=\"\${sht84}\""
eval "F$((FP+NP+1))=\"\${sht81}\""
eval "F$((FP+NP+2))=\"\${sht74}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht56}\""
eval "F$((FP+NP+5))=\"\${sht53}\""
eval "F$((FP+NP+6))=\"\${sht46}\""
eval "F$((FP+NP+7))=\"\${sht38}\""
eval "F$((FP+NP+8))=\"\${sht36}\""
eval "F$((FP+NP+9))=\"\${sht34}\""
eval "F$((FP+NP+10))=\"\${sht31}\""
eval "F$((FP+NP+11))=\"\${sht29}\""
eval "F$((FP+NP+12))=\"\${sht27}\""
eval "F$((FP+NP+13))=\"\${sht25}\""
eval "F$((FP+NP+14))=\"\${sht23}\""
eval "F$((FP+NP+15))=\"\${sht19}\""
eval "F$((FP+NP+16))=\"\${sht11}\""
eval "F$((FP+NP+17))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht84}\""
eval "F$((NFP+1))=\"\${sht102}\""
CALLEE=emit
RPC=22; ACTION=call; return
;;
22)
eval "sht84=\"\$F$((FP+NP+0))\""
eval "sht81=\"\$F$((FP+NP+1))\""
eval "sht74=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht56=\"\$F$((FP+NP+4))\""
eval "sht53=\"\$F$((FP+NP+5))\""
eval "sht46=\"\$F$((FP+NP+6))\""
eval "sht38=\"\$F$((FP+NP+7))\""
eval "sht36=\"\$F$((FP+NP+8))\""
eval "sht34=\"\$F$((FP+NP+9))\""
eval "sht31=\"\$F$((FP+NP+10))\""
eval "sht29=\"\$F$((FP+NP+11))\""
eval "sht27=\"\$F$((FP+NP+12))\""
eval "sht25=\"\$F$((FP+NP+13))\""
eval "sht23=\"\$F$((FP+NP+14))\""
eval "sht19=\"\$F$((FP+NP+15))\""
eval "sht11=\"\$F$((FP+NP+16))\""
eval "sht3=\"\$F$((FP+NP+17))\""
sht103="${R}"
sht104="${sht103}"
sht105="T:${sht31#??}!"
sht106="T:=T:!${sht105#??}"
sht107="T:${sht34#??}${sht106#??}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
eval "F$((FP+NP+3))=\"\${sht81}\""
eval "F$((FP+NP+4))=\"\${sht74}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht56}\""
eval "F$((FP+NP+7))=\"\${sht53}\""
eval "F$((FP+NP+8))=\"\${sht46}\""
eval "F$((FP+NP+9))=\"\${sht38}\""
eval "F$((FP+NP+10))=\"\${sht36}\""
eval "F$((FP+NP+11))=\"\${sht34}\""
eval "F$((FP+NP+12))=\"\${sht31}\""
eval "F$((FP+NP+13))=\"\${sht29}\""
eval "F$((FP+NP+14))=\"\${sht27}\""
eval "F$((FP+NP+15))=\"\${sht25}\""
eval "F$((FP+NP+16))=\"\${sht23}\""
eval "F$((FP+NP+17))=\"\${sht19}\""
eval "F$((FP+NP+18))=\"\${sht11}\""
eval "F$((FP+NP+19))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht107}\""
CALLEE=qset
RPC=23; ACTION=call; return
;;
23)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
eval "sht81=\"\$F$((FP+NP+3))\""
eval "sht74=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht56=\"\$F$((FP+NP+6))\""
eval "sht53=\"\$F$((FP+NP+7))\""
eval "sht46=\"\$F$((FP+NP+8))\""
eval "sht38=\"\$F$((FP+NP+9))\""
eval "sht36=\"\$F$((FP+NP+10))\""
eval "sht34=\"\$F$((FP+NP+11))\""
eval "sht31=\"\$F$((FP+NP+12))\""
eval "sht29=\"\$F$((FP+NP+13))\""
eval "sht27=\"\$F$((FP+NP+14))\""
eval "sht25=\"\$F$((FP+NP+15))\""
eval "sht23=\"\$F$((FP+NP+16))\""
eval "sht19=\"\$F$((FP+NP+17))\""
eval "sht11=\"\$F$((FP+NP+18))\""
eval "sht3=\"\$F$((FP+NP+19))\""
sht108="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
eval "F$((NFP+1))=\"\${sht108}\""
CALLEE=emit
RPC=24; ACTION=call; return
;;
24)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht109="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht109}\""
CALLEE=bkzzP
RPC=25; ACTION=call; return
;;
25)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht110}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
eval "F$((FP+NP+3))=\"\${sht81}\""
eval "F$((FP+NP+4))=\"\${sht74}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht56}\""
eval "F$((FP+NP+7))=\"\${sht53}\""
eval "F$((FP+NP+8))=\"\${sht46}\""
eval "F$((FP+NP+9))=\"\${sht38}\""
eval "F$((FP+NP+10))=\"\${sht36}\""
eval "F$((FP+NP+11))=\"\${sht34}\""
eval "F$((FP+NP+12))=\"\${sht31}\""
eval "F$((FP+NP+13))=\"\${sht29}\""
eval "F$((FP+NP+14))=\"\${sht27}\""
eval "F$((FP+NP+15))=\"\${sht25}\""
eval "F$((FP+NP+16))=\"\${sht23}\""
eval "F$((FP+NP+17))=\"\${sht19}\""
eval "F$((FP+NP+18))=\"\${sht11}\""
eval "F$((FP+NP+19))=\"\${sht3}\""
hp_cons "S:val" "${sht34}"
eval "sht110=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
eval "sht81=\"\$F$((FP+NP+3))\""
eval "sht74=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht56=\"\$F$((FP+NP+6))\""
eval "sht53=\"\$F$((FP+NP+7))\""
eval "sht46=\"\$F$((FP+NP+8))\""
eval "sht38=\"\$F$((FP+NP+9))\""
eval "sht36=\"\$F$((FP+NP+10))\""
eval "sht34=\"\$F$((FP+NP+11))\""
eval "sht31=\"\$F$((FP+NP+12))\""
eval "sht29=\"\$F$((FP+NP+13))\""
eval "sht27=\"\$F$((FP+NP+14))\""
eval "sht25=\"\$F$((FP+NP+15))\""
eval "sht23=\"\$F$((FP+NP+16))\""
eval "sht19=\"\$F$((FP+NP+17))\""
eval "sht11=\"\$F$((FP+NP+18))\""
eval "sht3=\"\$F$((FP+NP+19))\""
sht111="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
hp_cons "${sht110}" "${sht111}"
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht112="${R}"
R="${sht112}"; ACTION=ret; return
;;
esac; }
SIZE_builtinzzQ=1
builtinzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_builtinzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:write-lines" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:append-lines" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:gc" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="S:t"; ACTION=ret; return
;;
6)
if [ "${p0}" = "S:print" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="S:t"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:read-lines" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="S:t"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:file-exists?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="S:t"; ACTION=ret; return
;;
12)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_prim_wrap=1
prim_wrap() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_prim_wrap))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:__p_add"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:__p_sub"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:__p_mul"; ACTION=ret; return
;;
6)
if [ "${p0}" = "S:<" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:__p_lt"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:=" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:__p_neq"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:cons" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:__p_cons"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:car" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:__p_car"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:cdr" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="T:__p_cdr"; ACTION=ret; return
;;
16)
if [ "${p0}" = "S:null?" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="T:__p_null"; ACTION=ret; return
;;
18)
if [ "${p0}" = "S:eq?" ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
R="T:__p_eq"; ACTION=ret; return
;;
20)
if [ "${p0}" = "S:pair?" ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="T:__p_pair"; ACTION=ret; return
;;
22)
if [ "${p0}" = "S:not" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
23)
R="T:__p_not"; ACTION=ret; return
;;
24)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_aas=3
aas() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_aas))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p1#??}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
sht3="T:=${sht2#??}"
sht4="T:${sht0#??}${sht3#??}"
sht5="T:A${sht4#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
sht6="${R}"
hp_cdr "${p0}"
sht7="${R}"
sht8="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=aas
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cons "${sht6}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_emit_list=2
emit_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_emit_list))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht0}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${sht1}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lbuiltin=10
lbuiltin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbuiltin))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
sht2="${sht1}"
hp_car "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=tmpn
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
sht5="${sht4}"
hp_car "${p0}"
sht6="${R}"
sht7="T:${sht6#??}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=mangle
RPC=3; ACTION=call; return
;;
3)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht8="${R}"
sht9="${sht8}"
hp_car "${sht2}"
sht10="${R}"
hp_cdr "${sht2}"
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"I:1\""
CALLEE=aas
RPC=4; ACTION=call; return
;;
4)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit_list
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht13="${R}"
sht14="${sht13}"
sht15="T:${sht9#??}.cmd"
sht16="T:call ${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht17="${R}"
sht18="${sht17}"
sht19="T:${sht5#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=7; ACTION=call; return
;;
7)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "S:val" "${sht5}"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
hp_cons "${sht22}" "${sht23}"
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht24="${R}"
R="${sht24}"; ACTION=ret; return
;;
esac; }
SIZE_lval=17
lval() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lval))
NP=4
case $PC in
0)
if [ "${p0#I:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
sht0="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:lit" "${sht0}"
eval "p2=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cons "${p2}" "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:nil" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "T:NIL"
eval "p2=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${p2}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:t" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "T:S:t"
eval "p2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${p2}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
6)
if [ "${p0#T:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=enc_mc
RPC=9; ACTION=call; return
;;
8)
if [ "${p0#S:}" != "${p0}" ]; then PC=10; else PC=11; fi
ACTION=jump; return
;;
9)
eval "p2=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="T:T:${sht7#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "${sht8}"
eval "p2=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cons "${p2}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
10)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=12; ACTION=call; return
;;
11)
hp_car "${p0}"
sht31="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht31}\""
CALLEE=arithzzQ
RPC=24; ACTION=call; return
;;
12)
sht11="${R}"
sht12="${sht11}"
if [ "${sht12}" = NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=prim_wrap
RPC=15; ACTION=call; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht12}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht29}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht30="${R}"
R="${sht30}"; ACTION=ret; return
;;
15)
eval "sht12=\"\$F$((FP+NP+0))\""
sht13="${R}"
if [ "${sht13}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
16)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=prim_wrap
RPC=18; ACTION=call; return
;;
17)
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=gfns_of
RPC=19; ACTION=call; return
;;
18)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht14="${R}"
sht15="T:C:${sht14#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:cst" "${sht15}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht16}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
19)
eval "p0=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht18}\""
CALLEE=memzzQ
RPC=20; ACTION=call; return
;;
20)
eval "sht12=\"\$F$((FP+NP+0))\""
sht19="${R}"
if [ "${sht19}" != NIL ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
sht20="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
CALLEE=mangle
RPC=23; ACTION=call; return
;;
22)
sht25="T:${p0#??}"
sht26="T:G_${sht25#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht26}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht27}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht28="${R}"
R="${sht28}"; ACTION=ret; return
;;
23)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht21="${R}"
sht22="T:C:${sht21#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:cst" "${sht22}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht23}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht24="${R}"
R="${sht24}"; ACTION=ret; return
;;
24)
sht32="${R}"
if [ "${sht32}" != NIL ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
hp_cdr "${p0}"
sht33="${R}"
hp_car "${sht33}"
sht34="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=27; ACTION=call; return
;;
26)
hp_car "${p0}"
sht64="${R}"
if [ "${sht64}" = "S:cons" ]; then PC=36; else PC=37; fi
ACTION=jump; return
;;
27)
sht35="${R}"
sht36="${sht35}"
hp_cdr "${p0}"
sht37="${R}"
hp_cdr "${sht37}"
sht38="${R}"
hp_car "${sht38}"
sht39="${R}"
hp_car "${sht36}"
sht40="${R}"
hp_cdr "${sht36}"
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht40}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=28; ACTION=call; return
;;
28)
eval "sht40=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht40}\""
eval "F$((NFP+3))=\"\${sht42}\""
CALLEE=lval
RPC=29; ACTION=call; return
;;
29)
eval "sht36=\"\$F$((FP+NP+0))\""
sht43="${R}"
sht44="${sht43}"
hp_car "${sht44}"
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht44}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht45}\""
CALLEE=tmpn
RPC=30; ACTION=call; return
;;
30)
eval "sht44=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
sht46="${R}"
sht47="${sht46}"
hp_car "${sht44}"
sht48="${R}"
hp_cdr "${sht36}"
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht48}\""
eval "F$((FP+NP+2))=\"\${sht47}\""
eval "F$((FP+NP+3))=\"\${sht44}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
CALLEE=aref
RPC=31; ACTION=call; return
;;
31)
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht48=\"\$F$((FP+NP+1))\""
eval "sht47=\"\$F$((FP+NP+2))\""
eval "sht44=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
sht50="${R}"
hp_car "${p0}"
sht51="${R}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht47}\""
eval "F$((FP+NP+2))=\"\${sht48}\""
eval "F$((FP+NP+3))=\"\${sht47}\""
eval "F$((FP+NP+4))=\"\${sht44}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
CALLEE=op_zzGbatch
RPC=32; ACTION=call; return
;;
32)
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht47=\"\$F$((FP+NP+1))\""
eval "sht48=\"\$F$((FP+NP+2))\""
eval "sht47=\"\$F$((FP+NP+3))\""
eval "sht44=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
sht52="${R}"
hp_cdr "${sht44}"
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht52}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht47}\""
eval "F$((FP+NP+3))=\"\${sht48}\""
eval "F$((FP+NP+4))=\"\${sht47}\""
eval "F$((FP+NP+5))=\"\${sht44}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
CALLEE=aref
RPC=33; ACTION=call; return
;;
33)
eval "sht52=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht47=\"\$F$((FP+NP+2))\""
eval "sht48=\"\$F$((FP+NP+3))\""
eval "sht47=\"\$F$((FP+NP+4))\""
eval "sht44=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
sht54="${R}"
sht55="T:${sht52#??}${sht54#??}"
sht56="T:${sht50#??}${sht55#??}"
sht57="T:=${sht56#??}"
sht58="T:${sht47#??}${sht57#??}"
sht59="T:set /a ${sht58#??}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht44}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${sht59}\""
CALLEE=emit
RPC=34; ACTION=call; return
;;
34)
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht44=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht60="${R}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht44}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht60}\""
CALLEE=bkzzP
RPC=35; ACTION=call; return
;;
35)
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht44=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht61="${R}"
eval "F$((FP+NP+0))=\"\${sht61}\""
eval "F$((FP+NP+1))=\"\${sht47}\""
eval "F$((FP+NP+2))=\"\${sht44}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
hp_cons "S:raw" "${sht47}"
eval "sht61=\"\$F$((FP+NP+0))\""
eval "sht47=\"\$F$((FP+NP+1))\""
eval "sht44=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
sht62="${R}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht44}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
hp_cons "${sht61}" "${sht62}"
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht44=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht63="${R}"
R="${sht63}"; ACTION=ret; return
;;
36)
hp_cdr "${p0}"
sht65="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht65}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=38; ACTION=call; return
;;
37)
hp_car "${p0}"
sht97="${R}"
if [ "${sht97}" = "S:string-append" ]; then PC=48; else PC=49; fi
ACTION=jump; return
;;
38)
sht66="${R}"
sht67="${sht66}"
hp_car "${sht67}"
sht68="${R}"
eval "F$((FP+NP+0))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht68}\""
CALLEE=tmpn
RPC=39; ACTION=call; return
;;
39)
eval "sht67=\"\$F$((FP+NP+0))\""
sht69="${R}"
sht70="${sht69}"
hp_cdr "${sht67}"
sht71="${R}"
hp_car "${sht71}"
sht72="${R}"
sht73="${sht72}"
hp_cdr "${sht67}"
sht74="${R}"
hp_cdr "${sht74}"
sht75="${R}"
hp_car "${sht75}"
sht76="${R}"
sht77="${sht76}"
hp_car "${sht67}"
sht78="${R}"
eval "F$((FP+NP+0))=\"\${sht77}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht70}\""
eval "F$((FP+NP+3))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht78}\""
STGV="T:set /a HN+=1"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=40; ACTION=call; return
;;
40)
eval "sht77=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht70=\"\$F$((FP+NP+2))\""
eval "sht67=\"\$F$((FP+NP+3))\""
sht79="${R}"
sht80="${sht79}"
eval "F$((FP+NP+0))=\"\${sht80}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht77}\""
eval "F$((FP+NP+3))=\"\${sht73}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht73}\""
CALLEE=vref
RPC=41; ACTION=call; return
;;
41)
eval "sht80=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht77=\"\$F$((FP+NP+2))\""
eval "sht73=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht67=\"\$F$((FP+NP+5))\""
sht81="${R}"
sht82="T:${sht81#??}#"
sht83="T:>%HD%\\car%HN% echo(${sht82#??}"
eval "F$((FP+NP+0))=\"\${sht80}\""
eval "F$((FP+NP+1))=\"\${sht77}\""
eval "F$((FP+NP+2))=\"\${sht73}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht80}\""
eval "F$((NFP+1))=\"\${sht83}\""
CALLEE=emit
RPC=42; ACTION=call; return
;;
42)
eval "sht80=\"\$F$((FP+NP+0))\""
eval "sht77=\"\$F$((FP+NP+1))\""
eval "sht73=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht67=\"\$F$((FP+NP+4))\""
sht84="${R}"
sht85="${sht84}"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht77}\""
eval "F$((FP+NP+4))=\"\${sht73}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht77}\""
CALLEE=vref
RPC=43; ACTION=call; return
;;
43)
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht77=\"\$F$((FP+NP+3))\""
eval "sht73=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht67=\"\$F$((FP+NP+6))\""
sht86="${R}"
sht87="T:${sht86#??}#"
sht88="T:>%HD%\\cdr%HN% echo(${sht87#??}"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht77}\""
eval "F$((FP+NP+3))=\"\${sht73}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht85}\""
eval "F$((NFP+1))=\"\${sht88}\""
CALLEE=emit
RPC=44; ACTION=call; return
;;
44)
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht77=\"\$F$((FP+NP+2))\""
eval "sht73=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht67=\"\$F$((FP+NP+5))\""
sht89="${R}"
sht90="${sht89}"
sht91="T:${sht70#??}=P:!HN!"
eval "F$((FP+NP+0))=\"\${sht90}\""
eval "F$((FP+NP+1))=\"\${sht90}\""
eval "F$((FP+NP+2))=\"\${sht85}\""
eval "F$((FP+NP+3))=\"\${sht80}\""
eval "F$((FP+NP+4))=\"\${sht77}\""
eval "F$((FP+NP+5))=\"\${sht73}\""
eval "F$((FP+NP+6))=\"\${sht70}\""
eval "F$((FP+NP+7))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht91}\""
CALLEE=qset
RPC=45; ACTION=call; return
;;
45)
eval "sht90=\"\$F$((FP+NP+0))\""
eval "sht90=\"\$F$((FP+NP+1))\""
eval "sht85=\"\$F$((FP+NP+2))\""
eval "sht80=\"\$F$((FP+NP+3))\""
eval "sht77=\"\$F$((FP+NP+4))\""
eval "sht73=\"\$F$((FP+NP+5))\""
eval "sht70=\"\$F$((FP+NP+6))\""
eval "sht67=\"\$F$((FP+NP+7))\""
sht92="${R}"
eval "F$((FP+NP+0))=\"\${sht90}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht77}\""
eval "F$((FP+NP+4))=\"\${sht73}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht90}\""
eval "F$((NFP+1))=\"\${sht92}\""
CALLEE=emit
RPC=46; ACTION=call; return
;;
46)
eval "sht90=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht77=\"\$F$((FP+NP+3))\""
eval "sht73=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht67=\"\$F$((FP+NP+6))\""
sht93="${R}"
eval "F$((FP+NP+0))=\"\${sht90}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht77}\""
eval "F$((FP+NP+4))=\"\${sht73}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht67}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht93}\""
CALLEE=bkzzP
RPC=47; ACTION=call; return
;;
47)
eval "sht90=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht77=\"\$F$((FP+NP+3))\""
eval "sht73=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht67=\"\$F$((FP+NP+6))\""
sht94="${R}"
eval "F$((FP+NP+0))=\"\${sht94}\""
eval "F$((FP+NP+1))=\"\${sht90}\""
eval "F$((FP+NP+2))=\"\${sht85}\""
eval "F$((FP+NP+3))=\"\${sht80}\""
eval "F$((FP+NP+4))=\"\${sht77}\""
eval "F$((FP+NP+5))=\"\${sht73}\""
eval "F$((FP+NP+6))=\"\${sht70}\""
eval "F$((FP+NP+7))=\"\${sht67}\""
hp_cons "S:val" "${sht70}"
eval "sht94=\"\$F$((FP+NP+0))\""
eval "sht90=\"\$F$((FP+NP+1))\""
eval "sht85=\"\$F$((FP+NP+2))\""
eval "sht80=\"\$F$((FP+NP+3))\""
eval "sht77=\"\$F$((FP+NP+4))\""
eval "sht73=\"\$F$((FP+NP+5))\""
eval "sht70=\"\$F$((FP+NP+6))\""
eval "sht67=\"\$F$((FP+NP+7))\""
sht95="${R}"
eval "F$((FP+NP+0))=\"\${sht90}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht77}\""
eval "F$((FP+NP+4))=\"\${sht73}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht67}\""
hp_cons "${sht94}" "${sht95}"
eval "sht90=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht77=\"\$F$((FP+NP+3))\""
eval "sht73=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht67=\"\$F$((FP+NP+6))\""
sht96="${R}"
R="${sht96}"; ACTION=ret; return
;;
48)
hp_cdr "${p0}"
sht98="${R}"
hp_car "${sht98}"
sht99="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht99}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=50; ACTION=call; return
;;
49)
hp_car "${p0}"
sht126="${R}"
if [ "${sht126}" = "S:car" ]; then PC=59; else PC=60; fi
ACTION=jump; return
;;
50)
sht100="${R}"
sht101="${sht100}"
hp_cdr "${p0}"
sht102="${R}"
hp_cdr "${sht102}"
sht103="${R}"
hp_car "${sht103}"
sht104="${R}"
hp_car "${sht101}"
sht105="${R}"
hp_cdr "${sht101}"
sht106="${R}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht104}\""
eval "F$((FP+NP+3))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht106}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=51; ACTION=call; return
;;
51)
eval "sht105=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht104=\"\$F$((FP+NP+2))\""
eval "sht101=\"\$F$((FP+NP+3))\""
sht107="${R}"
eval "F$((FP+NP+0))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht105}\""
eval "F$((NFP+3))=\"\${sht107}\""
CALLEE=lval
RPC=52; ACTION=call; return
;;
52)
eval "sht101=\"\$F$((FP+NP+0))\""
sht108="${R}"
sht109="${sht108}"
hp_car "${sht109}"
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht109}\""
eval "F$((FP+NP+1))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht110}\""
CALLEE=tmpn
RPC=53; ACTION=call; return
;;
53)
eval "sht109=\"\$F$((FP+NP+0))\""
eval "sht101=\"\$F$((FP+NP+1))\""
sht111="${R}"
sht112="${sht111}"
hp_car "${sht109}"
sht113="${R}"
hp_cdr "${sht101}"
sht114="${R}"
eval "F$((FP+NP+0))=\"\${sht112}\""
eval "F$((FP+NP+1))=\"\${sht113}\""
eval "F$((FP+NP+2))=\"\${sht112}\""
eval "F$((FP+NP+3))=\"\${sht109}\""
eval "F$((FP+NP+4))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht114}\""
CALLEE=cref
RPC=54; ACTION=call; return
;;
54)
eval "sht112=\"\$F$((FP+NP+0))\""
eval "sht113=\"\$F$((FP+NP+1))\""
eval "sht112=\"\$F$((FP+NP+2))\""
eval "sht109=\"\$F$((FP+NP+3))\""
eval "sht101=\"\$F$((FP+NP+4))\""
sht115="${R}"
hp_cdr "${sht109}"
sht116="${R}"
eval "F$((FP+NP+0))=\"\${sht115}\""
eval "F$((FP+NP+1))=\"\${sht112}\""
eval "F$((FP+NP+2))=\"\${sht113}\""
eval "F$((FP+NP+3))=\"\${sht112}\""
eval "F$((FP+NP+4))=\"\${sht109}\""
eval "F$((FP+NP+5))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht116}\""
CALLEE=cref
RPC=55; ACTION=call; return
;;
55)
eval "sht115=\"\$F$((FP+NP+0))\""
eval "sht112=\"\$F$((FP+NP+1))\""
eval "sht113=\"\$F$((FP+NP+2))\""
eval "sht112=\"\$F$((FP+NP+3))\""
eval "sht109=\"\$F$((FP+NP+4))\""
eval "sht101=\"\$F$((FP+NP+5))\""
sht117="${R}"
sht118="T:${sht115#??}${sht117#??}"
sht119="T:=T:${sht118#??}"
sht120="T:${sht112#??}${sht119#??}"
eval "F$((FP+NP+0))=\"\${sht113}\""
eval "F$((FP+NP+1))=\"\${sht112}\""
eval "F$((FP+NP+2))=\"\${sht109}\""
eval "F$((FP+NP+3))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht120}\""
CALLEE=qset
RPC=56; ACTION=call; return
;;
56)
eval "sht113=\"\$F$((FP+NP+0))\""
eval "sht112=\"\$F$((FP+NP+1))\""
eval "sht109=\"\$F$((FP+NP+2))\""
eval "sht101=\"\$F$((FP+NP+3))\""
sht121="${R}"
eval "F$((FP+NP+0))=\"\${sht112}\""
eval "F$((FP+NP+1))=\"\${sht109}\""
eval "F$((FP+NP+2))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht113}\""
eval "F$((NFP+1))=\"\${sht121}\""
CALLEE=emit
RPC=57; ACTION=call; return
;;
57)
eval "sht112=\"\$F$((FP+NP+0))\""
eval "sht109=\"\$F$((FP+NP+1))\""
eval "sht101=\"\$F$((FP+NP+2))\""
sht122="${R}"
eval "F$((FP+NP+0))=\"\${sht112}\""
eval "F$((FP+NP+1))=\"\${sht109}\""
eval "F$((FP+NP+2))=\"\${sht101}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht122}\""
CALLEE=bkzzP
RPC=58; ACTION=call; return
;;
58)
eval "sht112=\"\$F$((FP+NP+0))\""
eval "sht109=\"\$F$((FP+NP+1))\""
eval "sht101=\"\$F$((FP+NP+2))\""
sht123="${R}"
eval "F$((FP+NP+0))=\"\${sht123}\""
eval "F$((FP+NP+1))=\"\${sht112}\""
eval "F$((FP+NP+2))=\"\${sht109}\""
eval "F$((FP+NP+3))=\"\${sht101}\""
hp_cons "S:val" "${sht112}"
eval "sht123=\"\$F$((FP+NP+0))\""
eval "sht112=\"\$F$((FP+NP+1))\""
eval "sht109=\"\$F$((FP+NP+2))\""
eval "sht101=\"\$F$((FP+NP+3))\""
sht124="${R}"
eval "F$((FP+NP+0))=\"\${sht112}\""
eval "F$((FP+NP+1))=\"\${sht109}\""
eval "F$((FP+NP+2))=\"\${sht101}\""
hp_cons "${sht123}" "${sht124}"
eval "sht112=\"\$F$((FP+NP+0))\""
eval "sht109=\"\$F$((FP+NP+1))\""
eval "sht101=\"\$F$((FP+NP+2))\""
sht125="${R}"
R="${sht125}"; ACTION=ret; return
;;
59)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:car"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=61; ACTION=call; return
;;
60)
hp_car "${p0}"
sht128="${R}"
if [ "${sht128}" = "S:cdr" ]; then PC=62; else PC=63; fi
ACTION=jump; return
;;
61)
sht127="${R}"
R="${sht127}"; ACTION=ret; return
;;
62)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:cdr"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=64; ACTION=call; return
;;
63)
hp_car "${p0}"
sht130="${R}"
if [ "${sht130}" = "S:if" ]; then PC=65; else PC=66; fi
ACTION=jump; return
;;
64)
sht129="${R}"
R="${sht129}"; ACTION=ret; return
;;
65)
hp_cdr "${p0}"
sht131="${R}"
hp_car "${sht131}"
sht132="${R}"
hp_cdr "${p0}"
sht133="${R}"
hp_cdr "${sht133}"
sht134="${R}"
hp_car "${sht134}"
sht135="${R}"
eval "F$((FP+NP+0))=\"\${sht135}\""
eval "F$((FP+NP+1))=\"\${sht132}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=67; ACTION=call; return
;;
66)
hp_car "${p0}"
sht138="${R}"
if [ "${sht138}" = "S:cond" ]; then PC=69; else PC=70; fi
ACTION=jump; return
;;
67)
eval "sht135=\"\$F$((FP+NP+0))\""
eval "sht132=\"\$F$((FP+NP+1))\""
sht136="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht132}\""
eval "F$((NFP+1))=\"\${sht135}\""
eval "F$((NFP+2))=\"\${sht136}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=68; ACTION=call; return
;;
68)
sht137="${R}"
R="${sht137}"; ACTION=ret; return
;;
69)
hp_cdr "${p0}"
sht139="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht139}\""
CALLEE=cond_zzGif
RPC=71; ACTION=call; return
;;
70)
hp_car "${p0}"
sht141="${R}"
if [ "${sht141}" = "S:let" ]; then PC=72; else PC=73; fi
ACTION=jump; return
;;
71)
sht140="${R}"
eval "F$((FP+0))=\"\${sht140}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
72)
hp_cdr "${p0}"
sht142="${R}"
hp_car "${sht142}"
sht143="${R}"
hp_cdr "${p0}"
sht144="${R}"
hp_cdr "${sht144}"
sht145="${R}"
hp_car "${sht145}"
sht146="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht143}\""
eval "F$((NFP+1))=\"\${sht146}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=llet
RPC=74; ACTION=call; return
;;
73)
hp_car "${p0}"
sht148="${R}"
if [ "${sht148}" = "S:begin" ]; then PC=75; else PC=76; fi
ACTION=jump; return
;;
74)
sht147="${R}"
R="${sht147}"; ACTION=ret; return
;;
75)
hp_cdr "${p0}"
sht149="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht149}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbegin
RPC=77; ACTION=call; return
;;
76)
hp_car "${p0}"
sht151="${R}"
if [ "${sht151}" = "S:quote" ]; then PC=78; else PC=79; fi
ACTION=jump; return
;;
77)
sht150="${R}"
R="${sht150}"; ACTION=ret; return
;;
78)
hp_cdr "${p0}"
sht152="${R}"
hp_car "${sht152}"
sht153="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht153}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=lquote
RPC=80; ACTION=call; return
;;
79)
hp_car "${p0}"
sht155="${R}"
if [ "${sht155}" = "S:string-length" ]; then PC=81; else PC=82; fi
ACTION=jump; return
;;
80)
sht154="${R}"
R="${sht154}"; ACTION=ret; return
;;
81)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lstrlen
RPC=83; ACTION=call; return
;;
82)
hp_car "${p0}"
sht157="${R}"
if [ "${sht157}" = "S:substring" ]; then PC=84; else PC=85; fi
ACTION=jump; return
;;
83)
sht156="${R}"
R="${sht156}"; ACTION=ret; return
;;
84)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lsubstr
RPC=86; ACTION=call; return
;;
85)
hp_car "${p0}"
sht159="${R}"
if [ "${sht159}" = "S:symbol->string" ]; then PC=87; else PC=88; fi
ACTION=jump; return
;;
86)
sht158="${R}"
R="${sht158}"; ACTION=ret; return
;;
87)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=89; ACTION=call; return
;;
88)
hp_car "${p0}"
sht161="${R}"
if [ "${sht161}" = "S:number->string" ]; then PC=90; else PC=91; fi
ACTION=jump; return
;;
89)
sht160="${R}"
R="${sht160}"; ACTION=ret; return
;;
90)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=92; ACTION=call; return
;;
91)
hp_car "${p0}"
sht163="${R}"
if [ "${sht163}" = "S:string->symbol" ]; then PC=93; else PC=94; fi
ACTION=jump; return
;;
92)
sht162="${R}"
R="${sht162}"; ACTION=ret; return
;;
93)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=95; ACTION=call; return
;;
94)
hp_car "${p0}"
sht165="${R}"
if [ "${sht165}" = "S:string->number" ]; then PC=96; else PC=97; fi
ACTION=jump; return
;;
95)
sht164="${R}"
R="${sht164}"; ACTION=ret; return
;;
96)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=98; ACTION=call; return
;;
97)
hp_car "${p0}"
sht167="${R}"
if [ "${sht167}" = "S:dq" ]; then PC=99; else PC=100; fi
ACTION=jump; return
;;
98)
sht166="${R}"
R="${sht166}"; ACTION=ret; return
;;
99)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
CALLEE=tmpn
RPC=101; ACTION=call; return
;;
100)
hp_car "${p0}"
sht176="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht176}\""
CALLEE=builtinzzQ
RPC=105; ACTION=call; return
;;
101)
sht168="${R}"
sht169="${sht168}"
sht170="T:${sht169#??}=T:!BANG8!"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht169}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht170}\""
CALLEE=qset
RPC=102; ACTION=call; return
;;
102)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht169=\"\$F$((FP+NP+1))\""
sht171="${R}"
eval "F$((FP+NP+0))=\"\${sht169}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht171}\""
CALLEE=emit
RPC=103; ACTION=call; return
;;
103)
eval "sht169=\"\$F$((FP+NP+0))\""
sht172="${R}"
eval "F$((FP+NP+0))=\"\${sht169}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht172}\""
CALLEE=bkzzP
RPC=104; ACTION=call; return
;;
104)
eval "sht169=\"\$F$((FP+NP+0))\""
sht173="${R}"
eval "F$((FP+NP+0))=\"\${sht173}\""
eval "F$((FP+NP+1))=\"\${sht169}\""
hp_cons "S:val" "${sht169}"
eval "sht173=\"\$F$((FP+NP+0))\""
eval "sht169=\"\$F$((FP+NP+1))\""
sht174="${R}"
eval "F$((FP+NP+0))=\"\${sht169}\""
hp_cons "${sht173}" "${sht174}"
eval "sht169=\"\$F$((FP+NP+0))\""
sht175="${R}"
R="${sht175}"; ACTION=ret; return
;;
105)
sht177="${R}"
if [ "${sht177}" != NIL ]; then PC=106; else PC=107; fi
ACTION=jump; return
;;
106)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbuiltin
RPC=108; ACTION=call; return
;;
107)
hp_car "${p0}"
sht179="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht179}\""
CALLEE=tpredzzQ
RPC=109; ACTION=call; return
;;
108)
sht178="${R}"
R="${sht178}"; ACTION=ret; return
;;
109)
sht180="${R}"
if [ "${sht180}" != NIL ]; then PC=110; else PC=111; fi
ACTION=jump; return
;;
110)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="S:t"
eval "F$((NFP+1))=\"\$STGV\""
STGV="S:nil"
eval "F$((NFP+2))=\"\$STGV\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=112; ACTION=call; return
;;
111)
hp_car "${p0}"
sht182="${R}"
if [ "${sht182}" = "S:make-closure" ]; then PC=113; else PC=114; fi
ACTION=jump; return
;;
112)
sht181="${R}"
R="${sht181}"; ACTION=ret; return
;;
113)
hp_cdr "${p0}"
sht183="${R}"
hp_car "${sht183}"
sht184="${R}"
hp_cdr "${p0}"
sht185="${R}"
hp_cdr "${sht185}"
sht186="${R}"
eval "F$((FP+NP+0))=\"\${sht184}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht186}\""
CALLEE=mkclo_caps
RPC=115; ACTION=call; return
;;
114)
hp_car "${p0}"
sht207="${R}"
if [ "${sht207}" = "S:apply" ]; then PC=121; else PC=122; fi
ACTION=jump; return
;;
115)
eval "sht184=\"\$F$((FP+NP+0))\""
sht187="${R}"
eval "F$((FP+NP+0))=\"\${sht184}\""
hp_cons "${sht187}" "NIL"
eval "sht184=\"\$F$((FP+NP+0))\""
sht188="${R}"
hp_cons "${sht184}" "${sht188}"
sht189="${R}"
hp_cons "S:cons" "${sht189}"
sht190="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht190}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=116; ACTION=call; return
;;
116)
sht191="${R}"
sht192="${sht191}"
hp_car "${sht192}"
sht193="${R}"
eval "F$((FP+NP+0))=\"\${sht192}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht193}\""
CALLEE=tmpn
RPC=117; ACTION=call; return
;;
117)
eval "sht192=\"\$F$((FP+NP+0))\""
sht194="${R}"
sht195="${sht194}"
hp_car "${sht192}"
sht196="${R}"
hp_cdr "${sht192}"
sht197="${R}"
hp_cdr "${sht197}"
sht198="${R}"
sht199="T:${sht198#??}:~2!"
sht200="T:=K:!${sht199#??}"
sht201="T:${sht195#??}${sht200#??}"
eval "F$((FP+NP+0))=\"\${sht196}\""
eval "F$((FP+NP+1))=\"\${sht195}\""
eval "F$((FP+NP+2))=\"\${sht192}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht201}\""
CALLEE=qset
RPC=118; ACTION=call; return
;;
118)
eval "sht196=\"\$F$((FP+NP+0))\""
eval "sht195=\"\$F$((FP+NP+1))\""
eval "sht192=\"\$F$((FP+NP+2))\""
sht202="${R}"
eval "F$((FP+NP+0))=\"\${sht195}\""
eval "F$((FP+NP+1))=\"\${sht192}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht196}\""
eval "F$((NFP+1))=\"\${sht202}\""
CALLEE=emit
RPC=119; ACTION=call; return
;;
119)
eval "sht195=\"\$F$((FP+NP+0))\""
eval "sht192=\"\$F$((FP+NP+1))\""
sht203="${R}"
eval "F$((FP+NP+0))=\"\${sht195}\""
eval "F$((FP+NP+1))=\"\${sht192}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht203}\""
CALLEE=bkzzP
RPC=120; ACTION=call; return
;;
120)
eval "sht195=\"\$F$((FP+NP+0))\""
eval "sht192=\"\$F$((FP+NP+1))\""
sht204="${R}"
eval "F$((FP+NP+0))=\"\${sht204}\""
eval "F$((FP+NP+1))=\"\${sht195}\""
eval "F$((FP+NP+2))=\"\${sht192}\""
hp_cons "S:val" "${sht195}"
eval "sht204=\"\$F$((FP+NP+0))\""
eval "sht195=\"\$F$((FP+NP+1))\""
eval "sht192=\"\$F$((FP+NP+2))\""
sht205="${R}"
eval "F$((FP+NP+0))=\"\${sht195}\""
eval "F$((FP+NP+1))=\"\${sht192}\""
hp_cons "${sht204}" "${sht205}"
eval "sht195=\"\$F$((FP+NP+0))\""
eval "sht192=\"\$F$((FP+NP+1))\""
sht206="${R}"
R="${sht206}"; ACTION=ret; return
;;
121)
hp_cdr "${p0}"
sht208="${R}"
hp_car "${sht208}"
sht209="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht209}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=123; ACTION=call; return
;;
122)
hp_car "${p0}"
sht274="${R}"
if [ "${sht274#S:}" != "${sht274}" ]; then PC=145; else PC=146; fi
ACTION=jump; return
;;
123)
sht210="${R}"
sht211="${sht210}"
hp_cdr "${sht211}"
sht212="${R}"
eval "F$((FP+NP+0))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht212}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=124; ACTION=call; return
;;
124)
eval "sht211=\"\$F$((FP+NP+0))\""
sht213="${R}"
sht214="${sht213}"
hp_cdr "${p0}"
sht215="${R}"
hp_cdr "${sht215}"
sht216="${R}"
hp_car "${sht216}"
sht217="${R}"
hp_car "${sht211}"
sht218="${R}"
eval "F$((FP+NP+0))=\"\${sht214}\""
eval "F$((FP+NP+1))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht217}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht218}\""
eval "F$((NFP+3))=\"\${sht214}\""
CALLEE=lval
RPC=125; ACTION=call; return
;;
125)
eval "sht214=\"\$F$((FP+NP+0))\""
eval "sht211=\"\$F$((FP+NP+1))\""
sht219="${R}"
sht220="${sht219}"
hp_cdr "${sht220}"
sht221="${R}"
eval "F$((FP+NP+0))=\"\${sht220}\""
eval "F$((FP+NP+1))=\"\${sht214}\""
eval "F$((FP+NP+2))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht221}\""
eval "F$((NFP+1))=\"\${sht214}\""
CALLEE=addlive
RPC=126; ACTION=call; return
;;
126)
eval "sht220=\"\$F$((FP+NP+0))\""
eval "sht214=\"\$F$((FP+NP+1))\""
eval "sht211=\"\$F$((FP+NP+2))\""
sht222="${R}"
sht223="${sht222}"
hp_car "${sht220}"
sht224="${R}"
eval "F$((FP+NP+0))=\"\${sht223}\""
eval "F$((FP+NP+1))=\"\${sht220}\""
eval "F$((FP+NP+2))=\"\${sht214}\""
eval "F$((FP+NP+3))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht224}\""
CALLEE=b_npc
RPC=127; ACTION=call; return
;;
127)
eval "sht223=\"\$F$((FP+NP+0))\""
eval "sht220=\"\$F$((FP+NP+1))\""
eval "sht214=\"\$F$((FP+NP+2))\""
eval "sht211=\"\$F$((FP+NP+3))\""
sht225="${R}"
sht226="${sht225}"
hp_car "${sht220}"
sht227="${R}"
eval "F$((FP+NP+0))=\"\${sht226}\""
eval "F$((FP+NP+1))=\"\${sht223}\""
eval "F$((FP+NP+2))=\"\${sht220}\""
eval "F$((FP+NP+3))=\"\${sht214}\""
eval "F$((FP+NP+4))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht227}\""
CALLEE=bnpczzP
RPC=128; ACTION=call; return
;;
128)
eval "sht226=\"\$F$((FP+NP+0))\""
eval "sht223=\"\$F$((FP+NP+1))\""
eval "sht220=\"\$F$((FP+NP+2))\""
eval "sht214=\"\$F$((FP+NP+3))\""
eval "sht211=\"\$F$((FP+NP+4))\""
sht228="${R}"
eval "F$((FP+NP+0))=\"\${sht226}\""
eval "F$((FP+NP+1))=\"\${sht223}\""
eval "F$((FP+NP+2))=\"\${sht220}\""
eval "F$((FP+NP+3))=\"\${sht214}\""
eval "F$((FP+NP+4))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht228}\""
eval "F$((NFP+1))=\"\${sht223}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=129; ACTION=call; return
;;
129)
eval "sht226=\"\$F$((FP+NP+0))\""
eval "sht223=\"\$F$((FP+NP+1))\""
eval "sht220=\"\$F$((FP+NP+2))\""
eval "sht214=\"\$F$((FP+NP+3))\""
eval "sht211=\"\$F$((FP+NP+4))\""
sht229="${R}"
eval "F$((FP+NP+0))=\"\${sht226}\""
eval "F$((FP+NP+1))=\"\${sht223}\""
eval "F$((FP+NP+2))=\"\${sht220}\""
eval "F$((FP+NP+3))=\"\${sht214}\""
eval "F$((FP+NP+4))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht229}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=130; ACTION=call; return
;;
130)
eval "sht226=\"\$F$((FP+NP+0))\""
eval "sht223=\"\$F$((FP+NP+1))\""
eval "sht220=\"\$F$((FP+NP+2))\""
eval "sht214=\"\$F$((FP+NP+3))\""
eval "sht211=\"\$F$((FP+NP+4))\""
sht230="${R}"
sht231="${sht230}"
hp_cdr "${sht211}"
sht232="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht231}\""
eval "F$((FP+NP+2))=\"\${sht231}\""
eval "F$((FP+NP+3))=\"\${sht226}\""
eval "F$((FP+NP+4))=\"\${sht223}\""
eval "F$((FP+NP+5))=\"\${sht220}\""
eval "F$((FP+NP+6))=\"\${sht214}\""
eval "F$((FP+NP+7))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht232}\""
CALLEE=vref
RPC=131; ACTION=call; return
;;
131)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht231=\"\$F$((FP+NP+1))\""
eval "sht231=\"\$F$((FP+NP+2))\""
eval "sht226=\"\$F$((FP+NP+3))\""
eval "sht223=\"\$F$((FP+NP+4))\""
eval "sht220=\"\$F$((FP+NP+5))\""
eval "sht214=\"\$F$((FP+NP+6))\""
eval "sht211=\"\$F$((FP+NP+7))\""
sht233="${R}"
sht234="T:${sht233#??}${G_DQ#??}"
sht235="T:CALLEE=${sht234#??}"
sht236="T:${G_DQ#??}${sht235#??}"
sht237="T:set ${sht236#??}"
eval "F$((FP+NP+0))=\"\${sht231}\""
eval "F$((FP+NP+1))=\"\${sht226}\""
eval "F$((FP+NP+2))=\"\${sht223}\""
eval "F$((FP+NP+3))=\"\${sht220}\""
eval "F$((FP+NP+4))=\"\${sht214}\""
eval "F$((FP+NP+5))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht231}\""
eval "F$((NFP+1))=\"\${sht237}\""
CALLEE=emit
RPC=132; ACTION=call; return
;;
132)
eval "sht231=\"\$F$((FP+NP+0))\""
eval "sht226=\"\$F$((FP+NP+1))\""
eval "sht223=\"\$F$((FP+NP+2))\""
eval "sht220=\"\$F$((FP+NP+3))\""
eval "sht214=\"\$F$((FP+NP+4))\""
eval "sht211=\"\$F$((FP+NP+5))\""
sht238="${R}"
sht239="${sht238}"
hp_cdr "${sht220}"
sht240="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht239}\""
eval "F$((FP+NP+2))=\"\${sht239}\""
eval "F$((FP+NP+3))=\"\${sht231}\""
eval "F$((FP+NP+4))=\"\${sht226}\""
eval "F$((FP+NP+5))=\"\${sht223}\""
eval "F$((FP+NP+6))=\"\${sht220}\""
eval "F$((FP+NP+7))=\"\${sht214}\""
eval "F$((FP+NP+8))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht240}\""
CALLEE=vref
RPC=133; ACTION=call; return
;;
133)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht239=\"\$F$((FP+NP+1))\""
eval "sht239=\"\$F$((FP+NP+2))\""
eval "sht231=\"\$F$((FP+NP+3))\""
eval "sht226=\"\$F$((FP+NP+4))\""
eval "sht223=\"\$F$((FP+NP+5))\""
eval "sht220=\"\$F$((FP+NP+6))\""
eval "sht214=\"\$F$((FP+NP+7))\""
eval "sht211=\"\$F$((FP+NP+8))\""
sht241="${R}"
sht242="T:${sht241#??}${G_DQ#??}"
sht243="T:APLIST=${sht242#??}"
sht244="T:${G_DQ#??}${sht243#??}"
sht245="T:set ${sht244#??}"
eval "F$((FP+NP+0))=\"\${sht239}\""
eval "F$((FP+NP+1))=\"\${sht231}\""
eval "F$((FP+NP+2))=\"\${sht226}\""
eval "F$((FP+NP+3))=\"\${sht223}\""
eval "F$((FP+NP+4))=\"\${sht220}\""
eval "F$((FP+NP+5))=\"\${sht214}\""
eval "F$((FP+NP+6))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht239}\""
eval "F$((NFP+1))=\"\${sht245}\""
CALLEE=emit
RPC=134; ACTION=call; return
;;
134)
eval "sht239=\"\$F$((FP+NP+0))\""
eval "sht231=\"\$F$((FP+NP+1))\""
eval "sht226=\"\$F$((FP+NP+2))\""
eval "sht223=\"\$F$((FP+NP+3))\""
eval "sht220=\"\$F$((FP+NP+4))\""
eval "sht214=\"\$F$((FP+NP+5))\""
eval "sht211=\"\$F$((FP+NP+6))\""
sht246="${R}"
sht247="${sht246}"
sht248="T:${sht226#??}"
sht249="T:${sht248#??}${G_DQ#??}"
sht250="T:RPC=${sht249#??}"
sht251="T:${G_DQ#??}${sht250#??}"
sht252="T:set ${sht251#??}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht239}\""
eval "F$((FP+NP+2))=\"\${sht231}\""
eval "F$((FP+NP+3))=\"\${sht226}\""
eval "F$((FP+NP+4))=\"\${sht223}\""
eval "F$((FP+NP+5))=\"\${sht220}\""
eval "F$((FP+NP+6))=\"\${sht214}\""
eval "F$((FP+NP+7))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht247}\""
eval "F$((NFP+1))=\"\${sht252}\""
CALLEE=emit
RPC=135; ACTION=call; return
;;
135)
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht239=\"\$F$((FP+NP+1))\""
eval "sht231=\"\$F$((FP+NP+2))\""
eval "sht226=\"\$F$((FP+NP+3))\""
eval "sht223=\"\$F$((FP+NP+4))\""
eval "sht220=\"\$F$((FP+NP+5))\""
eval "sht214=\"\$F$((FP+NP+6))\""
eval "sht211=\"\$F$((FP+NP+7))\""
sht253="${R}"
sht254="${sht253}"
sht255="T:${G_DQ#??} & goto :eof"
sht256="T:ACTION=apply${sht255#??}"
sht257="T:${G_DQ#??}${sht256#??}"
sht258="T:set ${sht257#??}"
eval "F$((FP+NP+0))=\"\${sht254}\""
eval "F$((FP+NP+1))=\"\${sht247}\""
eval "F$((FP+NP+2))=\"\${sht239}\""
eval "F$((FP+NP+3))=\"\${sht231}\""
eval "F$((FP+NP+4))=\"\${sht226}\""
eval "F$((FP+NP+5))=\"\${sht223}\""
eval "F$((FP+NP+6))=\"\${sht220}\""
eval "F$((FP+NP+7))=\"\${sht214}\""
eval "F$((FP+NP+8))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht254}\""
eval "F$((NFP+1))=\"\${sht258}\""
CALLEE=emit
RPC=136; ACTION=call; return
;;
136)
eval "sht254=\"\$F$((FP+NP+0))\""
eval "sht247=\"\$F$((FP+NP+1))\""
eval "sht239=\"\$F$((FP+NP+2))\""
eval "sht231=\"\$F$((FP+NP+3))\""
eval "sht226=\"\$F$((FP+NP+4))\""
eval "sht223=\"\$F$((FP+NP+5))\""
eval "sht220=\"\$F$((FP+NP+6))\""
eval "sht214=\"\$F$((FP+NP+7))\""
eval "sht211=\"\$F$((FP+NP+8))\""
sht259="${R}"
sht260="${sht259}"
eval "F$((FP+NP+0))=\"\${sht260}\""
eval "F$((FP+NP+1))=\"\${sht254}\""
eval "F$((FP+NP+2))=\"\${sht247}\""
eval "F$((FP+NP+3))=\"\${sht239}\""
eval "F$((FP+NP+4))=\"\${sht231}\""
eval "F$((FP+NP+5))=\"\${sht226}\""
eval "F$((FP+NP+6))=\"\${sht223}\""
eval "F$((FP+NP+7))=\"\${sht220}\""
eval "F$((FP+NP+8))=\"\${sht214}\""
eval "F$((FP+NP+9))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht260}\""
eval "F$((NFP+1))=\"\${sht226}\""
CALLEE=switch
RPC=137; ACTION=call; return
;;
137)
eval "sht260=\"\$F$((FP+NP+0))\""
eval "sht254=\"\$F$((FP+NP+1))\""
eval "sht247=\"\$F$((FP+NP+2))\""
eval "sht239=\"\$F$((FP+NP+3))\""
eval "sht231=\"\$F$((FP+NP+4))\""
eval "sht226=\"\$F$((FP+NP+5))\""
eval "sht223=\"\$F$((FP+NP+6))\""
eval "sht220=\"\$F$((FP+NP+7))\""
eval "sht214=\"\$F$((FP+NP+8))\""
eval "sht211=\"\$F$((FP+NP+9))\""
sht261="${R}"
sht262="${sht261}"
eval "F$((FP+NP+0))=\"\${sht262}\""
eval "F$((FP+NP+1))=\"\${sht260}\""
eval "F$((FP+NP+2))=\"\${sht254}\""
eval "F$((FP+NP+3))=\"\${sht247}\""
eval "F$((FP+NP+4))=\"\${sht239}\""
eval "F$((FP+NP+5))=\"\${sht231}\""
eval "F$((FP+NP+6))=\"\${sht226}\""
eval "F$((FP+NP+7))=\"\${sht223}\""
eval "F$((FP+NP+8))=\"\${sht220}\""
eval "F$((FP+NP+9))=\"\${sht214}\""
eval "F$((FP+NP+10))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht262}\""
CALLEE=tmpn
RPC=138; ACTION=call; return
;;
138)
eval "sht262=\"\$F$((FP+NP+0))\""
eval "sht260=\"\$F$((FP+NP+1))\""
eval "sht254=\"\$F$((FP+NP+2))\""
eval "sht247=\"\$F$((FP+NP+3))\""
eval "sht239=\"\$F$((FP+NP+4))\""
eval "sht231=\"\$F$((FP+NP+5))\""
eval "sht226=\"\$F$((FP+NP+6))\""
eval "sht223=\"\$F$((FP+NP+7))\""
eval "sht220=\"\$F$((FP+NP+8))\""
eval "sht214=\"\$F$((FP+NP+9))\""
eval "sht211=\"\$F$((FP+NP+10))\""
sht263="${R}"
sht264="${sht263}"
eval "F$((FP+NP+0))=\"\${sht264}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht254}\""
eval "F$((FP+NP+4))=\"\${sht247}\""
eval "F$((FP+NP+5))=\"\${sht239}\""
eval "F$((FP+NP+6))=\"\${sht231}\""
eval "F$((FP+NP+7))=\"\${sht226}\""
eval "F$((FP+NP+8))=\"\${sht223}\""
eval "F$((FP+NP+9))=\"\${sht220}\""
eval "F$((FP+NP+10))=\"\${sht214}\""
eval "F$((FP+NP+11))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht262}\""
eval "F$((NFP+1))=\"\${sht223}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=139; ACTION=call; return
;;
139)
eval "sht264=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht254=\"\$F$((FP+NP+3))\""
eval "sht247=\"\$F$((FP+NP+4))\""
eval "sht239=\"\$F$((FP+NP+5))\""
eval "sht231=\"\$F$((FP+NP+6))\""
eval "sht226=\"\$F$((FP+NP+7))\""
eval "sht223=\"\$F$((FP+NP+8))\""
eval "sht220=\"\$F$((FP+NP+9))\""
eval "sht214=\"\$F$((FP+NP+10))\""
eval "sht211=\"\$F$((FP+NP+11))\""
sht265="${R}"
sht266="T:${sht264#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht265}\""
eval "F$((FP+NP+1))=\"\${sht264}\""
eval "F$((FP+NP+2))=\"\${sht262}\""
eval "F$((FP+NP+3))=\"\${sht260}\""
eval "F$((FP+NP+4))=\"\${sht254}\""
eval "F$((FP+NP+5))=\"\${sht247}\""
eval "F$((FP+NP+6))=\"\${sht239}\""
eval "F$((FP+NP+7))=\"\${sht231}\""
eval "F$((FP+NP+8))=\"\${sht226}\""
eval "F$((FP+NP+9))=\"\${sht223}\""
eval "F$((FP+NP+10))=\"\${sht220}\""
eval "F$((FP+NP+11))=\"\${sht214}\""
eval "F$((FP+NP+12))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht266}\""
CALLEE=qset
RPC=140; ACTION=call; return
;;
140)
eval "sht265=\"\$F$((FP+NP+0))\""
eval "sht264=\"\$F$((FP+NP+1))\""
eval "sht262=\"\$F$((FP+NP+2))\""
eval "sht260=\"\$F$((FP+NP+3))\""
eval "sht254=\"\$F$((FP+NP+4))\""
eval "sht247=\"\$F$((FP+NP+5))\""
eval "sht239=\"\$F$((FP+NP+6))\""
eval "sht231=\"\$F$((FP+NP+7))\""
eval "sht226=\"\$F$((FP+NP+8))\""
eval "sht223=\"\$F$((FP+NP+9))\""
eval "sht220=\"\$F$((FP+NP+10))\""
eval "sht214=\"\$F$((FP+NP+11))\""
eval "sht211=\"\$F$((FP+NP+12))\""
sht267="${R}"
eval "F$((FP+NP+0))=\"\${sht264}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht254}\""
eval "F$((FP+NP+4))=\"\${sht247}\""
eval "F$((FP+NP+5))=\"\${sht239}\""
eval "F$((FP+NP+6))=\"\${sht231}\""
eval "F$((FP+NP+7))=\"\${sht226}\""
eval "F$((FP+NP+8))=\"\${sht223}\""
eval "F$((FP+NP+9))=\"\${sht220}\""
eval "F$((FP+NP+10))=\"\${sht214}\""
eval "F$((FP+NP+11))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht265}\""
eval "F$((NFP+1))=\"\${sht267}\""
CALLEE=emit
RPC=141; ACTION=call; return
;;
141)
eval "sht264=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht254=\"\$F$((FP+NP+3))\""
eval "sht247=\"\$F$((FP+NP+4))\""
eval "sht239=\"\$F$((FP+NP+5))\""
eval "sht231=\"\$F$((FP+NP+6))\""
eval "sht226=\"\$F$((FP+NP+7))\""
eval "sht223=\"\$F$((FP+NP+8))\""
eval "sht220=\"\$F$((FP+NP+9))\""
eval "sht214=\"\$F$((FP+NP+10))\""
eval "sht211=\"\$F$((FP+NP+11))\""
sht268="${R}"
eval "F$((FP+NP+0))=\"\${sht268}\""
eval "F$((FP+NP+1))=\"\${sht264}\""
eval "F$((FP+NP+2))=\"\${sht262}\""
eval "F$((FP+NP+3))=\"\${sht260}\""
eval "F$((FP+NP+4))=\"\${sht254}\""
eval "F$((FP+NP+5))=\"\${sht247}\""
eval "F$((FP+NP+6))=\"\${sht239}\""
eval "F$((FP+NP+7))=\"\${sht231}\""
eval "F$((FP+NP+8))=\"\${sht226}\""
eval "F$((FP+NP+9))=\"\${sht223}\""
eval "F$((FP+NP+10))=\"\${sht220}\""
eval "F$((FP+NP+11))=\"\${sht214}\""
eval "F$((FP+NP+12))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht223}\""
CALLEE=lenl
RPC=142; ACTION=call; return
;;
142)
eval "sht268=\"\$F$((FP+NP+0))\""
eval "sht264=\"\$F$((FP+NP+1))\""
eval "sht262=\"\$F$((FP+NP+2))\""
eval "sht260=\"\$F$((FP+NP+3))\""
eval "sht254=\"\$F$((FP+NP+4))\""
eval "sht247=\"\$F$((FP+NP+5))\""
eval "sht239=\"\$F$((FP+NP+6))\""
eval "sht231=\"\$F$((FP+NP+7))\""
eval "sht226=\"\$F$((FP+NP+8))\""
eval "sht223=\"\$F$((FP+NP+9))\""
eval "sht220=\"\$F$((FP+NP+10))\""
eval "sht214=\"\$F$((FP+NP+11))\""
eval "sht211=\"\$F$((FP+NP+12))\""
sht269="${R}"
eval "F$((FP+NP+0))=\"\${sht264}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht254}\""
eval "F$((FP+NP+4))=\"\${sht247}\""
eval "F$((FP+NP+5))=\"\${sht239}\""
eval "F$((FP+NP+6))=\"\${sht231}\""
eval "F$((FP+NP+7))=\"\${sht226}\""
eval "F$((FP+NP+8))=\"\${sht223}\""
eval "F$((FP+NP+9))=\"\${sht220}\""
eval "F$((FP+NP+10))=\"\${sht214}\""
eval "F$((FP+NP+11))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht268}\""
eval "F$((NFP+1))=\"\${sht269}\""
CALLEE=bsm
RPC=143; ACTION=call; return
;;
143)
eval "sht264=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht254=\"\$F$((FP+NP+3))\""
eval "sht247=\"\$F$((FP+NP+4))\""
eval "sht239=\"\$F$((FP+NP+5))\""
eval "sht231=\"\$F$((FP+NP+6))\""
eval "sht226=\"\$F$((FP+NP+7))\""
eval "sht223=\"\$F$((FP+NP+8))\""
eval "sht220=\"\$F$((FP+NP+9))\""
eval "sht214=\"\$F$((FP+NP+10))\""
eval "sht211=\"\$F$((FP+NP+11))\""
sht270="${R}"
eval "F$((FP+NP+0))=\"\${sht264}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht254}\""
eval "F$((FP+NP+4))=\"\${sht247}\""
eval "F$((FP+NP+5))=\"\${sht239}\""
eval "F$((FP+NP+6))=\"\${sht231}\""
eval "F$((FP+NP+7))=\"\${sht226}\""
eval "F$((FP+NP+8))=\"\${sht223}\""
eval "F$((FP+NP+9))=\"\${sht220}\""
eval "F$((FP+NP+10))=\"\${sht214}\""
eval "F$((FP+NP+11))=\"\${sht211}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht270}\""
CALLEE=bkzzP
RPC=144; ACTION=call; return
;;
144)
eval "sht264=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht254=\"\$F$((FP+NP+3))\""
eval "sht247=\"\$F$((FP+NP+4))\""
eval "sht239=\"\$F$((FP+NP+5))\""
eval "sht231=\"\$F$((FP+NP+6))\""
eval "sht226=\"\$F$((FP+NP+7))\""
eval "sht223=\"\$F$((FP+NP+8))\""
eval "sht220=\"\$F$((FP+NP+9))\""
eval "sht214=\"\$F$((FP+NP+10))\""
eval "sht211=\"\$F$((FP+NP+11))\""
sht271="${R}"
eval "F$((FP+NP+0))=\"\${sht271}\""
eval "F$((FP+NP+1))=\"\${sht264}\""
eval "F$((FP+NP+2))=\"\${sht262}\""
eval "F$((FP+NP+3))=\"\${sht260}\""
eval "F$((FP+NP+4))=\"\${sht254}\""
eval "F$((FP+NP+5))=\"\${sht247}\""
eval "F$((FP+NP+6))=\"\${sht239}\""
eval "F$((FP+NP+7))=\"\${sht231}\""
eval "F$((FP+NP+8))=\"\${sht226}\""
eval "F$((FP+NP+9))=\"\${sht223}\""
eval "F$((FP+NP+10))=\"\${sht220}\""
eval "F$((FP+NP+11))=\"\${sht214}\""
eval "F$((FP+NP+12))=\"\${sht211}\""
hp_cons "S:val" "${sht264}"
eval "sht271=\"\$F$((FP+NP+0))\""
eval "sht264=\"\$F$((FP+NP+1))\""
eval "sht262=\"\$F$((FP+NP+2))\""
eval "sht260=\"\$F$((FP+NP+3))\""
eval "sht254=\"\$F$((FP+NP+4))\""
eval "sht247=\"\$F$((FP+NP+5))\""
eval "sht239=\"\$F$((FP+NP+6))\""
eval "sht231=\"\$F$((FP+NP+7))\""
eval "sht226=\"\$F$((FP+NP+8))\""
eval "sht223=\"\$F$((FP+NP+9))\""
eval "sht220=\"\$F$((FP+NP+10))\""
eval "sht214=\"\$F$((FP+NP+11))\""
eval "sht211=\"\$F$((FP+NP+12))\""
sht272="${R}"
eval "F$((FP+NP+0))=\"\${sht264}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht254}\""
eval "F$((FP+NP+4))=\"\${sht247}\""
eval "F$((FP+NP+5))=\"\${sht239}\""
eval "F$((FP+NP+6))=\"\${sht231}\""
eval "F$((FP+NP+7))=\"\${sht226}\""
eval "F$((FP+NP+8))=\"\${sht223}\""
eval "F$((FP+NP+9))=\"\${sht220}\""
eval "F$((FP+NP+10))=\"\${sht214}\""
eval "F$((FP+NP+11))=\"\${sht211}\""
hp_cons "${sht271}" "${sht272}"
eval "sht264=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht254=\"\$F$((FP+NP+3))\""
eval "sht247=\"\$F$((FP+NP+4))\""
eval "sht239=\"\$F$((FP+NP+5))\""
eval "sht231=\"\$F$((FP+NP+6))\""
eval "sht226=\"\$F$((FP+NP+7))\""
eval "sht223=\"\$F$((FP+NP+8))\""
eval "sht220=\"\$F$((FP+NP+9))\""
eval "sht214=\"\$F$((FP+NP+10))\""
eval "sht211=\"\$F$((FP+NP+11))\""
sht273="${R}"
R="${sht273}"; ACTION=ret; return
;;
145)
hp_car "${p0}"
sht276="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht276}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=148; ACTION=call; return
;;
146)
sht275="NIL"
PC=147; ACTION=jump; return
;;
147)
if [ "${sht275}" != NIL ]; then PC=149; else PC=150; fi
ACTION=jump; return
;;
148)
sht277="${R}"
if [ "${sht277}" = NIL ]; then
sht278="S:t"
else
sht278="NIL"
fi
sht275="${sht278}"
PC=147; ACTION=jump; return
;;
149)
hp_cdr "${p0}"
sht279="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht279}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=151; ACTION=call; return
;;
150)
hp_car "${p0}"
sht329="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht329}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=169; ACTION=call; return
;;
151)
sht280="${R}"
sht281="${sht280}"
hp_car "${sht281}"
sht282="${R}"
eval "F$((FP+NP+0))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht282}\""
CALLEE=b_npc
RPC=152; ACTION=call; return
;;
152)
eval "sht281=\"\$F$((FP+NP+0))\""
sht283="${R}"
sht284="${sht283}"
hp_car "${p0}"
sht285="${R}"
sht286="T:${sht285#??}"
eval "F$((FP+NP+0))=\"\${sht284}\""
eval "F$((FP+NP+1))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht286}\""
CALLEE=mangle
RPC=153; ACTION=call; return
;;
153)
eval "sht284=\"\$F$((FP+NP+0))\""
eval "sht281=\"\$F$((FP+NP+1))\""
sht287="${R}"
sht288="${sht287}"
hp_car "${sht281}"
sht289="${R}"
eval "F$((FP+NP+0))=\"\${sht288}\""
eval "F$((FP+NP+1))=\"\${sht284}\""
eval "F$((FP+NP+2))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht289}\""
CALLEE=bnpczzP
RPC=154; ACTION=call; return
;;
154)
eval "sht288=\"\$F$((FP+NP+0))\""
eval "sht284=\"\$F$((FP+NP+1))\""
eval "sht281=\"\$F$((FP+NP+2))\""
sht290="${R}"
eval "F$((FP+NP+0))=\"\${sht288}\""
eval "F$((FP+NP+1))=\"\${sht284}\""
eval "F$((FP+NP+2))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht290}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=155; ACTION=call; return
;;
155)
eval "sht288=\"\$F$((FP+NP+0))\""
eval "sht284=\"\$F$((FP+NP+1))\""
eval "sht281=\"\$F$((FP+NP+2))\""
sht291="${R}"
eval "F$((FP+NP+0))=\"\${sht288}\""
eval "F$((FP+NP+1))=\"\${sht284}\""
eval "F$((FP+NP+2))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht291}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=156; ACTION=call; return
;;
156)
eval "sht288=\"\$F$((FP+NP+0))\""
eval "sht284=\"\$F$((FP+NP+1))\""
eval "sht281=\"\$F$((FP+NP+2))\""
sht292="${R}"
sht293="${sht292}"
hp_cdr "${sht281}"
sht294="${R}"
eval "F$((FP+NP+0))=\"\${sht293}\""
eval "F$((FP+NP+1))=\"\${sht288}\""
eval "F$((FP+NP+2))=\"\${sht284}\""
eval "F$((FP+NP+3))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht293}\""
eval "F$((NFP+1))=\"\${sht294}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=157; ACTION=call; return
;;
157)
eval "sht293=\"\$F$((FP+NP+0))\""
eval "sht288=\"\$F$((FP+NP+1))\""
eval "sht284=\"\$F$((FP+NP+2))\""
eval "sht281=\"\$F$((FP+NP+3))\""
sht295="${R}"
sht296="${sht295}"
sht297="T:${sht288#??}${G_DQ#??}"
sht298="T:CALLEE=${sht297#??}"
sht299="T:${G_DQ#??}${sht298#??}"
sht300="T:set ${sht299#??}"
eval "F$((FP+NP+0))=\"\${sht296}\""
eval "F$((FP+NP+1))=\"\${sht293}\""
eval "F$((FP+NP+2))=\"\${sht288}\""
eval "F$((FP+NP+3))=\"\${sht284}\""
eval "F$((FP+NP+4))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht296}\""
eval "F$((NFP+1))=\"\${sht300}\""
CALLEE=emit
RPC=158; ACTION=call; return
;;
158)
eval "sht296=\"\$F$((FP+NP+0))\""
eval "sht293=\"\$F$((FP+NP+1))\""
eval "sht288=\"\$F$((FP+NP+2))\""
eval "sht284=\"\$F$((FP+NP+3))\""
eval "sht281=\"\$F$((FP+NP+4))\""
sht301="${R}"
sht302="${sht301}"
sht303="T:${sht284#??}"
sht304="T:${sht303#??}${G_DQ#??}"
sht305="T:RPC=${sht304#??}"
sht306="T:${G_DQ#??}${sht305#??}"
sht307="T:set ${sht306#??}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${sht296}\""
eval "F$((FP+NP+2))=\"\${sht293}\""
eval "F$((FP+NP+3))=\"\${sht288}\""
eval "F$((FP+NP+4))=\"\${sht284}\""
eval "F$((FP+NP+5))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht302}\""
eval "F$((NFP+1))=\"\${sht307}\""
CALLEE=emit
RPC=159; ACTION=call; return
;;
159)
eval "sht302=\"\$F$((FP+NP+0))\""
eval "sht296=\"\$F$((FP+NP+1))\""
eval "sht293=\"\$F$((FP+NP+2))\""
eval "sht288=\"\$F$((FP+NP+3))\""
eval "sht284=\"\$F$((FP+NP+4))\""
eval "sht281=\"\$F$((FP+NP+5))\""
sht308="${R}"
sht309="${sht308}"
sht310="T:${G_DQ#??} & goto :eof"
sht311="T:ACTION=call${sht310#??}"
sht312="T:${G_DQ#??}${sht311#??}"
sht313="T:set ${sht312#??}"
eval "F$((FP+NP+0))=\"\${sht309}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht296}\""
eval "F$((FP+NP+3))=\"\${sht293}\""
eval "F$((FP+NP+4))=\"\${sht288}\""
eval "F$((FP+NP+5))=\"\${sht284}\""
eval "F$((FP+NP+6))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht309}\""
eval "F$((NFP+1))=\"\${sht313}\""
CALLEE=emit
RPC=160; ACTION=call; return
;;
160)
eval "sht309=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht296=\"\$F$((FP+NP+2))\""
eval "sht293=\"\$F$((FP+NP+3))\""
eval "sht288=\"\$F$((FP+NP+4))\""
eval "sht284=\"\$F$((FP+NP+5))\""
eval "sht281=\"\$F$((FP+NP+6))\""
sht314="${R}"
sht315="${sht314}"
eval "F$((FP+NP+0))=\"\${sht315}\""
eval "F$((FP+NP+1))=\"\${sht309}\""
eval "F$((FP+NP+2))=\"\${sht302}\""
eval "F$((FP+NP+3))=\"\${sht296}\""
eval "F$((FP+NP+4))=\"\${sht293}\""
eval "F$((FP+NP+5))=\"\${sht288}\""
eval "F$((FP+NP+6))=\"\${sht284}\""
eval "F$((FP+NP+7))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht315}\""
eval "F$((NFP+1))=\"\${sht284}\""
CALLEE=switch
RPC=161; ACTION=call; return
;;
161)
eval "sht315=\"\$F$((FP+NP+0))\""
eval "sht309=\"\$F$((FP+NP+1))\""
eval "sht302=\"\$F$((FP+NP+2))\""
eval "sht296=\"\$F$((FP+NP+3))\""
eval "sht293=\"\$F$((FP+NP+4))\""
eval "sht288=\"\$F$((FP+NP+5))\""
eval "sht284=\"\$F$((FP+NP+6))\""
eval "sht281=\"\$F$((FP+NP+7))\""
sht316="${R}"
sht317="${sht316}"
eval "F$((FP+NP+0))=\"\${sht317}\""
eval "F$((FP+NP+1))=\"\${sht315}\""
eval "F$((FP+NP+2))=\"\${sht309}\""
eval "F$((FP+NP+3))=\"\${sht302}\""
eval "F$((FP+NP+4))=\"\${sht296}\""
eval "F$((FP+NP+5))=\"\${sht293}\""
eval "F$((FP+NP+6))=\"\${sht288}\""
eval "F$((FP+NP+7))=\"\${sht284}\""
eval "F$((FP+NP+8))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht317}\""
CALLEE=tmpn
RPC=162; ACTION=call; return
;;
162)
eval "sht317=\"\$F$((FP+NP+0))\""
eval "sht315=\"\$F$((FP+NP+1))\""
eval "sht309=\"\$F$((FP+NP+2))\""
eval "sht302=\"\$F$((FP+NP+3))\""
eval "sht296=\"\$F$((FP+NP+4))\""
eval "sht293=\"\$F$((FP+NP+5))\""
eval "sht288=\"\$F$((FP+NP+6))\""
eval "sht284=\"\$F$((FP+NP+7))\""
eval "sht281=\"\$F$((FP+NP+8))\""
sht318="${R}"
sht319="${sht318}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht317}\""
eval "F$((FP+NP+2))=\"\${sht315}\""
eval "F$((FP+NP+3))=\"\${sht309}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht296}\""
eval "F$((FP+NP+6))=\"\${sht293}\""
eval "F$((FP+NP+7))=\"\${sht288}\""
eval "F$((FP+NP+8))=\"\${sht284}\""
eval "F$((FP+NP+9))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht317}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=163; ACTION=call; return
;;
163)
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht317=\"\$F$((FP+NP+1))\""
eval "sht315=\"\$F$((FP+NP+2))\""
eval "sht309=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht296=\"\$F$((FP+NP+5))\""
eval "sht293=\"\$F$((FP+NP+6))\""
eval "sht288=\"\$F$((FP+NP+7))\""
eval "sht284=\"\$F$((FP+NP+8))\""
eval "sht281=\"\$F$((FP+NP+9))\""
sht320="${R}"
sht321="T:${sht319#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht320}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht317}\""
eval "F$((FP+NP+3))=\"\${sht315}\""
eval "F$((FP+NP+4))=\"\${sht309}\""
eval "F$((FP+NP+5))=\"\${sht302}\""
eval "F$((FP+NP+6))=\"\${sht296}\""
eval "F$((FP+NP+7))=\"\${sht293}\""
eval "F$((FP+NP+8))=\"\${sht288}\""
eval "F$((FP+NP+9))=\"\${sht284}\""
eval "F$((FP+NP+10))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht321}\""
CALLEE=qset
RPC=164; ACTION=call; return
;;
164)
eval "sht320=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht317=\"\$F$((FP+NP+2))\""
eval "sht315=\"\$F$((FP+NP+3))\""
eval "sht309=\"\$F$((FP+NP+4))\""
eval "sht302=\"\$F$((FP+NP+5))\""
eval "sht296=\"\$F$((FP+NP+6))\""
eval "sht293=\"\$F$((FP+NP+7))\""
eval "sht288=\"\$F$((FP+NP+8))\""
eval "sht284=\"\$F$((FP+NP+9))\""
eval "sht281=\"\$F$((FP+NP+10))\""
sht322="${R}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht317}\""
eval "F$((FP+NP+2))=\"\${sht315}\""
eval "F$((FP+NP+3))=\"\${sht309}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht296}\""
eval "F$((FP+NP+6))=\"\${sht293}\""
eval "F$((FP+NP+7))=\"\${sht288}\""
eval "F$((FP+NP+8))=\"\${sht284}\""
eval "F$((FP+NP+9))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht320}\""
eval "F$((NFP+1))=\"\${sht322}\""
CALLEE=emit
RPC=165; ACTION=call; return
;;
165)
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht317=\"\$F$((FP+NP+1))\""
eval "sht315=\"\$F$((FP+NP+2))\""
eval "sht309=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht296=\"\$F$((FP+NP+5))\""
eval "sht293=\"\$F$((FP+NP+6))\""
eval "sht288=\"\$F$((FP+NP+7))\""
eval "sht284=\"\$F$((FP+NP+8))\""
eval "sht281=\"\$F$((FP+NP+9))\""
sht323="${R}"
eval "F$((FP+NP+0))=\"\${sht323}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht317}\""
eval "F$((FP+NP+3))=\"\${sht315}\""
eval "F$((FP+NP+4))=\"\${sht309}\""
eval "F$((FP+NP+5))=\"\${sht302}\""
eval "F$((FP+NP+6))=\"\${sht296}\""
eval "F$((FP+NP+7))=\"\${sht293}\""
eval "F$((FP+NP+8))=\"\${sht288}\""
eval "F$((FP+NP+9))=\"\${sht284}\""
eval "F$((FP+NP+10))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=166; ACTION=call; return
;;
166)
eval "sht323=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht317=\"\$F$((FP+NP+2))\""
eval "sht315=\"\$F$((FP+NP+3))\""
eval "sht309=\"\$F$((FP+NP+4))\""
eval "sht302=\"\$F$((FP+NP+5))\""
eval "sht296=\"\$F$((FP+NP+6))\""
eval "sht293=\"\$F$((FP+NP+7))\""
eval "sht288=\"\$F$((FP+NP+8))\""
eval "sht284=\"\$F$((FP+NP+9))\""
eval "sht281=\"\$F$((FP+NP+10))\""
sht324="${R}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht317}\""
eval "F$((FP+NP+2))=\"\${sht315}\""
eval "F$((FP+NP+3))=\"\${sht309}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht296}\""
eval "F$((FP+NP+6))=\"\${sht293}\""
eval "F$((FP+NP+7))=\"\${sht288}\""
eval "F$((FP+NP+8))=\"\${sht284}\""
eval "F$((FP+NP+9))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht323}\""
eval "F$((NFP+1))=\"\${sht324}\""
CALLEE=bsm
RPC=167; ACTION=call; return
;;
167)
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht317=\"\$F$((FP+NP+1))\""
eval "sht315=\"\$F$((FP+NP+2))\""
eval "sht309=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht296=\"\$F$((FP+NP+5))\""
eval "sht293=\"\$F$((FP+NP+6))\""
eval "sht288=\"\$F$((FP+NP+7))\""
eval "sht284=\"\$F$((FP+NP+8))\""
eval "sht281=\"\$F$((FP+NP+9))\""
sht325="${R}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht317}\""
eval "F$((FP+NP+2))=\"\${sht315}\""
eval "F$((FP+NP+3))=\"\${sht309}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht296}\""
eval "F$((FP+NP+6))=\"\${sht293}\""
eval "F$((FP+NP+7))=\"\${sht288}\""
eval "F$((FP+NP+8))=\"\${sht284}\""
eval "F$((FP+NP+9))=\"\${sht281}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht325}\""
CALLEE=bkzzP
RPC=168; ACTION=call; return
;;
168)
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht317=\"\$F$((FP+NP+1))\""
eval "sht315=\"\$F$((FP+NP+2))\""
eval "sht309=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht296=\"\$F$((FP+NP+5))\""
eval "sht293=\"\$F$((FP+NP+6))\""
eval "sht288=\"\$F$((FP+NP+7))\""
eval "sht284=\"\$F$((FP+NP+8))\""
eval "sht281=\"\$F$((FP+NP+9))\""
sht326="${R}"
eval "F$((FP+NP+0))=\"\${sht326}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht317}\""
eval "F$((FP+NP+3))=\"\${sht315}\""
eval "F$((FP+NP+4))=\"\${sht309}\""
eval "F$((FP+NP+5))=\"\${sht302}\""
eval "F$((FP+NP+6))=\"\${sht296}\""
eval "F$((FP+NP+7))=\"\${sht293}\""
eval "F$((FP+NP+8))=\"\${sht288}\""
eval "F$((FP+NP+9))=\"\${sht284}\""
eval "F$((FP+NP+10))=\"\${sht281}\""
hp_cons "S:val" "${sht319}"
eval "sht326=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht317=\"\$F$((FP+NP+2))\""
eval "sht315=\"\$F$((FP+NP+3))\""
eval "sht309=\"\$F$((FP+NP+4))\""
eval "sht302=\"\$F$((FP+NP+5))\""
eval "sht296=\"\$F$((FP+NP+6))\""
eval "sht293=\"\$F$((FP+NP+7))\""
eval "sht288=\"\$F$((FP+NP+8))\""
eval "sht284=\"\$F$((FP+NP+9))\""
eval "sht281=\"\$F$((FP+NP+10))\""
sht327="${R}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht317}\""
eval "F$((FP+NP+2))=\"\${sht315}\""
eval "F$((FP+NP+3))=\"\${sht309}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht296}\""
eval "F$((FP+NP+6))=\"\${sht293}\""
eval "F$((FP+NP+7))=\"\${sht288}\""
eval "F$((FP+NP+8))=\"\${sht284}\""
eval "F$((FP+NP+9))=\"\${sht281}\""
hp_cons "${sht326}" "${sht327}"
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht317=\"\$F$((FP+NP+1))\""
eval "sht315=\"\$F$((FP+NP+2))\""
eval "sht309=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht296=\"\$F$((FP+NP+5))\""
eval "sht293=\"\$F$((FP+NP+6))\""
eval "sht288=\"\$F$((FP+NP+7))\""
eval "sht284=\"\$F$((FP+NP+8))\""
eval "sht281=\"\$F$((FP+NP+9))\""
sht328="${R}"
R="${sht328}"; ACTION=ret; return
;;
169)
sht330="${R}"
sht331="${sht330}"
hp_cdr "${sht331}"
sht332="${R}"
hp_cdr "${sht332}"
sht333="${R}"
sht334="${sht333}"
hp_cdr "${sht331}"
sht335="${R}"
eval "F$((FP+NP+0))=\"\${sht334}\""
eval "F$((FP+NP+1))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht335}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=170; ACTION=call; return
;;
170)
eval "sht334=\"\$F$((FP+NP+0))\""
eval "sht331=\"\$F$((FP+NP+1))\""
sht336="${R}"
sht337="${sht336}"
hp_cdr "${p0}"
sht338="${R}"
hp_car "${sht331}"
sht339="${R}"
eval "F$((FP+NP+0))=\"\${sht337}\""
eval "F$((FP+NP+1))=\"\${sht334}\""
eval "F$((FP+NP+2))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht338}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht339}\""
eval "F$((NFP+3))=\"\${sht337}\""
CALLEE=largs
RPC=171; ACTION=call; return
;;
171)
eval "sht337=\"\$F$((FP+NP+0))\""
eval "sht334=\"\$F$((FP+NP+1))\""
eval "sht331=\"\$F$((FP+NP+2))\""
sht340="${R}"
sht341="${sht340}"
hp_car "${sht341}"
sht342="${R}"
eval "F$((FP+NP+0))=\"\${sht341}\""
eval "F$((FP+NP+1))=\"\${sht337}\""
eval "F$((FP+NP+2))=\"\${sht334}\""
eval "F$((FP+NP+3))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht342}\""
CALLEE=b_npc
RPC=172; ACTION=call; return
;;
172)
eval "sht341=\"\$F$((FP+NP+0))\""
eval "sht337=\"\$F$((FP+NP+1))\""
eval "sht334=\"\$F$((FP+NP+2))\""
eval "sht331=\"\$F$((FP+NP+3))\""
sht343="${R}"
sht344="${sht343}"
hp_car "${sht341}"
sht345="${R}"
eval "F$((FP+NP+0))=\"\${sht344}\""
eval "F$((FP+NP+1))=\"\${sht341}\""
eval "F$((FP+NP+2))=\"\${sht337}\""
eval "F$((FP+NP+3))=\"\${sht334}\""
eval "F$((FP+NP+4))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht345}\""
CALLEE=bnpczzP
RPC=173; ACTION=call; return
;;
173)
eval "sht344=\"\$F$((FP+NP+0))\""
eval "sht341=\"\$F$((FP+NP+1))\""
eval "sht337=\"\$F$((FP+NP+2))\""
eval "sht334=\"\$F$((FP+NP+3))\""
eval "sht331=\"\$F$((FP+NP+4))\""
sht346="${R}"
eval "F$((FP+NP+0))=\"\${sht344}\""
eval "F$((FP+NP+1))=\"\${sht341}\""
eval "F$((FP+NP+2))=\"\${sht337}\""
eval "F$((FP+NP+3))=\"\${sht334}\""
eval "F$((FP+NP+4))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht346}\""
eval "F$((NFP+1))=\"\${sht337}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=174; ACTION=call; return
;;
174)
eval "sht344=\"\$F$((FP+NP+0))\""
eval "sht341=\"\$F$((FP+NP+1))\""
eval "sht337=\"\$F$((FP+NP+2))\""
eval "sht334=\"\$F$((FP+NP+3))\""
eval "sht331=\"\$F$((FP+NP+4))\""
sht347="${R}"
eval "F$((FP+NP+0))=\"\${sht344}\""
eval "F$((FP+NP+1))=\"\${sht341}\""
eval "F$((FP+NP+2))=\"\${sht337}\""
eval "F$((FP+NP+3))=\"\${sht334}\""
eval "F$((FP+NP+4))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht347}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=175; ACTION=call; return
;;
175)
eval "sht344=\"\$F$((FP+NP+0))\""
eval "sht341=\"\$F$((FP+NP+1))\""
eval "sht337=\"\$F$((FP+NP+2))\""
eval "sht334=\"\$F$((FP+NP+3))\""
eval "sht331=\"\$F$((FP+NP+4))\""
sht348="${R}"
sht349="${sht348}"
hp_cdr "${sht341}"
sht350="${R}"
eval "F$((FP+NP+0))=\"\${sht349}\""
eval "F$((FP+NP+1))=\"\${sht344}\""
eval "F$((FP+NP+2))=\"\${sht341}\""
eval "F$((FP+NP+3))=\"\${sht337}\""
eval "F$((FP+NP+4))=\"\${sht334}\""
eval "F$((FP+NP+5))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht349}\""
eval "F$((NFP+1))=\"\${sht350}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=176; ACTION=call; return
;;
176)
eval "sht349=\"\$F$((FP+NP+0))\""
eval "sht344=\"\$F$((FP+NP+1))\""
eval "sht341=\"\$F$((FP+NP+2))\""
eval "sht337=\"\$F$((FP+NP+3))\""
eval "sht334=\"\$F$((FP+NP+4))\""
eval "sht331=\"\$F$((FP+NP+5))\""
sht351="${R}"
sht352="${sht351}"
sht353="T:!${G_DQ#??}"
sht354="T:${sht334#??}${sht353#??}"
sht355="T:CALLEE=!${sht354#??}"
sht356="T:${G_DQ#??}${sht355#??}"
sht357="T:set ${sht356#??}"
eval "F$((FP+NP+0))=\"\${sht352}\""
eval "F$((FP+NP+1))=\"\${sht349}\""
eval "F$((FP+NP+2))=\"\${sht344}\""
eval "F$((FP+NP+3))=\"\${sht341}\""
eval "F$((FP+NP+4))=\"\${sht337}\""
eval "F$((FP+NP+5))=\"\${sht334}\""
eval "F$((FP+NP+6))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht352}\""
eval "F$((NFP+1))=\"\${sht357}\""
CALLEE=emit
RPC=177; ACTION=call; return
;;
177)
eval "sht352=\"\$F$((FP+NP+0))\""
eval "sht349=\"\$F$((FP+NP+1))\""
eval "sht344=\"\$F$((FP+NP+2))\""
eval "sht341=\"\$F$((FP+NP+3))\""
eval "sht337=\"\$F$((FP+NP+4))\""
eval "sht334=\"\$F$((FP+NP+5))\""
eval "sht331=\"\$F$((FP+NP+6))\""
sht358="${R}"
sht359="${sht358}"
sht360="T:${sht344#??}"
sht361="T:${sht360#??}${G_DQ#??}"
sht362="T:RPC=${sht361#??}"
sht363="T:${G_DQ#??}${sht362#??}"
sht364="T:set ${sht363#??}"
eval "F$((FP+NP+0))=\"\${sht359}\""
eval "F$((FP+NP+1))=\"\${sht352}\""
eval "F$((FP+NP+2))=\"\${sht349}\""
eval "F$((FP+NP+3))=\"\${sht344}\""
eval "F$((FP+NP+4))=\"\${sht341}\""
eval "F$((FP+NP+5))=\"\${sht337}\""
eval "F$((FP+NP+6))=\"\${sht334}\""
eval "F$((FP+NP+7))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht359}\""
eval "F$((NFP+1))=\"\${sht364}\""
CALLEE=emit
RPC=178; ACTION=call; return
;;
178)
eval "sht359=\"\$F$((FP+NP+0))\""
eval "sht352=\"\$F$((FP+NP+1))\""
eval "sht349=\"\$F$((FP+NP+2))\""
eval "sht344=\"\$F$((FP+NP+3))\""
eval "sht341=\"\$F$((FP+NP+4))\""
eval "sht337=\"\$F$((FP+NP+5))\""
eval "sht334=\"\$F$((FP+NP+6))\""
eval "sht331=\"\$F$((FP+NP+7))\""
sht365="${R}"
sht366="${sht365}"
sht367="T:${G_DQ#??} & goto :eof"
sht368="T:ACTION=call${sht367#??}"
sht369="T:${G_DQ#??}${sht368#??}"
sht370="T:set ${sht369#??}"
eval "F$((FP+NP+0))=\"\${sht366}\""
eval "F$((FP+NP+1))=\"\${sht359}\""
eval "F$((FP+NP+2))=\"\${sht352}\""
eval "F$((FP+NP+3))=\"\${sht349}\""
eval "F$((FP+NP+4))=\"\${sht344}\""
eval "F$((FP+NP+5))=\"\${sht341}\""
eval "F$((FP+NP+6))=\"\${sht337}\""
eval "F$((FP+NP+7))=\"\${sht334}\""
eval "F$((FP+NP+8))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht366}\""
eval "F$((NFP+1))=\"\${sht370}\""
CALLEE=emit
RPC=179; ACTION=call; return
;;
179)
eval "sht366=\"\$F$((FP+NP+0))\""
eval "sht359=\"\$F$((FP+NP+1))\""
eval "sht352=\"\$F$((FP+NP+2))\""
eval "sht349=\"\$F$((FP+NP+3))\""
eval "sht344=\"\$F$((FP+NP+4))\""
eval "sht341=\"\$F$((FP+NP+5))\""
eval "sht337=\"\$F$((FP+NP+6))\""
eval "sht334=\"\$F$((FP+NP+7))\""
eval "sht331=\"\$F$((FP+NP+8))\""
sht371="${R}"
sht372="${sht371}"
eval "F$((FP+NP+0))=\"\${sht372}\""
eval "F$((FP+NP+1))=\"\${sht366}\""
eval "F$((FP+NP+2))=\"\${sht359}\""
eval "F$((FP+NP+3))=\"\${sht352}\""
eval "F$((FP+NP+4))=\"\${sht349}\""
eval "F$((FP+NP+5))=\"\${sht344}\""
eval "F$((FP+NP+6))=\"\${sht341}\""
eval "F$((FP+NP+7))=\"\${sht337}\""
eval "F$((FP+NP+8))=\"\${sht334}\""
eval "F$((FP+NP+9))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht372}\""
eval "F$((NFP+1))=\"\${sht344}\""
CALLEE=switch
RPC=180; ACTION=call; return
;;
180)
eval "sht372=\"\$F$((FP+NP+0))\""
eval "sht366=\"\$F$((FP+NP+1))\""
eval "sht359=\"\$F$((FP+NP+2))\""
eval "sht352=\"\$F$((FP+NP+3))\""
eval "sht349=\"\$F$((FP+NP+4))\""
eval "sht344=\"\$F$((FP+NP+5))\""
eval "sht341=\"\$F$((FP+NP+6))\""
eval "sht337=\"\$F$((FP+NP+7))\""
eval "sht334=\"\$F$((FP+NP+8))\""
eval "sht331=\"\$F$((FP+NP+9))\""
sht373="${R}"
sht374="${sht373}"
eval "F$((FP+NP+0))=\"\${sht374}\""
eval "F$((FP+NP+1))=\"\${sht372}\""
eval "F$((FP+NP+2))=\"\${sht366}\""
eval "F$((FP+NP+3))=\"\${sht359}\""
eval "F$((FP+NP+4))=\"\${sht352}\""
eval "F$((FP+NP+5))=\"\${sht349}\""
eval "F$((FP+NP+6))=\"\${sht344}\""
eval "F$((FP+NP+7))=\"\${sht341}\""
eval "F$((FP+NP+8))=\"\${sht337}\""
eval "F$((FP+NP+9))=\"\${sht334}\""
eval "F$((FP+NP+10))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht374}\""
CALLEE=tmpn
RPC=181; ACTION=call; return
;;
181)
eval "sht374=\"\$F$((FP+NP+0))\""
eval "sht372=\"\$F$((FP+NP+1))\""
eval "sht366=\"\$F$((FP+NP+2))\""
eval "sht359=\"\$F$((FP+NP+3))\""
eval "sht352=\"\$F$((FP+NP+4))\""
eval "sht349=\"\$F$((FP+NP+5))\""
eval "sht344=\"\$F$((FP+NP+6))\""
eval "sht341=\"\$F$((FP+NP+7))\""
eval "sht337=\"\$F$((FP+NP+8))\""
eval "sht334=\"\$F$((FP+NP+9))\""
eval "sht331=\"\$F$((FP+NP+10))\""
sht375="${R}"
sht376="${sht375}"
eval "F$((FP+NP+0))=\"\${sht376}\""
eval "F$((FP+NP+1))=\"\${sht374}\""
eval "F$((FP+NP+2))=\"\${sht372}\""
eval "F$((FP+NP+3))=\"\${sht366}\""
eval "F$((FP+NP+4))=\"\${sht359}\""
eval "F$((FP+NP+5))=\"\${sht352}\""
eval "F$((FP+NP+6))=\"\${sht349}\""
eval "F$((FP+NP+7))=\"\${sht344}\""
eval "F$((FP+NP+8))=\"\${sht341}\""
eval "F$((FP+NP+9))=\"\${sht337}\""
eval "F$((FP+NP+10))=\"\${sht334}\""
eval "F$((FP+NP+11))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht374}\""
eval "F$((NFP+1))=\"\${sht337}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=182; ACTION=call; return
;;
182)
eval "sht376=\"\$F$((FP+NP+0))\""
eval "sht374=\"\$F$((FP+NP+1))\""
eval "sht372=\"\$F$((FP+NP+2))\""
eval "sht366=\"\$F$((FP+NP+3))\""
eval "sht359=\"\$F$((FP+NP+4))\""
eval "sht352=\"\$F$((FP+NP+5))\""
eval "sht349=\"\$F$((FP+NP+6))\""
eval "sht344=\"\$F$((FP+NP+7))\""
eval "sht341=\"\$F$((FP+NP+8))\""
eval "sht337=\"\$F$((FP+NP+9))\""
eval "sht334=\"\$F$((FP+NP+10))\""
eval "sht331=\"\$F$((FP+NP+11))\""
sht377="${R}"
sht378="T:${sht376#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht377}\""
eval "F$((FP+NP+1))=\"\${sht376}\""
eval "F$((FP+NP+2))=\"\${sht374}\""
eval "F$((FP+NP+3))=\"\${sht372}\""
eval "F$((FP+NP+4))=\"\${sht366}\""
eval "F$((FP+NP+5))=\"\${sht359}\""
eval "F$((FP+NP+6))=\"\${sht352}\""
eval "F$((FP+NP+7))=\"\${sht349}\""
eval "F$((FP+NP+8))=\"\${sht344}\""
eval "F$((FP+NP+9))=\"\${sht341}\""
eval "F$((FP+NP+10))=\"\${sht337}\""
eval "F$((FP+NP+11))=\"\${sht334}\""
eval "F$((FP+NP+12))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht378}\""
CALLEE=qset
RPC=183; ACTION=call; return
;;
183)
eval "sht377=\"\$F$((FP+NP+0))\""
eval "sht376=\"\$F$((FP+NP+1))\""
eval "sht374=\"\$F$((FP+NP+2))\""
eval "sht372=\"\$F$((FP+NP+3))\""
eval "sht366=\"\$F$((FP+NP+4))\""
eval "sht359=\"\$F$((FP+NP+5))\""
eval "sht352=\"\$F$((FP+NP+6))\""
eval "sht349=\"\$F$((FP+NP+7))\""
eval "sht344=\"\$F$((FP+NP+8))\""
eval "sht341=\"\$F$((FP+NP+9))\""
eval "sht337=\"\$F$((FP+NP+10))\""
eval "sht334=\"\$F$((FP+NP+11))\""
eval "sht331=\"\$F$((FP+NP+12))\""
sht379="${R}"
eval "F$((FP+NP+0))=\"\${sht376}\""
eval "F$((FP+NP+1))=\"\${sht374}\""
eval "F$((FP+NP+2))=\"\${sht372}\""
eval "F$((FP+NP+3))=\"\${sht366}\""
eval "F$((FP+NP+4))=\"\${sht359}\""
eval "F$((FP+NP+5))=\"\${sht352}\""
eval "F$((FP+NP+6))=\"\${sht349}\""
eval "F$((FP+NP+7))=\"\${sht344}\""
eval "F$((FP+NP+8))=\"\${sht341}\""
eval "F$((FP+NP+9))=\"\${sht337}\""
eval "F$((FP+NP+10))=\"\${sht334}\""
eval "F$((FP+NP+11))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht377}\""
eval "F$((NFP+1))=\"\${sht379}\""
CALLEE=emit
RPC=184; ACTION=call; return
;;
184)
eval "sht376=\"\$F$((FP+NP+0))\""
eval "sht374=\"\$F$((FP+NP+1))\""
eval "sht372=\"\$F$((FP+NP+2))\""
eval "sht366=\"\$F$((FP+NP+3))\""
eval "sht359=\"\$F$((FP+NP+4))\""
eval "sht352=\"\$F$((FP+NP+5))\""
eval "sht349=\"\$F$((FP+NP+6))\""
eval "sht344=\"\$F$((FP+NP+7))\""
eval "sht341=\"\$F$((FP+NP+8))\""
eval "sht337=\"\$F$((FP+NP+9))\""
eval "sht334=\"\$F$((FP+NP+10))\""
eval "sht331=\"\$F$((FP+NP+11))\""
sht380="${R}"
eval "F$((FP+NP+0))=\"\${sht380}\""
eval "F$((FP+NP+1))=\"\${sht376}\""
eval "F$((FP+NP+2))=\"\${sht374}\""
eval "F$((FP+NP+3))=\"\${sht372}\""
eval "F$((FP+NP+4))=\"\${sht366}\""
eval "F$((FP+NP+5))=\"\${sht359}\""
eval "F$((FP+NP+6))=\"\${sht352}\""
eval "F$((FP+NP+7))=\"\${sht349}\""
eval "F$((FP+NP+8))=\"\${sht344}\""
eval "F$((FP+NP+9))=\"\${sht341}\""
eval "F$((FP+NP+10))=\"\${sht337}\""
eval "F$((FP+NP+11))=\"\${sht334}\""
eval "F$((FP+NP+12))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht337}\""
CALLEE=lenl
RPC=185; ACTION=call; return
;;
185)
eval "sht380=\"\$F$((FP+NP+0))\""
eval "sht376=\"\$F$((FP+NP+1))\""
eval "sht374=\"\$F$((FP+NP+2))\""
eval "sht372=\"\$F$((FP+NP+3))\""
eval "sht366=\"\$F$((FP+NP+4))\""
eval "sht359=\"\$F$((FP+NP+5))\""
eval "sht352=\"\$F$((FP+NP+6))\""
eval "sht349=\"\$F$((FP+NP+7))\""
eval "sht344=\"\$F$((FP+NP+8))\""
eval "sht341=\"\$F$((FP+NP+9))\""
eval "sht337=\"\$F$((FP+NP+10))\""
eval "sht334=\"\$F$((FP+NP+11))\""
eval "sht331=\"\$F$((FP+NP+12))\""
sht381="${R}"
eval "F$((FP+NP+0))=\"\${sht376}\""
eval "F$((FP+NP+1))=\"\${sht374}\""
eval "F$((FP+NP+2))=\"\${sht372}\""
eval "F$((FP+NP+3))=\"\${sht366}\""
eval "F$((FP+NP+4))=\"\${sht359}\""
eval "F$((FP+NP+5))=\"\${sht352}\""
eval "F$((FP+NP+6))=\"\${sht349}\""
eval "F$((FP+NP+7))=\"\${sht344}\""
eval "F$((FP+NP+8))=\"\${sht341}\""
eval "F$((FP+NP+9))=\"\${sht337}\""
eval "F$((FP+NP+10))=\"\${sht334}\""
eval "F$((FP+NP+11))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht380}\""
eval "F$((NFP+1))=\"\${sht381}\""
CALLEE=bsm
RPC=186; ACTION=call; return
;;
186)
eval "sht376=\"\$F$((FP+NP+0))\""
eval "sht374=\"\$F$((FP+NP+1))\""
eval "sht372=\"\$F$((FP+NP+2))\""
eval "sht366=\"\$F$((FP+NP+3))\""
eval "sht359=\"\$F$((FP+NP+4))\""
eval "sht352=\"\$F$((FP+NP+5))\""
eval "sht349=\"\$F$((FP+NP+6))\""
eval "sht344=\"\$F$((FP+NP+7))\""
eval "sht341=\"\$F$((FP+NP+8))\""
eval "sht337=\"\$F$((FP+NP+9))\""
eval "sht334=\"\$F$((FP+NP+10))\""
eval "sht331=\"\$F$((FP+NP+11))\""
sht382="${R}"
eval "F$((FP+NP+0))=\"\${sht376}\""
eval "F$((FP+NP+1))=\"\${sht374}\""
eval "F$((FP+NP+2))=\"\${sht372}\""
eval "F$((FP+NP+3))=\"\${sht366}\""
eval "F$((FP+NP+4))=\"\${sht359}\""
eval "F$((FP+NP+5))=\"\${sht352}\""
eval "F$((FP+NP+6))=\"\${sht349}\""
eval "F$((FP+NP+7))=\"\${sht344}\""
eval "F$((FP+NP+8))=\"\${sht341}\""
eval "F$((FP+NP+9))=\"\${sht337}\""
eval "F$((FP+NP+10))=\"\${sht334}\""
eval "F$((FP+NP+11))=\"\${sht331}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht382}\""
CALLEE=bkzzP
RPC=187; ACTION=call; return
;;
187)
eval "sht376=\"\$F$((FP+NP+0))\""
eval "sht374=\"\$F$((FP+NP+1))\""
eval "sht372=\"\$F$((FP+NP+2))\""
eval "sht366=\"\$F$((FP+NP+3))\""
eval "sht359=\"\$F$((FP+NP+4))\""
eval "sht352=\"\$F$((FP+NP+5))\""
eval "sht349=\"\$F$((FP+NP+6))\""
eval "sht344=\"\$F$((FP+NP+7))\""
eval "sht341=\"\$F$((FP+NP+8))\""
eval "sht337=\"\$F$((FP+NP+9))\""
eval "sht334=\"\$F$((FP+NP+10))\""
eval "sht331=\"\$F$((FP+NP+11))\""
sht383="${R}"
eval "F$((FP+NP+0))=\"\${sht383}\""
eval "F$((FP+NP+1))=\"\${sht376}\""
eval "F$((FP+NP+2))=\"\${sht374}\""
eval "F$((FP+NP+3))=\"\${sht372}\""
eval "F$((FP+NP+4))=\"\${sht366}\""
eval "F$((FP+NP+5))=\"\${sht359}\""
eval "F$((FP+NP+6))=\"\${sht352}\""
eval "F$((FP+NP+7))=\"\${sht349}\""
eval "F$((FP+NP+8))=\"\${sht344}\""
eval "F$((FP+NP+9))=\"\${sht341}\""
eval "F$((FP+NP+10))=\"\${sht337}\""
eval "F$((FP+NP+11))=\"\${sht334}\""
eval "F$((FP+NP+12))=\"\${sht331}\""
hp_cons "S:val" "${sht376}"
eval "sht383=\"\$F$((FP+NP+0))\""
eval "sht376=\"\$F$((FP+NP+1))\""
eval "sht374=\"\$F$((FP+NP+2))\""
eval "sht372=\"\$F$((FP+NP+3))\""
eval "sht366=\"\$F$((FP+NP+4))\""
eval "sht359=\"\$F$((FP+NP+5))\""
eval "sht352=\"\$F$((FP+NP+6))\""
eval "sht349=\"\$F$((FP+NP+7))\""
eval "sht344=\"\$F$((FP+NP+8))\""
eval "sht341=\"\$F$((FP+NP+9))\""
eval "sht337=\"\$F$((FP+NP+10))\""
eval "sht334=\"\$F$((FP+NP+11))\""
eval "sht331=\"\$F$((FP+NP+12))\""
sht384="${R}"
eval "F$((FP+NP+0))=\"\${sht376}\""
eval "F$((FP+NP+1))=\"\${sht374}\""
eval "F$((FP+NP+2))=\"\${sht372}\""
eval "F$((FP+NP+3))=\"\${sht366}\""
eval "F$((FP+NP+4))=\"\${sht359}\""
eval "F$((FP+NP+5))=\"\${sht352}\""
eval "F$((FP+NP+6))=\"\${sht349}\""
eval "F$((FP+NP+7))=\"\${sht344}\""
eval "F$((FP+NP+8))=\"\${sht341}\""
eval "F$((FP+NP+9))=\"\${sht337}\""
eval "F$((FP+NP+10))=\"\${sht334}\""
eval "F$((FP+NP+11))=\"\${sht331}\""
hp_cons "${sht383}" "${sht384}"
eval "sht376=\"\$F$((FP+NP+0))\""
eval "sht374=\"\$F$((FP+NP+1))\""
eval "sht372=\"\$F$((FP+NP+2))\""
eval "sht366=\"\$F$((FP+NP+3))\""
eval "sht359=\"\$F$((FP+NP+4))\""
eval "sht352=\"\$F$((FP+NP+5))\""
eval "sht349=\"\$F$((FP+NP+6))\""
eval "sht344=\"\$F$((FP+NP+7))\""
eval "sht341=\"\$F$((FP+NP+8))\""
eval "sht337=\"\$F$((FP+NP+9))\""
eval "sht334=\"\$F$((FP+NP+10))\""
eval "sht331=\"\$F$((FP+NP+11))\""
sht385="${R}"
R="${sht385}"; ACTION=ret; return
;;
esac; }
SIZE_ltbegin=6
ltbegin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltbegin))
NP=6
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltail
RPC=3; ACTION=call; return
;;
2)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=4; ACTION=call; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht4="${R}"
sht5="${sht4}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${sht5}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht7}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_ltail=15
ltail() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltail))
NP=6
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:begin" ]; then
sht2="S:t"
else
sht2="NIL"
fi
sht0="${sht2}"
PC=3; ACTION=jump; return
;;
2)
sht0="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht0}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltbegin
RPC=6; ACTION=call; return
;;
5)
if [ "${p0#P:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
6)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
7)
hp_car "${p0}"
sht6="${R}"
if [ "${sht6}" = "${p2}" ]; then
sht7="S:t"
else
sht7="NIL"
fi
sht5="${sht7}"
PC=9; ACTION=jump; return
;;
8)
sht5="NIL"
PC=9; ACTION=jump; return
;;
9)
if [ "${sht5}" != NIL ]; then PC=10; else PC=11; fi
ACTION=jump; return
;;
10)
hp_cdr "${p0}"
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=largs
RPC=12; ACTION=call; return
;;
11)
if [ "${p0#P:}" != "${p0}" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
12)
sht9="${R}"
sht10="${sht9}"
hp_car "${sht10}"
sht11="${R}"
hp_cdr "${sht10}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${sht12}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=setparams
RPC=13; ACTION=call; return
;;
13)
eval "sht10=\"\$F$((FP+NP+0))\""
sht13="${R}"
sht14="T:${G_DQ#??} & goto :eof"
sht15="T:ACTION=tail${sht14#??}"
sht16="T:${G_DQ#??}${sht15#??}"
sht17="T: & set ${sht16#??}"
sht18="T:${G_DQ#??}${sht17#??}"
sht19="T:PC=0${sht18#??}"
sht20="T:${G_DQ#??}${sht19#??}"
sht21="T:set ${sht20#??}"
eval "F$((FP+NP+0))=\"\${sht10}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht21}\""
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
eval "sht10=\"\$F$((FP+NP+0))\""
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
15)
hp_car "${p0}"
sht24="${R}"
if [ "${sht24}" = "S:if" ]; then
sht25="S:t"
else
sht25="NIL"
fi
sht23="${sht25}"
PC=17; ACTION=jump; return
;;
16)
sht23="NIL"
PC=17; ACTION=jump; return
;;
17)
if [ "${sht23}" != NIL ]; then PC=18; else PC=19; fi
ACTION=jump; return
;;
18)
hp_cdr "${p0}"
sht26="${R}"
hp_car "${sht26}"
sht27="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=ctest
RPC=20; ACTION=call; return
;;
19)
if [ "${p0#P:}" != "${p0}" ]; then PC=33; else PC=34; fi
ACTION=jump; return
;;
20)
sht28="${R}"
sht29="${sht28}"
hp_car "${sht29}"
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
CALLEE=b_npc
RPC=21; ACTION=call; return
;;
21)
eval "sht29=\"\$F$((FP+NP+0))\""
sht31="${R}"
sht32="${sht31}"
hp_car "${sht29}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
CALLEE=b_npc
RPC=22; ACTION=call; return
;;
22)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
sht34="${R}"
sht35="I:$(( ${sht34#??} + 1 ))"
sht36="${sht35}"
hp_car "${sht29}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=bnpczzP
RPC=23; ACTION=call; return
;;
23)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht38}\""
CALLEE=bnpczzP
RPC=24; ACTION=call; return
;;
24)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht39="${R}"
hp_cdr "${sht29}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=ifjump
RPC=25; ACTION=call; return
;;
25)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht41}\""
CALLEE=emit
RPC=26; ACTION=call; return
;;
26)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
CALLEE=jumpto
RPC=27; ACTION=call; return
;;
27)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
eval "F$((NFP+1))=\"\${sht43}\""
CALLEE=emit
RPC=28; ACTION=call; return
;;
28)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht44="${R}"
sht45="${sht44}"
hp_cdr "${p0}"
sht46="${R}"
hp_cdr "${sht46}"
sht47="${R}"
hp_car "${sht47}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht48}\""
eval "F$((FP+NP+4))=\"\${sht45}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
eval "F$((FP+NP+6))=\"\${sht32}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht45}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=switch
RPC=29; ACTION=call; return
;;
29)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht48=\"\$F$((FP+NP+3))\""
eval "sht45=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
eval "sht32=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${sht49}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltail
RPC=30; ACTION=call; return
;;
30)
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht50="${R}"
sht51="${sht50}"
eval "F$((FP+NP+0))=\"\${sht51}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=31; ACTION=call; return
;;
31)
eval "sht51=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
sht52="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht52}\""
eval "F$((FP+NP+4))=\"\${sht51}\""
eval "F$((FP+NP+5))=\"\${sht45}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht32}\""
eval "F$((FP+NP+8))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
eval "F$((NFP+1))=\"\${sht36}\""
CALLEE=switch
RPC=32; ACTION=call; return
;;
32)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht52=\"\$F$((FP+NP+3))\""
eval "sht51=\"\$F$((FP+NP+4))\""
eval "sht45=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht32=\"\$F$((FP+NP+7))\""
eval "sht29=\"\$F$((FP+NP+8))\""
sht53="${R}"
eval "F$((FP+0))=\"\${sht52}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht53}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
33)
hp_car "${p0}"
sht55="${R}"
if [ "${sht55}" = "S:cond" ]; then
sht56="S:t"
else
sht56="NIL"
fi
sht54="${sht56}"
PC=35; ACTION=jump; return
;;
34)
sht54="NIL"
PC=35; ACTION=jump; return
;;
35)
if [ "${sht54}" != NIL ]; then PC=36; else PC=37; fi
ACTION=jump; return
;;
36)
hp_cdr "${p0}"
sht57="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht57}\""
CALLEE=cond_zzGif
RPC=38; ACTION=call; return
;;
37)
if [ "${p0#P:}" != "${p0}" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
38)
sht58="${R}"
eval "F$((FP+0))=\"\${sht58}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
39)
hp_car "${p0}"
sht60="${R}"
if [ "${sht60}" = "S:let" ]; then
sht61="S:t"
else
sht61="NIL"
fi
sht59="${sht61}"
PC=41; ACTION=jump; return
;;
40)
sht59="NIL"
PC=41; ACTION=jump; return
;;
41)
if [ "${sht59}" != NIL ]; then PC=42; else PC=43; fi
ACTION=jump; return
;;
42)
hp_cdr "${p0}"
sht62="${R}"
hp_car "${sht62}"
sht63="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht63}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lbinds
RPC=44; ACTION=call; return
;;
43)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=45; ACTION=call; return
;;
44)
sht64="${R}"
sht65="${sht64}"
hp_cdr "${p0}"
sht66="${R}"
hp_cdr "${sht66}"
sht67="${R}"
hp_car "${sht67}"
sht68="${R}"
hp_cdr "${sht65}"
sht69="${R}"
hp_car "${sht69}"
sht70="${R}"
hp_car "${sht65}"
sht71="${R}"
hp_cdr "${sht65}"
sht72="${R}"
hp_cdr "${sht72}"
sht73="${R}"
eval "F$((FP+0))=\"\${sht68}\""
eval "F$((FP+1))=\"\${sht70}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht71}\""
eval "F$((FP+5))=\"\${sht73}\""
PC=0; ACTION=tail; return
;;
45)
sht74="${R}"
sht75="${sht74}"
hp_car "${sht75}"
sht76="${R}"
hp_cdr "${sht75}"
sht77="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht77}\""
CALLEE=vref
RPC=46; ACTION=call; return
;;
46)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
sht78="${R}"
sht79="T:${G_DQ#??} & goto :eof"
sht80="T:ACTION=ret${sht79#??}"
sht81="T:${G_DQ#??}${sht80#??}"
sht82="T: & set ${sht81#??}"
sht83="T:${G_DQ#??}${sht82#??}"
sht84="T:${sht78#??}${sht83#??}"
sht85="T:R=${sht84#??}"
sht86="T:${G_DQ#??}${sht85#??}"
sht87="T:set ${sht86#??}"
eval "F$((FP+NP+0))=\"\${sht75}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht76}\""
eval "F$((NFP+1))=\"\${sht87}\""
CALLEE=emit
RPC=47; ACTION=call; return
;;
47)
eval "sht75=\"\$F$((FP+NP+0))\""
sht88="${R}"
R="${sht88}"; ACTION=ret; return
;;
esac; }
SIZE_pmap_fr=3
pmap_fr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_pmap_fr))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
sht1="T:${p1#??}"
sht2="T:p${sht1#??}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
sht5="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=pmap_fr
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_ploads=3
ploads() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_ploads))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
if [ ${p1#??} -eq 0 ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht0="T:p0=%%F!FP!%%${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:call set ${sht1#??}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"I:1\""
CALLEE=ploads
RPC=5; ACTION=call; return
;;
4)
sht6="T:${p1#??}"
sht7="T:${p1#??}"
sht8="T:=%%F!_i!%%${G_DQ#??}"
sht9="T:${sht7#??}${sht8#??}"
sht10="T:p${sht9#??}"
sht11="T:${G_DQ#??}${sht10#??}"
sht12="T: & call set ${sht11#??}"
sht13="T:${sht6#??}${sht12#??}"
sht14="T:set /a _i=!FP!+${sht13#??}"
hp_cdr "${p0}"
sht15="${R}"
sht16="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=ploads
RPC=6; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
sht17="${R}"
hp_cons "${sht14}" "${sht17}"
sht18="${R}"
R="${sht18}"; ACTION=ret; return
;;
esac; }
SIZE_blkget=2
blkget() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_blkget))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "${p1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+0))=\"\${sht4}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_caseblocks=4
caseblocks() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_caseblocks))
NP=3
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p1#??}"
sht1="T::_pc${sht0#??}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=blkget
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht1}" "${sht2}"
sht3="${R}"
sht4="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht4}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=caseblocks
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_compile_fn=15
compile_fn() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
eval "p6=\"\$F$((FP+6))\""
FTOP=$((FP + SIZE_compile_fn))
NP=7
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
CALLEE=lenl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "T:\$GFNS" "${p6}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=pmap_fr
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "${sht3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
sht5="${sht4}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
CALLEE=mkb
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht5}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht6}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=4; ACTION=call; return
;;
4)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
sht8="${sht7}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_pc
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_cur
RPC=6; ACTION=call; return
;;
6)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=7; ACTION=call; return
;;
7)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht9}" "${sht11}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_blk
RPC=8; ACTION=call; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht12}" "${sht13}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht14="${R}"
sht15="${sht14}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_smax
RPC=9; ACTION=call; return
;;
9)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht16="${R}"
sht17="I:$(( ${sht1#??} + ${sht16#??} ))"
sht18="${sht17}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=10; ACTION=call; return
;;
10)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht19="${R}"
sht20="T:${sht18#??}"
sht21="T:set /a FT=!FP!+${sht20#??}"
sht22="T:${sht1#??}"
sht23="T:NP=${sht22#??}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht24}" "NIL"
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht25="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht21}" "${sht25}"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
eval "F$((NFP+1))=\"\${sht26}\""
CALLEE=append
RPC=12; ACTION=call; return
;;
12)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht27="${R}"
sht28="${sht27}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht28}\""
eval "F$((FP+NP+2))=\"\${sht28}\""
eval "F$((FP+NP+3))=\"\${sht18}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht5}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_npc
RPC=13; ACTION=call; return
;;
13)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht28=\"\$F$((FP+NP+1))\""
eval "sht28=\"\$F$((FP+NP+2))\""
eval "sht18=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht5=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
eval "F$((NFP+1))=\"\${sht15}\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"\${sht29}\""
eval "F$((NFP+4))=\"\${p1}\""
CALLEE=seg_files
RPC=14; ACTION=call; return
;;
14)
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht30}" "${p4}"
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht31="${R}"
R="${sht31}"; ACTION=ret; return
;;
esac; }
SIZE_compile_clambda=14
compile_clambda() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_compile_clambda))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=lenl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "T:\$GFNS" "${p4}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=append
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=pmap_fr
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "${sht4}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="${sht5}"
sht7="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=mangle
RPC=4; ACTION=call; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht8="${R}"
sht9="${sht8}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
CALLEE=mkb
RPC=5; ACTION=call; return
;;
5)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht6}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht10}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=6; ACTION=call; return
;;
6)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht11="${R}"
sht12="${sht11}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_pc
RPC=7; ACTION=call; return
;;
7)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_cur
RPC=8; ACTION=call; return
;;
8)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=9; ACTION=call; return
;;
9)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht13}" "${sht15}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_blk
RPC=10; ACTION=call; return
;;
10)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht16}" "${sht17}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht18="${R}"
sht19="${sht18}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_smax
RPC=11; ACTION=call; return
;;
11)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht20="${R}"
sht21="I:$(( ${sht1#??} + ${sht20#??} ))"
sht22="${sht21}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=12; ACTION=call; return
;;
12)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=cap_loads
RPC=13; ACTION=call; return
;;
13)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht24="${R}"
sht25="T:${sht22#??}"
sht26="T:set /a FT=!FP!+${sht25#??}"
sht27="T:${sht1#??}"
sht28="T:NP=${sht27#??}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
CALLEE=qset
RPC=14; ACTION=call; return
;;
14)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
hp_cons "${sht29}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht6}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
hp_cons "${sht26}" "${sht30}"
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht6=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
eval "F$((NFP+1))=\"\${sht31}\""
CALLEE=append
RPC=15; ACTION=call; return
;;
15)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht33="${R}"
sht34="${sht33}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht34}\""
eval "F$((FP+NP+2))=\"\${sht34}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_npc
RPC=17; ACTION=call; return
;;
17)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht34=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht34}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${sht19}\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"\${sht35}\""
eval "F$((NFP+4))=\"\${sht9}\""
CALLEE=seg_files
RPC=18; ACTION=call; return
;;
18)
eval "sht34=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht36="${R}"
R="${sht36}"; ACTION=ret; return
;;
esac; }
SIZE_tst=2
tst() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tst))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
if [ "${sht1#P:}" != "${sht1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "T:out" "${sht1}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht3="I:$(( ${#sht1} - 2 ))"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_show_list=2
show_list() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_show_list))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=show
RPC=3; ACTION=call; return
;;
2)
hp_cdr "${p0}"
sht3="${R}"
if [ "${sht3#P:}" != "${sht3}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=show
RPC=6; ACTION=call; return
;;
5)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=show
RPC=8; ACTION=call; return
;;
6)
sht5="${R}"
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=show_list
RPC=7; ACTION=call; return
;;
7)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="T: ${sht7#??}"
sht9="T:${sht5#??}${sht8#??}"
R="${sht9}"; ACTION=ret; return
;;
8)
sht11="${R}"
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=show
RPC=9; ACTION=call; return
;;
9)
eval "sht11=\"\$F$((FP+NP+0))\""
sht13="${R}"
sht14="T: . ${sht13#??}"
sht15="T:${sht11#??}${sht14#??}"
R="${sht15}"; ACTION=ret; return
;;
esac; }
SIZE_show=1
show() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_show))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:()"; ACTION=ret; return
;;
2)
if [ "${p0#I:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht0="T:${p0#??}"
R="${sht0}"; ACTION=ret; return
;;
4)
if [ "${p0#S:}" != "${p0}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
sht1="T:${p0#??}"
R="${sht1}"; ACTION=ret; return
;;
6)
if [ "${p0#T:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
sht2="T:${p0#??}${G_DQ#??}"
sht3="T:${G_DQ#??}${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
8)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=show_list
RPC=9; ACTION=call; return
;;
9)
sht4="${R}"
sht5="T:${sht4#??})"
sht6="T:(${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_def_lambdazzQ=1
def_lambdazzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_def_lambdazzQ))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:define" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=5; ACTION=call; return
;;
4)
R="NIL"; ACTION=ret; return
;;
5)
sht1="${R}"
if [ "${sht1#P:}" != "${sht1}" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
7)
R="NIL"; ACTION=ret; return
;;
8)
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
if [ "${sht3}" = "S:lambda" ]; then
sht4="S:t"
else
sht4="NIL"
fi
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_def_clambdazzQ=1
def_clambdazzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_def_clambdazzQ))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:define" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=5; ACTION=call; return
;;
4)
R="NIL"; ACTION=ret; return
;;
5)
sht1="${R}"
if [ "${sht1#P:}" != "${sht1}" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
7)
R="NIL"; ACTION=ret; return
;;
8)
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
if [ "${sht3}" = "S:clambda" ]; then
sht4="S:t"
else
sht4="NIL"
fi
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_resid_bind=2
resid_bind() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_resid_bind))
NP=1
case $PC in
0)
sht0="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=mangle
RPC=1; ACTION=call; return
;;
1)
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht1}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:make-compiled" "${sht2}"
eval "p0=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht3}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${p0}" "${sht4}"
sht5="${R}"
hp_cons "S:define" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_subst=4
subst() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_subst))
NP=3
case $PC in
0)
if [ "${p2}" = "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
if [ "${p2#P:}" != "${p2}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p2}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht0}\""
CALLEE=subst
RPC=5; ACTION=call; return
;;
4)
R="${p2}"; ACTION=ret; return
;;
5)
sht1="${R}"
hp_cdr "${p2}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht2}\""
CALLEE=subst
RPC=6; ACTION=call; return
;;
6)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_substzzS=5
substzzS() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_substzzS))
NP=3
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p2}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${p1}"
sht1="${R}"
hp_car "${p0}"
sht2="${R}"
hp_car "${p1}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=subst
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht1}\""
eval "F$((FP+2))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_refszzQ=2
refszzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_refszzQ))
NP=2
case $PC in
0)
if [ "${p1}" = "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p1#P:}" != "${p1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht0}\""
CALLEE=refszzQ
RPC=5; ACTION=call; return
;;
4)
R="NIL"; ACTION=ret; return
;;
5)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
R="S:t"; ACTION=ret; return
;;
7)
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_map_inline_expr=3
map_inline_expr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_map_inline_expr))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_expr
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_inline_form=3
map_inline_form() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_map_inline_form))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_form
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_form
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_mexpand=2
map_mexpand() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_map_mexpand))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=mexpand
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=map_mexpand
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_show=2
map_show() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_map_show))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=show
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=map_show
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_inline_expr=5
inline_expr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_inline_expr))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=assoc
RPC=3; ACTION=call; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
3)
sht1="${R}"
sht2="${sht1}"
if [ "${sht2}" = NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=6; ACTION=call; return
;;
5)
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
6)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht3}" "${sht5}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
7)
eval "sht2=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht9}\""
eval "F$((NFP+2))=\"\${sht10}\""
CALLEE=substzzS
RPC=10; ACTION=call; return
;;
10)
eval "sht2=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+0))=\"\${sht11}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_mk_tbl=3
mk_tbl() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mk_tbl))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
5)
sht2="NIL"
PC=6; ACTION=jump; return
;;
6)
if [ "${sht2}" != NIL ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
7)
sht4="${R}"
hp_car "${p0}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
8)
eval "sht4=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht4=\"\$F$((FP+NP+0))\""
sht7="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=refszzQ
RPC=10; ACTION=call; return
;;
10)
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=not
RPC=11; ACTION=call; return
;;
11)
sht9="${R}"
sht2="${sht9}"
PC=6; ACTION=jump; return
;;
12)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cadr
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht24="${R}"
eval "F$((FP+0))=\"\${sht24}\""
PC=0; ACTION=tail; return
;;
14)
sht11="${R}"
hp_car "${p0}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=caddr
RPC=15; ACTION=call; return
;;
15)
eval "sht11=\"\$F$((FP+NP+0))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=cadr
RPC=16; ACTION=call; return
;;
16)
eval "sht11=\"\$F$((FP+NP+0))\""
sht14="${R}"
hp_car "${p0}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=caddr
RPC=17; ACTION=call; return
;;
17)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=caddr
RPC=18; ACTION=call; return
;;
18)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
hp_cons "${sht17}" "NIL"
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
hp_cons "${sht14}" "${sht18}"
eval "sht11=\"\$F$((FP+NP+0))\""
sht19="${R}"
hp_cons "${sht11}" "${sht19}"
sht20="${R}"
hp_cdr "${p0}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=mk_tbl
RPC=19; ACTION=call; return
;;
19)
eval "sht20=\"\$F$((FP+NP+0))\""
sht22="${R}"
hp_cons "${sht20}" "${sht22}"
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
esac; }
SIZE_inline_form=4
inline_form() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_inline_form))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=def_lambdazzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadr
RPC=4; ACTION=call; return
;;
3)
R="${p0}"; ACTION=ret; return
;;
4)
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=5; ACTION=call; return
;;
5)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
6)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
8)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_expr
RPC=9; ACTION=call; return
;;
9)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
hp_cons "${sht6}" "NIL"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht3}" "${sht7}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "S:lambda" "${sht8}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht9}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
sht10="${R}"
hp_cons "${sht1}" "${sht10}"
sht11="${R}"
hp_cons "S:define" "${sht11}"
sht12="${R}"
R="${sht12}"; ACTION=ret; return
;;
esac; }
SIZE_inline_program=2
inline_program() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_inline_program))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=mk_tbl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=map_inline_form
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_cond_zzGif=3
cond_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cond_zzGif))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "S:t" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_cons "S:begin" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_car "${p0}"
sht7="${R}"
hp_cdr "${sht7}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
hp_cons "S:begin" "${sht8}"
eval "sht6=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cdr "${p0}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cond_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
hp_cons "${sht11}" "NIL"
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
hp_cons "${sht9}" "${sht12}"
eval "sht6=\"\$F$((FP+NP+0))\""
sht13="${R}"
hp_cons "${sht6}" "${sht13}"
sht14="${R}"
hp_cons "S:if" "${sht14}"
sht15="${R}"
R="${sht15}"; ACTION=ret; return
;;
esac; }
SIZE_str_zzGapp=2
str_zzGapp() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_str_zzGapp))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=str_zzGapp
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:string-append" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_list_zzGcons=2
list_zzGcons() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_list_zzGcons))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=list_zzGcons
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht2}" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht0}" "${sht3}"
sht4="${R}"
hp_cons "S:cons" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_and_zzGif=3
and_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_and_zzGif))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=and_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "S:nil" "NIL"
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "${sht5}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht2}" "${sht6}"
sht7="${R}"
hp_cons "S:if" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_or_zzGif=2
or_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_or_zzGif))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cons "${sht2}" "NIL"
sht3="${R}"
hp_cons "S:__or" "${sht3}"
sht4="${R}"
hp_cons "${sht4}" "NIL"
sht5="${R}"
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=or_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "${sht7}" "NIL"
eval "sht5=\"\$F$((FP+NP+0))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:__or" "${sht8}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:__or" "${sht9}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:if" "${sht10}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "${sht11}" "NIL"
eval "sht5=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cons "${sht5}" "${sht12}"
sht13="${R}"
hp_cons "S:let" "${sht13}"
sht14="${R}"
R="${sht14}"; ACTION=ret; return
;;
esac; }
SIZE_when_zzGif=4
when_zzGif() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_when_zzGif))
NP=2
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:begin" "${p1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "S:nil" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht0}" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
hp_cons "S:if" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_unless_zzGif=3
unless_zzGif() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_unless_zzGif))
NP=2
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:begin" "${p1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht0}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:nil" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
hp_cons "S:if" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_case_clause=1
case_clause() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_case_clause))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:else" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
hp_cons "S:t" "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht3="${R}"
hp_cons "${sht3}" "NIL"
sht4="${R}"
hp_cons "S:quote" "${sht4}"
sht5="${R}"
hp_cons "${sht5}" "NIL"
sht6="${R}"
hp_cons "S:__case" "${sht6}"
sht7="${R}"
hp_cons "S:eq?" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
hp_cons "${sht8}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_case_clauses=2
case_clauses() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_case_clauses))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=case_clause
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=case_clauses
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_case_zzGcond=3
case_zzGcond() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_case_zzGcond))
NP=2
case $PC in
0)
hp_cons "${p0}" "NIL"
sht0="${R}"
hp_cons "S:__case" "${sht0}"
sht1="${R}"
hp_cons "${sht1}" "NIL"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=case_clauses
RPC=1; ACTION=call; return
;;
1)
eval "sht2=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "S:cond" "${sht3}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:let" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_letzzS_zzGlets=3
letzzS_zzGlets() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_letzzS_zzGlets))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "S:begin" "${p1}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
hp_cons "${sht1}" "NIL"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=letzzS_zzGlets
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:let" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_mexpand=3
mexpand() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mexpand))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
3)
R="${p0}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=map_mexpand
RPC=7; ACTION=call; return
;;
6)
hp_car "${p0}"
sht9="${R}"
if [ "${sht9}" = "S:cond" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
hp_cons "S:lambda" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
8)
hp_cdr "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cond_zzGif
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht12="${R}"
if [ "${sht12}" = "S:and" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
10)
sht11="${R}"
eval "F$((FP+0))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
11)
hp_cdr "${p0}"
sht13="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=and_zzGif
RPC=13; ACTION=call; return
;;
12)
hp_car "${p0}"
sht15="${R}"
if [ "${sht15}" = "S:or" ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
13)
sht14="${R}"
eval "F$((FP+0))=\"\${sht14}\""
PC=0; ACTION=tail; return
;;
14)
hp_cdr "${p0}"
sht16="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=or_zzGif
RPC=16; ACTION=call; return
;;
15)
hp_car "${p0}"
sht18="${R}"
if [ "${sht18}" = "S:when" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
16)
sht17="${R}"
eval "F$((FP+0))=\"\${sht17}\""
PC=0; ACTION=tail; return
;;
17)
hp_cdr "${p0}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
hp_cdr "${p0}"
sht21="${R}"
hp_cdr "${sht21}"
sht22="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht22}\""
CALLEE=when_zzGif
RPC=19; ACTION=call; return
;;
18)
hp_car "${p0}"
sht24="${R}"
if [ "${sht24}" = "S:unless" ]; then PC=20; else PC=21; fi
ACTION=jump; return
;;
19)
sht23="${R}"
eval "F$((FP+0))=\"\${sht23}\""
PC=0; ACTION=tail; return
;;
20)
hp_cdr "${p0}"
sht25="${R}"
hp_car "${sht25}"
sht26="${R}"
hp_cdr "${p0}"
sht27="${R}"
hp_cdr "${sht27}"
sht28="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht28}\""
CALLEE=unless_zzGif
RPC=22; ACTION=call; return
;;
21)
hp_car "${p0}"
sht30="${R}"
if [ "${sht30}" = "S:case" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
22)
sht29="${R}"
eval "F$((FP+0))=\"\${sht29}\""
PC=0; ACTION=tail; return
;;
23)
hp_cdr "${p0}"
sht31="${R}"
hp_car "${sht31}"
sht32="${R}"
hp_cdr "${p0}"
sht33="${R}"
hp_cdr "${sht33}"
sht34="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht34}\""
CALLEE=case_zzGcond
RPC=25; ACTION=call; return
;;
24)
hp_car "${p0}"
sht36="${R}"
if [ "${sht36}" = "S:let*" ]; then PC=26; else PC=27; fi
ACTION=jump; return
;;
25)
sht35="${R}"
eval "F$((FP+0))=\"\${sht35}\""
PC=0; ACTION=tail; return
;;
26)
hp_cdr "${p0}"
sht37="${R}"
hp_car "${sht37}"
sht38="${R}"
hp_cdr "${p0}"
sht39="${R}"
hp_cdr "${sht39}"
sht40="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht38}\""
eval "F$((NFP+1))=\"\${sht40}\""
CALLEE=letzzS_zzGlets
RPC=28; ACTION=call; return
;;
27)
hp_car "${p0}"
sht42="${R}"
if [ "${sht42}" = "S:str" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
28)
sht41="${R}"
eval "F$((FP+0))=\"\${sht41}\""
PC=0; ACTION=tail; return
;;
29)
hp_cdr "${p0}"
sht43="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=map_mexpand
RPC=31; ACTION=call; return
;;
30)
hp_car "${p0}"
sht46="${R}"
if [ "${sht46}" = "S:list" ]; then PC=33; else PC=34; fi
ACTION=jump; return
;;
31)
sht44="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
CALLEE=str_zzGapp
RPC=32; ACTION=call; return
;;
32)
sht45="${R}"
R="${sht45}"; ACTION=ret; return
;;
33)
hp_cdr "${p0}"
sht47="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=map_mexpand
RPC=35; ACTION=call; return
;;
34)
hp_car "${p0}"
sht50="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht50}\""
CALLEE=mexpand
RPC=37; ACTION=call; return
;;
35)
sht48="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=list_zzGcons
RPC=36; ACTION=call; return
;;
36)
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
37)
sht51="${R}"
sht52="${sht51}"
hp_cdr "${p0}"
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht52}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
CALLEE=mexpand
RPC=38; ACTION=call; return
;;
38)
eval "sht52=\"\$F$((FP+NP+0))\""
sht54="${R}"
sht55="${sht54}"
hp_car "${p0}"
sht56="${R}"
if [ "${sht52}" = "${sht56}" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
39)
hp_cdr "${p0}"
sht58="${R}"
if [ "${sht55}" = "${sht58}" ]; then
sht59="S:t"
else
sht59="NIL"
fi
sht57="${sht59}"
PC=41; ACTION=jump; return
;;
40)
sht57="NIL"
PC=41; ACTION=jump; return
;;
41)
if [ "${sht57}" != NIL ]; then PC=42; else PC=43; fi
ACTION=jump; return
;;
42)
R="${p0}"; ACTION=ret; return
;;
43)
eval "F$((FP+NP+0))=\"\${sht55}\""
eval "F$((FP+NP+1))=\"\${sht52}\""
hp_cons "${sht52}" "${sht55}"
eval "sht55=\"\$F$((FP+NP+0))\""
eval "sht52=\"\$F$((FP+NP+1))\""
sht60="${R}"
R="${sht60}"; ACTION=ret; return
;;
esac; }
SIZE_mexpand_program=1
mexpand_program() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mexpand_program))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=map_mexpand
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_concat=2
concat() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_concat))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=concat
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_cp=10
cp() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_cp))
NP=6
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
gc
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=def_clambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=caddr
RPC=6; ACTION=call; return
;;
5)
hp_car "${p0}"
sht14="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
CALLEE=def_lambdazzQ
RPC=13; ACTION=call; return
;;
6)
sht4="${R}"
sht5="${sht4}"
hp_car "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
7)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=cadr
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=cadddr
RPC=10; ACTION=call; return
;;
10)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht8}\""
eval "F$((NFP+2))=\"\${sht9}\""
eval "F$((NFP+3))=\"\${sht10}\""
eval "F$((NFP+4))=\"\${p5}\""
CALLEE=compile_clambda
RPC=11; ACTION=call; return
;;
11)
eval "sht5=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=write_segs
RPC=12; ACTION=call; return
;;
12)
eval "sht5=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cdr "${p0}"
sht13="${R}"
eval "F$((FP+0))=\"\${sht13}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
13)
sht15="${R}"
if [ "${sht15}" != NIL ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
14)
hp_car "${p0}"
sht16="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=cadr
RPC=16; ACTION=call; return
;;
15)
hp_car "${p0}"
sht42="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
CALLEE=atom_constzzQ
RPC=28; ACTION=call; return
;;
16)
sht17="${R}"
sht18="T:${sht17#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
CALLEE=mangle
RPC=17; ACTION=call; return
;;
17)
sht19="${R}"
sht20="${sht19}"
hp_car "${p0}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=cadr
RPC=18; ACTION=call; return
;;
18)
eval "sht20=\"\$F$((FP+NP+0))\""
sht22="${R}"
hp_car "${p0}"
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=caddr
RPC=19; ACTION=call; return
;;
19)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
CALLEE=cadr
RPC=20; ACTION=call; return
;;
20)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht25="${R}"
hp_car "${p0}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
CALLEE=caddr
RPC=21; ACTION=call; return
;;
21)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
CALLEE=caddr
RPC=22; ACTION=call; return
;;
22)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${sht20}\""
eval "F$((NFP+2))=\"\${sht25}\""
eval "F$((NFP+3))=\"\${sht28}\""
eval "F$((NFP+4))=\"\${p3}\""
eval "F$((NFP+5))=\"\${p4}\""
eval "F$((NFP+6))=\"\${p5}\""
CALLEE=compile_fn
RPC=23; ACTION=call; return
;;
23)
eval "sht20=\"\$F$((FP+NP+0))\""
sht29="${R}"
sht30="${sht29}"
hp_cdr "${sht30}"
sht31="${R}"
sht32="${sht31}"
hp_car "${sht30}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=write_segs
RPC=24; ACTION=call; return
;;
24)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht34="${R}"
hp_car "${p0}"
sht35="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht35}\""
CALLEE=cadr
RPC=25; ACTION=call; return
;;
25)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
CALLEE=resid_bind
RPC=26; ACTION=call; return
;;
26)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=show
RPC=27; ACTION=call; return
;;
27)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
hp_cons "${sht38}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
append_lines "${p2}" "${sht39}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht40="${R}"
hp_cdr "${p0}"
sht41="${R}"
eval "F$((FP+0))=\"\${sht41}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht32}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
28)
sht43="${R}"
if [ "${sht43}" != NIL ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
29)
hp_cdr "${p0}"
sht44="${R}"
eval "F$((FP+0))=\"\${sht44}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
30)
hp_car "${p0}"
sht45="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht45}\""
CALLEE=show
RPC=31; ACTION=call; return
;;
31)
eval "p2=\"\$F$((FP+NP+0))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${sht46}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
sht47="${R}"
append_lines "${p2}" "${sht47}"
sht48="${R}"
hp_cdr "${p0}"
sht49="${R}"
eval "F$((FP+0))=\"\${sht49}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_atom_constzzQ=1
atom_constzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_atom_constzzQ))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=def_lambdazzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
if [ "${p0#P:}" != "${p0}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:define" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
5)
R="NIL"; ACTION=ret; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
7)
R="NIL"; ACTION=ret; return
;;
8)
sht2="${R}"
if [ "${sht2#P:}" != "${sht2}" ]; then
sht3="S:t"
else
sht3="NIL"
fi
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=not
RPC=9; ACTION=call; return
;;
9)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_const_inits=3
const_inits() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_const_inits))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=atom_constzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht18="${R}"
eval "F$((FP+0))=\"\${sht18}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
sht4="T:${sht3#??}"
hp_car "${p0}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=7; ACTION=call; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${sht7}\""
STGV="NIL"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=lval
RPC=9; ACTION=call; return
;;
9)
eval "sht4=\"\$F$((FP+NP+0))\""
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=vref
RPC=10; ACTION=call; return
;;
10)
eval "sht4=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="T:=${sht10#??}"
sht12="T:${sht4#??}${sht11#??}"
sht13="T:G_${sht12#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
sht14="${R}"
hp_cdr "${p0}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=const_inits
RPC=12; ACTION=call; return
;;
12)
eval "sht14=\"\$F$((FP+NP+0))\""
sht16="${R}"
hp_cons "${sht14}" "${sht16}"
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
esac; }
SIZE_memzzQ=2
memzzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_memzzQ))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
hp_cdr "${p1}"
sht1="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_set_add=2
set_add() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_set_add))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
hp_cons "${p0}" "${p1}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_lv_names=2
lv_names() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_lv_names))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=lv_names
RPC=3; ACTION=call; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_fv_binds=5
fv_binds() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv_binds))
NP=3
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv
RPC=3; ACTION=call; return
;;
2)
R="${p2}"; ACTION=ret; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_fv_list=5
fv_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv_list))
NP=3
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv
RPC=3; ACTION=call; return
;;
2)
R="${p2}"; ACTION=ret; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_fv=5
fv() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv))
NP=3
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
if [ "${p0#S:}" != "${p0}" ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
3)
R="${p2}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
hp_cdr "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=7; ACTION=call; return
;;
6)
hp_car "${p0}"
sht8="${R}"
if [ "${sht8}" = "S:let" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+0))=\"\${sht4}\""
eval "F$((FP+1))=\"\${sht7}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
8)
hp_cdr "${p0}"
sht9="${R}"
hp_cdr "${sht9}"
sht10="${R}"
hp_car "${sht10}"
sht11="${R}"
hp_cdr "${p0}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=lv_names
RPC=10; ACTION=call; return
;;
9)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv_list
RPC=13; ACTION=call; return
;;
10)
eval "sht11=\"\$F$((FP+NP+0))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht11=\"\$F$((FP+NP+0))\""
sht15="${R}"
hp_cdr "${p0}"
sht16="${R}"
hp_car "${sht16}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv_binds
RPC=12; ACTION=call; return
;;
12)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+0))=\"\${sht11}\""
eval "F$((FP+1))=\"\${sht15}\""
eval "F$((FP+2))=\"\${sht18}\""
PC=0; ACTION=tail; return
;;
13)
sht19="${R}"
R="${sht19}"; ACTION=ret; return
;;
14)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=16; ACTION=call; return
;;
15)
R="${p2}"; ACTION=ret; return
;;
16)
sht20="${R}"
if [ "${sht20}" != NIL ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="${p2}"; ACTION=ret; return
;;
18)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=set_add
RPC=19; ACTION=call; return
;;
19)
sht21="${R}"
R="${sht21}"; ACTION=ret; return
;;
esac; }
SIZE_keep_bound=3
keep_bound() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_keep_bound))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_bound
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
6)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_lift_list=7
lift_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_lift_list))
NP=3
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift
RPC=3; ACTION=call; return
;;
2)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht23}"
eval "p0=\"\$F$((FP+NP+0))\""
sht24="${R}"
hp_cons "${p0}" "${sht24}"
sht25="${R}"
R="${sht25}"; ACTION=ret; return
;;
3)
sht1="${R}"
sht2="${sht1}"
hp_cdr "${p0}"
sht3="${R}"
hp_cdr "${sht2}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht6}\""
CALLEE=lift_list
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="${sht7}"
hp_car "${sht2}"
sht9="${R}"
hp_car "${sht8}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht9}" "${sht10}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht11="${R}"
hp_cdr "${sht2}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
hp_cdr "${sht8}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht15}\""
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht16="${R}"
hp_cdr "${sht8}"
sht17="${R}"
hp_cdr "${sht17}"
sht18="${R}"
hp_car "${sht18}"
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht19}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
hp_cons "${sht16}" "${sht20}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht11}" "${sht21}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
esac; }
SIZE_lift=12
lift() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_lift))
NP=3
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht51="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht51}"
eval "p0=\"\$F$((FP+NP+0))\""
sht52="${R}"
hp_cons "${p0}" "${sht52}"
sht53="${R}"
R="${sht53}"; ACTION=ret; return
;;
3)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
sht7="${sht6}"
hp_cdr "${p0}"
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
hp_car "${sht9}"
sht10="${R}"
hp_cdr "${p0}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=7; ACTION=call; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift_list
RPC=12; ACTION=call; return
;;
7)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
eval "F$((NFP+1))=\"\${sht13}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
sht14="${R}"
sht15="${sht14}"
hp_car "${sht15}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
eval "F$((NFP+1))=\"\${sht7}\""
STGV="NIL"
eval "F$((NFP+2))=\"\$STGV\""
CALLEE=fv
RPC=9; ACTION=call; return
;;
9)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_bound
RPC=10; ACTION=call; return
;;
10)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
hp_cdr "${sht15}"
sht20="${R}"
hp_cdr "${sht20}"
sht21="${R}"
hp_car "${sht21}"
sht22="${R}"
sht23="T:${sht22#??}"
sht24="T:__lam${sht23#??}"
sht25="S:${sht24#??}"
sht26="${sht25}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht26}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "S:quote" "${sht27}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht28}" "${sht19}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "S:make-closure" "${sht29}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht30="${R}"
hp_cdr "${sht15}"
sht31="${R}"
hp_car "${sht31}"
sht32="${R}"
hp_car "${sht15}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht30}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht19}\""
eval "F$((FP+NP+7))=\"\${sht15}\""
eval "F$((FP+NP+8))=\"\${sht7}\""
hp_cons "${sht33}" "NIL"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht30=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht19=\"\$F$((FP+NP+6))\""
eval "sht15=\"\$F$((FP+NP+7))\""
eval "sht7=\"\$F$((FP+NP+8))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht19}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht7}\""
hp_cons "${sht19}" "${sht34}"
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht19=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht7=\"\$F$((FP+NP+7))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "${sht7}" "${sht35}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "S:clambda" "${sht36}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "${sht37}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht26}" "${sht38}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "S:define" "${sht39}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht40}" "NIL"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht41}\""
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
sht42="${R}"
hp_cdr "${sht15}"
sht43="${R}"
hp_cdr "${sht43}"
sht44="${R}"
hp_car "${sht44}"
sht45="${R}"
sht46="I:$(( ${sht45#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht46}" "NIL"
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
hp_cons "${sht42}" "${sht47}"
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht30}" "${sht48}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
12)
sht50="${R}"
R="${sht50}"; ACTION=ret; return
;;
esac; }
SIZE_lift_program=9
lift_program() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lift_program))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
sht1="${sht0}"
if [ "${sht1#P:}" != "${sht1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${sht1}"
sht3="${R}"
if [ "${sht3}" = "S:define" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
4)
sht2="NIL"
PC=5; ACTION=jump; return
;;
5)
if [ "${sht2}" != NIL ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
6)
hp_cdr "${sht1}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
hp_car "${sht6}"
sht7="${R}"
if [ "${sht7#P:}" != "${sht7}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
7)
sht4="NIL"
PC=8; ACTION=jump; return
;;
8)
sht2="${sht4}"
PC=5; ACTION=jump; return
;;
9)
hp_cdr "${sht1}"
sht9="${R}"
hp_cdr "${sht9}"
sht10="${R}"
hp_car "${sht10}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
if [ "${sht12}" = "S:lambda" ]; then
sht13="S:t"
else
sht13="NIL"
fi
sht8="${sht13}"
PC=11; ACTION=jump; return
;;
10)
sht8="NIL"
PC=11; ACTION=jump; return
;;
11)
sht4="${sht8}"
PC=8; ACTION=jump; return
;;
12)
hp_cdr "${sht1}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
sht16="${sht15}"
hp_cdr "${sht1}"
sht17="${R}"
hp_cdr "${sht17}"
sht18="${R}"
hp_car "${sht18}"
sht19="${R}"
hp_cdr "${sht19}"
sht20="${R}"
hp_car "${sht20}"
sht21="${R}"
sht22="${sht21}"
hp_cdr "${sht1}"
sht23="${R}"
hp_cdr "${sht23}"
sht24="${R}"
hp_car "${sht24}"
sht25="${R}"
hp_cdr "${sht25}"
sht26="${R}"
hp_cdr "${sht26}"
sht27="${R}"
hp_car "${sht27}"
sht28="${R}"
sht29="${sht28}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht22}\""
eval "F$((NFP+2))=\"\${p1}\""
CALLEE=lift
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lift_program
RPC=17; ACTION=call; return
;;
14)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht30="${R}"
sht31="${sht30}"
hp_car "${sht31}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht32}" "NIL"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht22}" "${sht33}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "S:lambda" "${sht34}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht35}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht16}" "${sht36}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "S:define" "${sht37}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht38="${R}"
hp_cdr "${sht31}"
sht39="${R}"
hp_car "${sht39}"
sht40="${R}"
hp_cdr "${p0}"
sht41="${R}"
hp_cdr "${sht31}"
sht42="${R}"
hp_cdr "${sht42}"
sht43="${R}"
hp_car "${sht43}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht40}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
eval "F$((NFP+1))=\"\${sht44}\""
CALLEE=lift_program
RPC=15; ACTION=call; return
;;
15)
eval "sht40=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
eval "F$((NFP+1))=\"\${sht45}\""
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht38}" "${sht46}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht47="${R}"
R="${sht47}"; ACTION=ret; return
;;
17)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht1}" "${sht49}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht50="${R}"
R="${sht50}"; ACTION=ret; return
;;
esac; }
SIZE_mkclo_caps=2
mkclo_caps() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mkclo_caps))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=mkclo_caps
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht2}" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht0}" "${sht3}"
sht4="${R}"
hp_cons "S:cons" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_cap_loads_go=3
cap_loads_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cap_loads_go))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p1#??}"
sht1="T:${sht0#??}=!R!"
sht2="T:p${sht1#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=qset
RPC=3; ACTION=call; return
;;
3)
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
STGV="T:_cl=!R:~2!"
eval "F$((NFP+0))=\"\$STGV\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "${sht4}" "NIL"
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "T:call rdfield.cmd cdr !_cl!" "${sht5}"
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
hp_cons "T:call rdfield.cmd car !_cl!" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
sht10="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht8}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${sht10}\""
CALLEE=cap_loads_go
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
sht11="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${sht11}\""
CALLEE=append
RPC=6; ACTION=call; return
;;
6)
sht12="${R}"
R="${sht12}"; ACTION=ret; return
;;
esac; }
SIZE_cap_loads=3
cap_loads() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cap_loads))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
NFP=$FTOP
STGV="T:_cl=!R:~2!"
eval "F$((NFP+0))=\"\$STGV\""
CALLEE=qset
RPC=3; ACTION=call; return
;;
3)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=cap_loads_go
RPC=4; ACTION=call; return
;;
4)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cons "${sht0}" "${sht1}"
sht2="${R}"
hp_cons "T:call rdfield.cmd cdr !CLO!" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_callees=4
callees() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_callees))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
R="${p1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1#S:}" != "${sht1}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=set_add
RPC=8; ACTION=call; return
;;
6)
sht2="${p1}"
PC=7; ACTION=jump; return
;;
7)
sht5="${sht2}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${p0}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=callees
RPC=9; ACTION=call; return
;;
8)
sht4="${R}"
sht2="${sht4}"
PC=7; ACTION=jump; return
;;
9)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=callees_list
RPC=10; ACTION=call; return
;;
10)
eval "sht5=\"\$F$((FP+NP+0))\""
sht9="${R}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_callees_list=3
callees_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_callees_list))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=callees
RPC=3; ACTION=call; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_defnames=2
defnames() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_defnames))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht7}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=defnames
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht3}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_keep_defined=3
keep_defined() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_keep_defined))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_defined
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
6)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_fn_body=1
fn_body() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fn_body))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=caddr
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_build_adj=3
build_adj() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_build_adj))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+0))=\"\${sht12}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
hp_car "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=fn_body
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=callees
RPC=8; ACTION=call; return
;;
8)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_defined
RPC=9; ACTION=call; return
;;
9)
eval "sht3=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${sht3}" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=build_adj
RPC=10; ACTION=call; return
;;
10)
eval "sht8=\"\$F$((FP+NP+0))\""
sht10="${R}"
hp_cons "${sht8}" "${sht10}"
sht11="${R}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_all_inzzQ=2
all_inzzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_all_inzzQ))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+0))=\"\${sht2}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
5)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_clean_pass=6
clean_pass() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_clean_pass))
NP=3
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "${p1}" "${p2}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
sht3="${sht2}"
hp_car "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
sht6="${sht5}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht7="${R}"
if [ "${sht7}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
5)
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=all_inzzQ
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht9="${R}"
if [ "${sht9}" != NIL ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
hp_cdr "${p0}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "${sht3}" "${p1}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht11="${R}"
eval "F$((FP+0))=\"\${sht10}\""
eval "F$((FP+1))=\"\${sht11}\""
STGV="S:t"
eval "F$((FP+2))=\"\$STGV\""
PC=0; ACTION=tail; return
;;
8)
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+0))=\"\${sht12}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_clean_fix=2
clean_fix() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_clean_fix))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
STGV="NIL"
eval "F$((NFP+2))=\"\$STGV\""
CALLEE=clean_pass
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
hp_car "${sht1}"
sht3="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
3)
hp_car "${sht1}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_elide_of=1
elide_of() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_elide_of))
NP=1
case $PC in
0)
NFP=$FTOP
STGV="T:\$ELIDE"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p0}\""
CALLEE=assoc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
hp_cdr "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_gfns_of=1
gfns_of() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_gfns_of))
NP=1
case $PC in
0)
NFP=$FTOP
STGV="T:\$GFNS"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p0}\""
CALLEE=assoc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
hp_cdr "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_compile_program=7
compile_program() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_compile_program))
NP=3
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=mexpand_program
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=lift_program
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
sht2="${sht1}"
sht3="T:${p1#??}/_consts.cmd"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=const_inits
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
write_lines "${sht3}" "${sht4}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
write_lines "${p2}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=defnames
RPC=4; ACTION=call; return
;;
4)
eval "p2=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"I:0\""
STGV="NIL"
eval "F$((NFP+4))=\"\$STGV\""
eval "F$((NFP+5))=\"\${sht7}\""
CALLEE=cp
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
