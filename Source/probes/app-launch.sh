#!/bin/sh
# The time from `open -a` to an application's first window, cold (its first launch in this boot) and warm (quit and launched
# again, twice), per application. For boot-matrix's program=. Prints one line per launch and one summary per application. 10 s of
# quiet comes first, so a boot's own work stays out of it as far as it can.
sleep 10
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
cat > /tmp/app-launch.py <<'EOF'
import os, signal, subprocess, sys, tempfile, time
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

def say(text):
    print(text)
    sys.stdout.flush()


def command(arguments, seconds, step):
    # Python 2.7 in period guests has no subprocess timeout. Files avoid a full stdout pipe blocking the child.
    say("STEP %s begin" % step)
    output = tempfile.TemporaryFile()
    child = subprocess.Popen(arguments, stdout=output, stderr=subprocess.STDOUT)
    deadline = time.time() + seconds
    while child.poll() is None and time.time() < deadline:
        time.sleep(0.05)
    timed_out = child.poll() is None
    if timed_out:
        say("TIMEOUT %s after %.1f s child=%d" % (step, seconds, child.pid))
        child.kill()  # Our Popen child only; never a process-name kill.
    reap_until = time.time() + 2
    while child.poll() is None and time.time() < reap_until:
        time.sleep(0.05)
    code = child.poll()
    if code is None:
        raise RuntimeError("%s child %d did not exit after SIGKILL" % (step, child.pid))
    output.seek(0)
    text = output.read(4096).decode("utf-8", "replace")
    output.close()
    say("STEP %s exit=%d%s%s" % (step, code, " timeout" if timed_out else "",
                                  (" output=" + text[:1000].strip()) if text else ""))
    return code, text, timed_out


def running(app):
    code, text, expired = command(["/usr/bin/pgrep", "-x", app], 3, "pids " + app)
    if expired or code not in (0, 1):
        raise RuntimeError("could not identify %s processes" % app)
    return set(int(pid) for pid in text.split())


def identity(pid):
    code, text, expired = command(["/bin/ps", "-p", str(pid), "-o", "stat=,lstart="], 3,
                                  "identity %d" % pid)
    if not expired and code == 1 and not text.strip():
        return None  # ps confirms that this PID no longer exists.
    fields = text.strip().split(None, 1)
    if expired or code != 0 or len(fields) != 2 or len(fields[1].split()) != 5:
        raise RuntimeError("could not verify process %d identity: exit=%d%s output=%s" %
                           (pid, code, " timeout" if expired else "", text[:1000].strip()))
    return None if fields[0].startswith("Z") else fields[1]


def launch(app, path):
    start = time.time()
    code, text, expired = command(["/usr/bin/open", "-a", path], 10, "open " + app)
    if code or expired:
        return None
    while time.time() - start < 40:
        if has_window(app):
            return time.time() - start
        time.sleep(0.02)
    say("TIMEOUT window %s after 40 s" % app)
    say("  windows then: %s" % sorted(set((w.get("kCGWindowOwnerName"), w.get("kCGWindowLayer")) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []))[:30])
    return None


def quit_app(app, owned):
    if not owned:
        return False
    # The probe refuses pre-existing app instances below. Remember start times as well as PIDs before signaling.
    code, text, expired = command(["/usr/bin/osascript", "-e", 'tell application "%s" to quit' % app],
                                  10, "quit " + app)
    deadline = time.time() + 5
    while time.time() < deadline:
        if not any(identity(pid) == stamp for pid, stamp in owned.items()):
            return not expired and code == 0
        time.sleep(0.1)
    say("FORCED QUIT %s owned_pids=%s" % (app, sorted(owned)))
    for pid, stamp in owned.items():
        if identity(pid) == stamp:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    time.sleep(0.2)
    return False

bad = 0
for app in APPS:
    path = PLACES.get(app, "/Applications/%s.app" % app)
    if not os.path.isdir(path):
        say("%s absent" % app)
        continue
    if running(app):
        say("FAIL %s already running; refusing to quit a process the probe did not launch" % app)
        bad += 1
        continue
    times = []
    for n in range(3):
        say("STEP launch %s %s" % (app, "cold" if n == 0 else "warm"))
        t = launch(app, path)
        owned = dict((pid, identity(pid)) for pid in running(app))
        owned = dict((pid, stamp) for pid, stamp in owned.items() if stamp is not None)
        times.append(t)
        print("%s %s %s" % (app, "cold" if n == 0 else "warm", "NO WINDOW" if t is None else "%.2f s" % t))
        sys.stdout.flush()
        if t is None:
            bad += 1
        time.sleep(2)
        if not quit_app(app, owned):
            say("FAIL %s graceful quit failed or required forced termination" % app)
            bad += 1
            break
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
