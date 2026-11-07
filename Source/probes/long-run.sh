#!/bin/sh
# A long session: applications opened and closed in numbers, i386 ones too, a JIT at work, memory pressure, and checks for wrong results and stalls throughout.
# For boot-matrix's program=, with limit= past LONG_RUN_SECONDS. Exits nonzero on a wrong result or an application that never got a window.
LONG_RUN_SECONDS=2400
sleep 10
u=$(stat -f%Su /dev/console); id=$(id -u "$u")
cat > /tmp/long-run-check.py <<'EOF'
# The same answer every time, on either architecture, from arithmetic, hashing and compression.
import hashlib, struct, sys, zlib
out, h, x = [], hashlib.sha256(), 0x123456789
for i in range(60000):
    x = (x * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
    out.append(struct.pack("<Q", x >> (x & 15)))
data = b"".join(out)
for i in range(8):
    data = zlib.decompress(zlib.compress(data, 6)) + hashlib.sha256(data).digest()
    h.update(data)
print(h.hexdigest() + " %.6f" % sum(float(j) ** 0.5 for j in range(2000)))
EOF
cat > /tmp/long-run.html <<'EOF'
<title>long run</title><canvas id=c width=600 height=400></canvas><script>
// Keeps the JIT compiling and discarding: new functions all the time, each hot for a moment.
var g = document.getElementById("c").getContext("2d"), n = 0;
function step() {
  var f = new Function("a", "var s=" + n + ";for(var i=0;i<200000;i++){s=(s*31+i^a)|0}return s");
  var s = f(n++);
  g.fillStyle = "rgb(" + (s & 255) + "," + ((s >> 8) & 255) + "," + ((s >> 16) & 255) + ")";
  g.fillRect(n % 600, n % 400, 40, 40);
  setTimeout(step, 10);
}
step();
</script>
EOF
cat > /tmp/long-run.py <<EOF
import mmap, os, random, subprocess, sys, threading, time
import Quartz
LONG_RUN = $LONG_RUN_SECONDS
PLACES = {"Keynote": "/Applications/iWork '09/Keynote.app", "QuickTime Player": "/Applications/QuickTime Player.app"}
CANDIDATES = ["Calculator", "TextEdit", "Notes", "Maps", "Safari", "System Preferences", "Keynote", "Contacts", "Calendar", "Dictionary", "Chess", "Stickies", "Font Book"]
DEVNULL = open(os.devnull, "w")
start = time.time()
lock = threading.Lock()
wrong = []
pressing = [False]
def say(text):
    with lock:
        print("%7.1f %s" % (time.time() - start, text))
        sys.stdout.flush()
def path_of(app):
    return PLACES.get(app, "/Applications/%s.app" % app)
def done():
    return time.time() - start > LONG_RUN

def heartbeat():
    last = time.time()
    while not done():
        time.sleep(0.1)
        now = time.time()
        if now - last > 2:
            say("STALL %.1f s with nothing else to do but wake up%s" % (now - last, ", under pressure" if pressing[0] else ""))
        last = now

def checker(arch):
    expected, runs = None, 0
    while not done():
        p = subprocess.Popen(["/usr/bin/arch", "-" + arch, "/usr/bin/python", "/tmp/long-run-check.py"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        got = p.communicate()[0].strip()
        runs += 1
        if p.returncode:
            if expected is None:
                say("no %s python: %s" % (arch, got[:200]))
                return
            wrong.append(arch)
            say("WRONG %s exit %s: %s" % (arch, p.returncode, got[:400]))
        elif expected is None:
            expected = got
            say("%s answers %s" % (arch, got))
        elif got != expected:
            wrong.append(arch)
            say("WRONG %s got %s" % (arch, got))
    say("%s checks: %d" % (arch, runs))

def file_check():
    block, runs = os.urandom(1 << 20), 0
    while not done():
        with open("/tmp/long-run.data", "wb") as f:
            for i in range(128):
                f.write(block)
            f.flush()
            os.fsync(f.fileno())
        time.sleep(60)
        with open("/tmp/long-run.data", "rb") as f:
            for i in range(128):
                if f.read(1 << 20) != block:
                    wrong.append("file")
                    say("WRONG file read back differs at MB %d" % i)
                    break
        runs += 1
    say("file checks: %d" % runs)

def pressure():
    pressing[0] = True
    # More than the guest has, in pages that won't compress, so that they go out to disk and come back. Each says which it is.
    size = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"])) * 11 / 10
    noise = os.urandom(1 << 20)
    salt = int(time.time()) & 0xFFFFF
    t = time.time()
    m = mmap.mmap(-1, size)
    pages = size / 4096 - 4
    for i in range(0, pages, 4):
        o = (i * 7 + salt) % ((1 << 20) - 16384)
        m[i * 4096:i * 4096 + 16384] = noise[o:o + 16384]
        if done():
            pages = i
            break
    wrote = time.time() - t
    for i in range(0, pages, 4):
        o = (i * 7 + salt) % ((1 << 20) - 16384)
        if m[i * 4096:i * 4096 + 16384] != noise[o:o + 16384]:
            wrong.append("memory")
            say("WRONG memory at page %d" % i)
            break
        if done():
            break
    m.close()
    pressing[0] = False
    say("pressure %d MB: wrote in %.0f s, checked in %.0f s" % (size >> 20, wrote, time.time() - t - wrote))
    say(" ".join(l.strip() for l in subprocess.check_output(["/usr/bin/vm_stat"]).splitlines() if "ageouts" in l or "wapouts" in l))

def has_window(app):
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerName") == app and w.get("kCGWindowLayer") in (0, 8): # 8: Keynote '09's theme chooser, a floating panel it won't quit from
            b = w.get("kCGWindowBounds") or {}
            if b.get("Width", 0) > 100 and b.get("Height", 0) > 100:
                return True
    return False
def launch(app):
    t = time.time()
    subprocess.call(["/usr/bin/open", "-a", path_of(app)])
    while time.time() - t < 60:
        if has_window(app):
            return time.time() - t
        time.sleep(0.05)
    return None
def quit_app(app):
    subprocess.call(["/usr/bin/osascript", "-e", 'tell application "%s" to quit' % app], stdout=DEVNULL, stderr=DEVNULL)
    for _ in range(50):
        if subprocess.call(["/usr/bin/pgrep", "-x", app], stdout=DEVNULL):
            return True
        time.sleep(0.1)
    subprocess.call(["/usr/bin/killall", "-9", app], stderr=DEVNULL)
    return False

apps = [a for a in CANDIDATES if os.path.isdir(path_of(a))]
say("apps: " + ", ".join(apps))
threads = [threading.Thread(target=f, args=a) for f, a in ((heartbeat, ()), (checker, ("x86_64",)), (checker, ("i386",)), (file_check, ()))]
for t in threads:
    t.daemon = True
    t.start()
random.seed(1)
cycle, nowindow, stuck, times = 0, [], 0, {}
while not done():
    cycle += 1
    chosen = random.sample(apps, min(len(apps), random.randint(3, 6)))
    if "Keynote" in apps and "Keynote" not in chosen and cycle % 2:
        chosen.append("Keynote")
    press = None
    if cycle % 8 == 4:
        press = threading.Thread(target=pressure)
        press.daemon = True
        press.start()
    for app in chosen:
        took = launch(app)
        if took is None:
            nowindow.append(app)
            say("NO WINDOW %s in 60 s. Windows: %s" % (app, sorted(set((w.get("kCGWindowOwnerName"), w.get("kCGWindowLayer")) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []))))
            say(subprocess.check_output("/bin/ps -axo pid,state,etime,time,command | /usr/bin/grep -v grep | /usr/bin/grep -e 'Contents/MacOS' -e ReportCrash | /usr/bin/cut -c1-110", shell=True))
        else:
            times.setdefault(app, []).append(took)
            if took > 15:
                say("SLOW %s %.1f s%s" % (app, took, " under pressure" if press and press.is_alive() else ""))
    if "Safari" in chosen:
        subprocess.call(["/usr/bin/open", "-a", path_of("Safari"), "/tmp/long-run.html"])
    time.sleep(random.uniform(1, 20))
    for app in chosen:
        if not quit_app(app):
            stuck += 1
            say("KILLED %s, it wouldn't quit" % app)
    if press:
        press.join()
    say("cycle %d: %s" % (cycle, ",".join(chosen)))
for t in threads:
    t.join(600)
for app in sorted(times):
    t = sorted(times[app])
    say("LAUNCHES %s n=%d median %.2f worst %.2f, first half %.2f, second half %.2f" % (app, len(t), t[len(t) // 2], t[-1], sum(times[app][:len(t) // 2]) / max(1, len(t) // 2), sum(times[app][len(t) // 2:]) / max(1, len(t) - len(t) // 2)))
say("SUMMARY cycles %d, no window %d, killed %d, wrong %d" % (cycle, len(nowindow), stuck, len(wrong)))
sys.exit(1 if wrong or nowindow else 0)
EOF
chmod 644 /tmp/long-run.py /tmp/long-run-check.py /tmp/long-run.html
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
    /usr/bin/python /tmp/join-session.py /usr/bin/sudo -u "$u" /usr/bin/python /tmp/long-run.py </dev/null 2>&1
    ;;
  *) /bin/launchctl asuser "$id" /usr/bin/sudo -u "$u" /usr/bin/python /tmp/long-run.py </dev/null 2>&1 ;;
esac
