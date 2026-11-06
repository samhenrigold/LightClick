#!/bin/sh
# The time from `open -a` to an application's first window, cold (its first launch in this boot) and warm (quit and launched
# again, twice), per application. For boot-matrix's program=. Prints one line per launch and one summary per application. 10 s of
# quiet comes first, so a boot's own work stays out of it as far as it can.
sleep 10
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
cat > /tmp/app-launch.py <<'EOF'
import os, subprocess, sys, time
import Quartz

APPS = ["Calculator", "TextEdit", "Notes", "Maps", "Safari", "System Preferences", "Keynote"]
PLACES = {"Keynote": "/Applications/iWork '09/Keynote.app"}

def has_window(app):
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerName") == app and w.get("kCGWindowLayer") == 0:
            b = w.get("kCGWindowBounds") or {}
            if b.get("Width", 0) > 100 and b.get("Height", 0) > 100:
                return True
    return False

def launch(app, path):
    start = time.time()
    subprocess.call(["/usr/bin/open", "-a", path])
    while time.time() - start < 40:
        if has_window(app):
            return time.time() - start
        time.sleep(0.02)
    print("  windows then: %s" % sorted(set((w.get("kCGWindowOwnerName"), w.get("kCGWindowLayer")) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []))[:30])
    return None

def quit_app(app):
    subprocess.call(["/usr/bin/osascript", "-e", 'tell application "%s" to quit' % app])
    for _ in range(100):
        if subprocess.call(["/usr/bin/pgrep", "-x", app], stdout=open(os.devnull, "w")):
            return
        time.sleep(0.1)
    subprocess.call(["/usr/bin/killall", "-9", app])
    time.sleep(1)

bad = 0
for app in APPS:
    path = PLACES.get(app, "/Applications/%s.app" % app)
    if not os.path.isdir(path):
        print("%s absent" % app)
        continue
    times = []
    for n in range(3):
        t = launch(app, path)
        times.append(t)
        print("%s %s %s" % (app, "cold" if n == 0 else "warm", "NO WINDOW" if t is None else "%.2f s" % t))
        sys.stdout.flush()
        if t is None:
            bad += 1
        time.sleep(2)
        quit_app(app)
        time.sleep(2)
    warm = [t for t in times[1:] if t is not None]
    print("LAUNCH %s cold %s warm %s" % (app, "none" if times[0] is None else "%.2f" % times[0], "none" if not warm else "%.2f" % min(warm)))
    sys.stdout.flush()
sys.exit(1 if bad else 0)
EOF
chmod 644 /tmp/app-launch.py
case "$(sw_vers -productVersion)" in
  10.9*|10.8*|10.7*|10.6*)
    # launchctl asuser came in 10.10. WindowServer goes by a client's audit session, so join Finder's, as seamless-session-join.h does.
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
    /usr/bin/python /tmp/join-session.py /usr/bin/sudo -u "$u" /usr/bin/python /tmp/app-launch.py </dev/null 2>&1
    ;;
  *) /bin/launchctl asuser "$id" /usr/bin/sudo -u "$u" /usr/bin/python /tmp/app-launch.py </dev/null 2>&1 ;;
esac
