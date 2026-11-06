#!/bin/sh
# A few real applications on a newer guest, for boot-matrix's program=: each launched from /Applications and still running 20 s
# later, plus an i386 launch if the guest can do one. Exits nonzero if one died.
sw_vers -productVersion
bad=0
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
echo "console user $u"
for a in Calculator TextEdit Safari Maps Notes "System Preferences"; do
  [ -d "/Applications/$a.app" ] || { echo "$a absent"; continue; }
  /bin/launchctl asuser "$id" /usr/bin/sudo -u "$u" /usr/bin/open -a "$a" </dev/null; rc=$?
  sleep 20
  if pgrep -x "$a" >/dev/null; then echo "$a running"; else echo "$a NOT RUNNING, open rc=$rc"; bad=$((bad+1)); fi
done
ls -d /Library/Logs/DiagnosticReports/* /Users/*/Library/Logs/DiagnosticReports/* 2>/dev/null | tail -6
if file -b /usr/bin/python2.7 | grep -q i386; then
  ok=0; fail=0; i=0
  while [ $i -lt 20 ]; do
    o=$(/usr/bin/arch -i386 /usr/bin/python2.7 -c 'print "ok32"' 2>&1); rc=$?
    if [ "$o" = ok32 ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "i386 run $i rc=$rc: $o" | head -2; fi
    i=$((i+1))
  done
  echo "i386 python ok=$ok bad=$fail"
  bad=$((bad+fail))
else
  echo "no i386 python: $(file -b /usr/bin/python2.7 | head -2 | tr '\n' ' ')"
  for f in /usr/bin/* /bin/*; do
    case "$(file -b "$f" 2>/dev/null)" in *"executable i386"*) echo "i386 executable: $f"; break;; esac
  done
fi
echo "RESULT bad=$bad"
[ "$bad" = 0 ]
