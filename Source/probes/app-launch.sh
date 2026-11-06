#!/bin/sh
# (On Mavericks guests, to its having finished launching: see finished_launching.)
# The time from `open -a` to an application's first window, cold (its first launch in this boot) and warm (quit and launched
# again, twice), per application. For boot-matrix's program=. Prints one line per launch and one summary per application. 10 s of
# quiet comes first, so a boot's own work stays out of it as far as it can.
sleep 10
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
cat > /tmp/app-launch.py <<'EOF'
import os, subprocess, sys, time
import AppKit
import Quartz

APPS = ["Calculator", "TextEdit", "Notes", "Maps", "Safari", "System Preferences", "Keynote"]
PLACES = {"Keynote": "/Applications/iWork '09/Keynote.app"}

# Mavericks guests give no window list to anything we can start, with no session behind us. There, the time is to the application saying it has finished launching.
def finished_launching(app):
    AppKit.NSRunLoop.currentRunLoop().runUntilDate_(AppKit.NSDate.dateWithTimeIntervalSinceNow_(0.01))
    for a in AppKit.NSWorkspace.sharedWorkspace().runningApplications():
        if a.localizedName() == app and a.isFinishedLaunching():
            return True
    return False

def has_window(app):
    windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    if windows is None:
        return finished_launching(app)
    for w in windows:
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
    # Nothing started from here reaches the window server on these guests, not even a LaunchAgent: only a process of the login session. So Terminal starts it.
    printf '#!/bin/sh\n/usr/bin/python /tmp/app-launch.py > /tmp/app-launch.out 2>&1\necho ALLDONE >> /tmp/app-launch.out\n' > /tmp/app-launch.command
    chmod 755 /tmp/app-launch.command
    /bin/launchctl bsexec "$(pgrep -x loginwindow | head -1)" /usr/bin/sudo -u "$u" /usr/bin/open -a Terminal /tmp/app-launch.command </dev/null
    n=0
    until grep -q ALLDONE /tmp/app-launch.out 2>/dev/null || [ $n -ge 900 ]; do sleep 1; n=$((n+1)); done
    cat /tmp/app-launch.out
    ;;
  *) /bin/launchctl asuser "$id" /usr/bin/sudo -u "$u" /usr/bin/python /tmp/app-launch.py </dev/null 2>&1 ;;
esac
