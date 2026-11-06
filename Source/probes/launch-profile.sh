#!/bin/sh
# Where an application's start goes, seen from inside the guest: a dtrace profile and disk totals over each launch, cold then warm.
# For boot-matrix's program=. Set APPS to choose. Needs dtrace, so no System Integrity Protection in the way.
sleep 10
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
cat > /tmp/p.d <<'EOF'
#pragma D option quiet
profile-997 { @kind[arg0 ? "kernel" : "user"] = count(); }
profile-997 /arg0/ { @kf[func(arg0)] = count(); }
profile-997 { @who[execname, arg0 ? "k" : "u"] = count(); }
io:::start { st[arg0] = timestamp; @ios = count(); @bytes = sum(args[0]->b_bcount); }
io:::done /st[arg0]/ { @lat = sum(timestamp - st[arg0]); @maxlat = max(timestamp - st[arg0]); st[arg0] = 0; }
dtrace:::END {
    printa("  samples %s %@d\n", @kind);
    trunc(@who, 14); printa("  who %s %s %@d\n", @who);
    trunc(@kf, 14); printa("  kernel %a %@d\n", @kf);
    printa("  io count %@d\n", @ios); printa("  io bytes %@d\n", @bytes); printa("  io total latency ns %@d\n", @lat); printa("  io worst ns %@d\n", @maxlat);
}
EOF
cat > /tmp/launch-profile.py <<EOF
import os, signal, subprocess, sys, time
import Quartz
USER = "$u"
APPS = "${APPS:-Calculator,Safari,Keynote}".split(",")
PLACES = {"Keynote": "/Applications/iWork '09/Keynote.app"}
def has_window(app):
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerName") == app and w.get("kCGWindowLayer") == 0:
            b = w.get("kCGWindowBounds") or {}
            if b.get("Width", 0) > 100 and b.get("Height", 0) > 100:
                return True
    return False
for app in APPS:
    path = PLACES.get(app, "/Applications/%s.app" % app)
    if not os.path.isdir(path):
        print("%s absent" % app)
        continue
    for kind in ("cold", "warm"):
        d = subprocess.Popen(["/usr/sbin/dtrace", "-q", "-s", "/tmp/p.d"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(2)
        start = time.time()
        subprocess.call(["/usr/bin/sudo", "-u", USER, "/usr/bin/open", "-a", path])
        while time.time() - start < 40 and not has_window(app):
            time.sleep(0.02)
        took = time.time() - start
        d.send_signal(signal.SIGINT)
        out = d.communicate()[0]
        print("=== %s %s %.2f s" % (app, kind, took))
        print(out)
        sys.stdout.flush()
        time.sleep(2)
        subprocess.call(["/usr/bin/sudo", "-u", USER, "/usr/bin/osascript", "-e", 'tell application "%s" to quit' % app])
        time.sleep(3)
        subprocess.call(["/usr/bin/killall", "-9", app], stderr=open(os.devnull, "w"))
        time.sleep(2)
EOF
case "$(sw_vers -productVersion)" in
  10.9*|10.8*|10.7*|10.6*)
    cat > /tmp/join-session.py <<'EOF'
import ctypes, os, subprocess, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
me = ctypes.c_uint.in_dll(libc, "mach_task_self_").value
finder = int(subprocess.check_output(["/usr/bin/pgrep", "-x", "Finder"]).split()[0])
task, bootstrap, session = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
token, count = (ctypes.c_uint * 8)(), ctypes.c_uint(8)
TASK_AUDIT_TOKEN, TASK_BOOTSTRAP_PORT = 15, 4
if libc.task_for_pid(me, finder, ctypes.byref(task)) or libc.task_info(task, TASK_AUDIT_TOKEN, token, ctypes.byref(count)) or libc.task_get_special_port(task, TASK_BOOTSTRAP_PORT, ctypes.byref(bootstrap)):
    sys.exit("could not read Finder's task")
if libc.audit_session_port(token[6], ctypes.byref(session)) == -1 or libc.audit_session_join(session) == -1:
    sys.exit("could not join Finder's session")
libc.task_set_special_port(me, TASK_BOOTSTRAP_PORT, bootstrap)
os.execv(sys.argv[1], sys.argv[1:])
EOF
    /usr/bin/python /tmp/join-session.py /usr/bin/python /tmp/launch-profile.py </dev/null 2>&1
    ;;
  *) /bin/launchctl asuser "$id" /usr/bin/python /tmp/launch-profile.py </dev/null 2>&1 ;;
esac
