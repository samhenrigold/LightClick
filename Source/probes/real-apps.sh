#!/bin/sh
# Real applications under the engine, since boots alone missed 32-bit processes breaking at several vCPUs. For boot-matrix's
# program=, at more than one vCPU: an i386 launch, over and over, then Keynote if the guest has it. Exits nonzero if one died.
ok=0; bad=0; i=0
while [ $i -lt 30 ]; do
  o=$(/usr/bin/arch -i386 /usr/bin/python2.7 -c 'print "ok32"' 2>&1); rc=$?
  if [ "$o" = ok32 ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "run $i rc=$rc: $o" | head -3; fi
  i=$((i+1))
done
echo "i386 python ok=$ok bad=$bad"
K=""
for k in /Applications/Keynote.app "/Applications/iWork '09/Keynote.app"; do
  [ -d "$k" ] && K="$k"
done
if [ -z "$K" ]; then echo "RESULT python_bad=$bad keynote=absent"; [ "$bad" = 0 ]; exit; fi
echo "keynote at $K"; file "$K/Contents/MacOS/Keynote" | head -3
u=$(stat -f%Su /dev/console); lw=$(pgrep -x loginwindow | head -1)
/bin/launchctl bsexec "$lw" /usr/bin/sudo -u "$u" /usr/bin/open -a "$K" </dev/null; echo "open rc=$?"
sleep 40
if pgrep -lx Keynote; then running=1; else echo "Keynote NOT RUNNING"; running=0; fi
grep -E 'crashed|SIG[A-Z]+|Abort trap|Segmentation' /var/log/system.log | grep -iE 'keynote|python' | tail -5 | cut -c1-170
echo "RESULT python_bad=$bad keynote=$running"
[ "$bad" = 0 ] && [ "$running" = 1 ]
