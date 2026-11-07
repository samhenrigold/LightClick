# Host side of scripts/seamless-try. Runs inside scripts/guest-bench, which supplies arguments, channel, request, source,
# stage and tag, and has already booted the clone.
import base64
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import threading
import time

results = source/'Build/seamless'
guest_tool = results/'seamless-guest'


def run(guest, command, timeout=600):
    """Runs the staged tool in the guest and shows its output, returning (status, stdout)."""
    result = request({'Executable': guest, 'Arguments': command}, timeout)
    output = result.get('Stdout') or ''
    print(output, end='' if output.endswith('\n') or not output else '\n', flush=True)
    problem = result.get('Stderr') or result.get('Error')
    if problem:
        print(f'# guest stderr: {str(problem)[:600]}', flush=True)
    return result.get('ExitCode'), output


def capture(name):
    """Saves the app's own whole guest frame, and returns its size in pixels."""
    result = request({'Action': 'capture'}, 180)
    frame = channel/'Frame.png'
    if not result.get('Captured') or not frame.exists():
        return None
    target = results/name
    shutil.copyfile(frame, target)
    listing = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(target)], text=True)
    return tuple(int(n) for n in re.findall(r'pixel(?:Width|Height): (\d+)', listing))


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def stream(seconds):
    print(f'== Phase 1: TextEdit streamed for {seconds} s', flush=True)
    guest = stage(guest_tool)
    port = free_port()
    png = results/f'{tag}.png'
    png.unlink(missing_ok=True)
    # The zoom button, on a 10.9 title bar. The guest reports whether it changed the bounds.
    viewer = subprocess.Popen([str(results/'seamless-viewer'), '--port', str(port), '--exit-after', str(seconds + 5),
                               '--png', str(png), '--test-input', '54,10'], stdout=subprocess.PIPE, text=True)
    status, _ = run(guest, ['program', '--port', str(port), '--seconds', str(seconds)])
    print(f'# guest exit {status}', flush=True)
    try:
        report, _ = viewer.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        viewer.terminate()
        report, _ = viewer.communicate()
    print(f'== Viewer on the host, exit {viewer.returncode}')
    print(report)
    if status == 3:
        print("The guest couldn't connect to 10.0.2.2. capture_mean above still stands. A clone with networkMode other "
              "than shared has no user-mode network; otherwise check that QEMU's slirp reaches host loopback. The next step "
              'is `guestfwd` into a private socket, as the design says.')
    size = capture(f'{tag}-guest-frame.png')
    print(f'# whole guest frame {size}, window as received {png if png.exists() else "(none)"}')


def session_pid(name):
    result = request({'Executable': '/usr/bin/pgrep', 'Arguments': ['-x', name]}, 60)
    return (result.get('Stdout') or '').strip()


# Past 4K, then the display transport's limit of 8192 in either direction, which is also the 256 MiB primary.
default_ladder = ['2560x1600', '3840x2160', '5120x2880', '6016x3384', '7680x4320', '8192x5120', '8192x8192']


def display(ladder):
    print('== Phase 2: how large a guest display works', flush=True)
    guest = stage(guest_tool)
    version = request({'Executable': '/usr/bin/uname', 'Arguments': ['-r']}, 60).get('Stdout', '')
    pre_metal = int(version.split('.')[0]) < 18
    print(f'# Darwin {version.strip()}: {"vmware-svga" if pre_metal else "PVG"}', flush=True)
    status, _ = run(guest, ['open-app', '--app', 'TextEdit'])
    if status != 0:
        raise SystemExit('TextEdit never opened')
    server = session_pid('WindowServer')
    table = [('size', 'offered', 'selected', 'host frame', 'placed', 'move ms', 'capture ms')]
    for step in ladder:
        width, height = (int(n) for n in step.split('x'))
        print(f'-- {step}', flush=True)
        requested = request({'Action': 'display-request', 'Width': width, 'Height': height,
                             'Density': 1 if pre_metal else 0}, 60)
        if 'Requested' not in requested:
            raise SystemExit(f'The app has no display-request; build it from this branch. {requested}')
        status, output = run(guest, ['display', '--width', str(width), '--height', str(height)])
        offered = status != 2
        selected = status == 0
        placed = moves = cost = ''
        if selected:
            # A far corner: if this shows in the host's frame, the whole of the display is real.
            placed_status, placed_output = run(guest, ['place', '--app', 'TextEdit', '--x', str(max(0, width-1000)), '--y',
                                                       str(max(0, height-900)), '--moves', '20'])
            placed = 'yes' if placed_status == 0 else f'no ({placed_status})'
            found = re.search(r'move_mean ([\d.]+)', placed_output)
            moves = found.group(1) if found else ''
            found = re.search(r'display_capture ([\d.]+)', output)
            cost = found.group(1) if found else ''
        size = capture(f'{tag}-{step}.png')
        now_server = session_pid('WindowServer')
        table.append((step, 'yes' if offered else 'NO', 'yes' if selected else f'NO ({status})',
                      f'{size[0]}x{size[1]}' if size else 'none', placed, moves, cost))
        if now_server != server:
            print(f'# ERROR WindowServer restarted during {step}: {server} became {now_server}')
            table.append((step, 'WindowServer restarted', '', '', '', '', ''))
            break
        if not selected or (size and size != (width, height)):
            print(f'# Stopping at {step}.')
            break
    print('== Results')
    widths = [max(len(row[i]) for row in table) for i in range(len(table[0]))]
    for row in table:
        print('  '.join(cell.ljust(widths[i]) for i, cell in enumerate(row)))
    print(f'# Frames are in {results}/{tag}-*.png. Check the TextEdit window is whole in the far corner of each.')
    # Slots on the largest size reached, as the design would place a second window.
    run(guest, ['place', '--app', 'TextEdit', '--slot', '1', '--slot-width', '1000', '--slot-height', '800'])
    capture(f'{tag}-slot.png')


def save(text):
    path = results/f'{tag}.txt'
    path.write_text(text)
    print(f'# Saved to {path}')


def input_probe():
    print('== What a test NSView in the guest receives, by mechanism', flush=True)
    guest = stage(results/'seamless-input-guest')
    status, output = run(guest, ['probe'], 900)
    print(f'# guest exit {status}', flush=True)
    save(output)


def input_live(seconds):
    print(f'== Your trackpad and keyboard to a test view in the guest, for {seconds} s. Use the window that appears.', flush=True)
    guest = stage(results/'seamless-input-guest')
    port = free_port()
    host = subprocess.Popen([str(results/'seamless-input-host'), '--port', str(port), '--seconds', str(seconds + 10)])
    status, output = run(guest, ['live', '--port', str(port), '--seconds', str(seconds)], seconds + 300)
    print(f'# guest exit {status}', flush=True)
    host.terminate()
    if status == 3:
        print("The guest couldn't connect to 10.0.2.2, so nothing reached it. `input` needs no network and still works.")
    save(output)


def windowserver_seconds():
    text = request({'Executable': '/bin/ps', 'Arguments': ['-axco', 'time=,command=']}, 60).get('Stdout', '')
    for line in text.splitlines():
        if line.split()[1:] == ['WindowServer']:
            minutes, seconds = line.split()[0].split(':')
            return int(minutes) * 60 + float(seconds)
    return 0


def tree(seconds, guest=None, hook=False, command=None):
    label = 'with the hook' if hook else 'by capture'
    print(f'== Every window of a demo app, {label}, for {seconds} s', flush=True)
    guest = guest or stage(guest_tool)
    port = free_port()
    name = f'{tag}-hook' if hook else tag
    prefix = results/f'{name}-window'
    for old in list(results.glob(f'{name}-window-*.png')) + list(results.glob(f'{name}-screen-*.png')):
        old.unlink()
    viewer = subprocess.Popen([str(results/'seamless-viewer'), '--tree', '--port', str(port), '--exit-after', str(seconds + 5),
                               '--png', str(prefix), '--screenshots', str(results/f'{name}-screen'),
                               # The demo's Anchor button, on a 10.9 title bar: it adds "clicked" to the title.
                               '--test-input', '365,156', '--test-motion'],
                              stdout=subprocess.PIPE, text=True)
    time.sleep(1)  # A busy host takes a moment to bind, and a guest that arrives first measures nothing.
    server_before = windowserver_seconds()
    started = time.time()
    status, _ = run(guest, (command or ['program-tree']) + ['--port', str(port), '--seconds', str(seconds)] +
                    (['--hook'] if hook else []))
    print(f'windowserver_cpu {(windowserver_seconds() - server_before) / (time.time() - started) * 100:.0f} %')
    print(f'# guest exit {status}', flush=True)
    try:
        report, _ = viewer.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        viewer.terminate()
        report, _ = viewer.communicate()
    print(f'== Viewer on the host, exit {viewer.returncode}')
    print(report)
    print(f'# Each window is in {prefix}-<id>.png, and composed views in {name}-screen-*.png.', flush=True)


def install_hook():
    # Uses a reboot, since launchd only reads a job's environment when it loads. This is a clone, so the edit goes with it.
    # The agent answers with an error until it's up.
    version = ''
    for _ in range(120):
        version = request({'Executable': '/usr/bin/uname', 'Arguments': ['-r']}, 60).get('Stdout', '')
        if version:
            break
        time.sleep(5)
    if not version.startswith(('13.', '18.')):
        raise SystemExit(f'The hook has builds for 10.9 and 10.14, with their symbol names; this is Darwin {version.strip()}.')
    staged = stage(results/'seamless-ws-hook.dylib')
    plist = '/System/Library/LaunchDaemons/com.apple.WindowServer.plist'
    install = ('set -e; cp "$1" /var/tmp/seamless-ws-hook.dylib; chmod 755 /var/tmp/seamless-ws-hook.dylib; '
               'rm -f /var/tmp/seamless-ws-probe.log; '
               f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" {plist} || true; '
               f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string '
               f'/var/tmp/seamless-ws-hook.dylib" {plist}; /usr/bin/plutil -lint {plist}')
    result = request({'Executable': '/bin/sh', 'Arguments': ['-c', install, 'sh', staged]}, 120)
    print(result.get('Stdout', ''), result.get('Stderr', ''), flush=True)
    if result.get('ExitCode') != 0:
        raise SystemExit('Could not install the hook')
    print('# Rebooting the clone', flush=True)
    # In the background, so the agent can answer before it goes.
    request({'Executable': '/bin/sh', 'Arguments': ['-c', '(sleep 5; /sbin/reboot) >/dev/null 2>&1 &']}, 60)
    time.sleep(90)
    # The agent comes back after the reboot; any failure until then just means not yet.
    deadline = time.time() + 600
    log = ''
    while time.time() < deadline:
        try:
            result = request({'Executable': '/bin/cat', 'Arguments': ['/var/tmp/seamless-ws-probe.log']}, 120)
        except SystemExit as stuck:
            print(f'# waiting: {stuck}', flush=True)
            continue
        log = result.get('Stdout') or ''
        if log.count('-- sample') >= 2 or 'refusing' in log or 'not calling any' in log or log.count('== loaded') > 2:
            break
        time.sleep(15)
    (results/f'{tag}.log').write_text(log)
    if log.count('== loaded') > 1:
        print(f'# ERROR WindowServer restarted: loaded {log.count("== loaded")} times. Newest crash:')
        crash = request({'Executable': '/bin/sh', 'Arguments': ['-c', 'cd /Library/Logs/DiagnosticReports && f=$(ls -t WindowServer* | head -1) && '
                                                                     'sed -n 1,70p "$f"']}, 60)
        print((crash.get('Stdout') or crash.get('Stderr') or '')[:5000], flush=True)
    state = request({'Executable': '/usr/bin/pgrep', 'Arguments': ['-lx', 'WindowServer']}, 60)
    print(f'# WindowServer: {state.get("Stdout", "").strip() or "NOT RUNNING"}')
    print('\n'.join(log.splitlines()[:6]))


def hook(seconds):
    install_hook()
    print(f'# frame {capture(f"{tag}-frame.png")}: does the desktop still look right?', flush=True)
    # The staging folder doesn't survive a reboot.
    guest = stage(guest_tool)
    tree(seconds, guest)
    tree(seconds, guest, hook=True, command=['program-tree', '--gl'] if 'gl' in arguments else None)
    log = request({'Executable': '/bin/cat', 'Arguments': ['/var/tmp/seamless-ws-probe.log']}, 120).get('Stdout') or ''
    (results/f'{tag}.log').write_text(log)


def diag():
    guest = stage(guest_tool)
    copy = ('mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp "$1" /tmp/sg/g; chmod 755 /tmp/sg/g')
    request({'Executable': '/bin/sh', 'Arguments': ['-c', copy, 'sh', guest]}, 120)
    time.sleep(90)
    finder = request({'Executable': '/usr/bin/pgrep', 'Arguments': ['-x', 'Finder']}, 60).get('Stdout', '').strip()
    login = request({'Executable': '/usr/bin/pgrep', 'Arguments': ['-x', 'loginwindow']}, 60).get('Stdout', '').strip()
    print(f'# Finder {finder} loginwindow {login}')
    session = ['/bin/launchctl', 'bsexec', finder, '/usr/bin/sudo', '-S', '-u', '#501']
    request({'Executable': '/bin/sh', 'Arguments': ['-c', ' '.join(session[:4]) + " /usr/bin/sudo -S -u '#501' /tmp/sg/g demo-app </dev/null >/tmp/sg/demo.log 2>&1 &"]}, 60)
    time.sleep(60)
    tries = [
        ['/bin/ps', '-axo', 'pid,user,comm'],
        ['/usr/bin/tail', '-n', '30', '/var/log/system.log'],
        session + ['/tmp/sg/g', 'diag'],
        ['/bin/launchctl', 'bsexec', finder, '/tmp/sg/g', 'diag'],
        session + ['/usr/sbin/screencapture', '-x', '/tmp/sg/s.png'],
        ['/bin/ls', '-la', '/tmp/sg'],
        ['/bin/cat', '/tmp/sg/demo.log'],
    ]
    for t in tries:
        print('>>', ' '.join(t), flush=True)
        r = request({'Executable': '/bin/sh', 'Arguments': ['-c', 'exec "$@" </dev/null', 'sh', *t]}, 120)
        print('  exit', r.get('ExitCode'), (r.get('Stdout') or '').strip()[:5000], '| err:', (r.get('Stderr') or r.get('Error') or '').strip(), flush=True)
    print(capture(f'{tag}-frame.png'))


def gl():
    # Does a GL view show on the guest's own display, as opposed to in a capture of its window?
    guest = stage(guest_tool)
    copy = 'mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp "$1" /tmp/sg/g; chmod 755 /tmp/sg/g'
    request({'Executable': '/bin/sh', 'Arguments': ['-c', copy, 'sh', guest]}, 120)
    request({'Executable': '/bin/sh', 'Arguments': ['-c', '/tmp/sg/g program-gl >/tmp/sg/gl.log 2>&1 &']}, 60)
    time.sleep(90)
    print('whole guest frame', capture(f'{tag}-guest-frame.png'), flush=True)
    r = request({'Executable': '/tmp/sg/g', 'Arguments': ['png-window', '--app', 'seamless-guest', '--out', '/tmp/sg/capture.png']}, 120)
    print(r.get('Stdout'), r.get('Stderr'))
    print(request({'Executable': '/bin/cat', 'Arguments': ['/tmp/sg/gl.log']}, 60).get('Stdout'))


def safari(seconds):
    install_hook()
    guest = stage(guest_tool)
    tree(seconds, guest, hook=True, command=['tree', '--app', 'Safari', '--open'])


def motion():
    install_hook()
    guest = stage(guest_tool)
    tree(32, guest, hook=True, command=['program-tree', '--gl'])


def version_is_mojave():
    return request({'Executable': '/usr/bin/uname', 'Arguments': ['-r']}, 60).get('Stdout', '').startswith('18.')


def tree_bench(seconds):
    # The windows the hook can't read, plus what it can, once each in one boot, to compare a machine's settings.
    install_hook()
    guest = stage(guest_tool)
    copy = 'mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp "$1" /tmp/sg/g; chmod 755 /tmp/sg/g'
    request({'Executable': '/bin/sh', 'Arguments': ['-c', copy, 'sh', guest]}, 120)
    for name, command in {'Safari': ['tree', '--app', 'Safari', '--open'], 'TextEdit': ['tree', '--app', 'TextEdit', '--open'],
                          'Demo': ['program-tree', '--gl']}.items():
        if name == 'Demo' and version_is_mojave():
            continue
        print(f'=== {name}', flush=True)
        tree(seconds, '/tmp/sg/g', hook=True, command=command)


def mojave(seconds):
    # What a capture does on Mojave, with the hook only reporting what its windows hold.
    install_hook()
    guest = stage(guest_tool)
    tree(seconds, guest, hook=True, command=['tree', '--app', 'TextEdit', '--open'])
    tree(seconds, guest, hook=True, command=['tree', '--app', 'Safari', '--open'])
    log = request({'Executable': '/bin/cat', 'Arguments': ['/var/tmp/seamless-ws-probe.log']}, 120).get('Stdout') or ''
    (results/f'{tag}-hook.log').write_text(log)


def placement():
    # Does the hook's offset move a window in the display's frame, with nothing else about it changing?
    for _ in range(120):
        if request({'Executable': '/usr/bin/touch', 'Arguments': ['/var/tmp/seamless-ws-placement']}, 60).get('ExitCode') == 0:
            break
        time.sleep(5)
    install_hook()
    guest = stage(guest_tool)
    run(guest, ['open-app', '--app', 'TextEdit'])
    time.sleep(5)
    print('before', capture(f'{tag}-before.png'), flush=True)
    run(guest, ['place', '--app', 'TextEdit', '--dx', '500', '--dy', '300', '--wait', '5'])
    print('after', capture(f'{tag}-after.png'), flush=True)
    time.sleep(3)
    print('later', capture(f'{tag}-later.png'), flush=True)
    log = request({'Executable': '/bin/cat', 'Arguments': ['/var/tmp/seamless-ws-probe.log']}, 120).get('Stdout') or ''
    print('\n'.join(line for line in log.splitlines() if 'redraw' in line or '== loaded' in line))


def windowed(seconds):
    # The bar: the same page and clicks as the seamless side of scripts/seamless-compare, through windowed mode's own path.
    guest = stage(guest_tool)
    print(run(guest, ['open-app', '--app', 'Safari'])[0], flush=True)
    time.sleep(15)
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    app_pid = next((row.split()[0] for row in listing.splitlines() if f'Build/bench/{tag}/' in row and 'Contents/MacOS/Light Click' in row), '0')
    windows = subprocess.run([str(results/'seamless-guest'), 'list'], capture_output=True, text=True).stdout
    window = next((re.search(r'id=(\d+)', row).group(1) for row in windows.splitlines() if f'pid={app_pid} ' in row and 'title="Clone of' in row), None)
    meter = str(results/'seamless-present-meter')
    if window:
        clicks = results/f'{tag}-clicks.txt'
        for _ in range(2):
            request({'Action': 'test-click'}, 60)
            time.sleep(1)
        clicks.write_text('')
        timing = subprocess.Popen([meter, window, '16', '--clicks', str(clicks)], stdout=subprocess.PIPE, text=True)
        for _ in range(15):
            at = request({'Action': 'test-click'}, 60).get('At')
            with clicks.open('a') as file:
                file.write(f'{at}\n')
            time.sleep(1)
        print('windowed_' + timing.communicate()[0].strip().replace('\n', '\nwindowed_'), flush=True)
        time.sleep(7)
    print('windowed_', end='', flush=True)
    cpu_percent()
    # And over the frames, what its window really shows, by that one window's ID.
    presenting = subprocess.Popen([meter, window, str(seconds)], stdout=subprocess.PIPE, text=True) if window else None
    first = request({'Action': 'display-frames'}, 60)
    started = time.time()
    time.sleep(seconds)
    last = request({'Action': 'display-frames'}, 60)
    spent = time.time() - started
    print(f'windowed_frames {(last.get("Arrived", 0) - first.get("Arrived", 0)) / spent:.1f} /s', flush=True)
    if presenting:
        print('windowed_' + presenting.communicate()[0].strip(), flush=True)
    print(f'windowed_distinct {(last.get("Distinct", 0) - first.get("Distinct", 0)) / spent:.1f} /s', flush=True)


def monitor_dump(why):
    # Where the agent's UART, COM2 at 0x2f8, and its interrupt are. IIR goes last, as reading it can clear what it says.
    print('# from the monitor,', why, flush=True)
    # Both ends of the agent's socket: whether QEMU still holds a client the app has let go.
    pids = [row.split()[0] for row in subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines()
            if f'Build/bench/{tag}/' in row]
    if pids:
        said = subprocess.run(['lsof', '-n', '-U', '-a', '-p', ','.join(pids)], capture_output=True, text=True).stdout
        print('## lsof', '\n'.join(row for row in said.splitlines() if 'guest-agent' in row or '->' in row)[:3000], flush=True)
        # A connection waiting in the listener's queue unaccepted points at QEMU's loop not reaching the hang-up.
        said = subprocess.run(['netstat', '-anv', '-f', 'unix'], capture_output=True, text=True).stdout
        print('## netstat', '\n'.join(row for row in said.splitlines() if 'guest-agent' in row)[:2000], flush=True)
        qemu = [row.split()[0] for row in subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines()
                if f'Build/bench/{tag}/' in row and 'qemu-system' in row]
        if qemu:
            sample = results/f'{tag}-qemu.sample.txt'
            subprocess.run(['sample', qemu[0], '3', '-file', str(sample)], capture_output=True)
            text = sample.read_text() if sample.exists() else ''
            main = text.split('Thread_')[1] if 'Thread_' in text else ''
            print('## qemu main thread', main[:3000], flush=True)
    for command in ('info chardev', 'info pic', 'info ioapic', 'info lapic', 'i/b 0x2f9', 'i/b 0x2fb', 'i/b 0x2fc', 'i/b 0x2fd', 'i/b 0x2fe', 'i/b 0x2fa', 'i/b 0x2fd'):
        print(f'## {command}', request({'Action': 'monitor', 'Command': command}, 30), flush=True)


def cpu_seconds():
    # All of this clone's: the app, QEMU, and any proxies, which are generated under its folder.
    total = 0.0
    rows = subprocess.run(['ps', '-axo', 'time=,command='], capture_output=True, text=True).stdout.splitlines()
    for row in rows:
        if f'Build/bench/{tag}/' not in row:
            continue
        clock = row.split()[0].split(':')
        total += sum(float(part) * 60 ** index for index, part in enumerate(reversed(clock)))
    return total


def cpu_percent(seconds=16):
    # The whole cost of showing the page moving, for the same number on windowed's side and seamless's.
    start, at = cpu_seconds(), time.time()
    time.sleep(seconds)
    percent = (cpu_seconds() - start) / (time.time() - at) * 100
    load = subprocess.run(['uptime'], capture_output=True, text=True).stdout.split('load average')[-1].strip()
    print(f'cpu_percent {percent:.0f}, load {load}', flush=True)


WATCH_PORT = 57391
# In one shell. A sample of the agent now and then says where it's stuck, if it is.
WATCHER = r'''
agent=$(/usr/bin/pgrep -f opengl-guest-agent | /usr/bin/head -1)
comm=opengl-guest-agent
report() { /usr/bin/nc -w 1 10.0.2.2 "$1"; }
{ echo "agent pid $agent is $comm"; /bin/ls /Library/LaunchDaemons | /usr/bin/grep -iE "virtual|intel|agent|qemu"; /bin/launchctl list | /usr/bin/grep -iE "virtual|qemu|guest"; } | report "$1"
# Late timers or wakeups show as a 0.1 s sleep taking over a second, logged with the guest's own clock.
/usr/bin/perl -MTime::HiRes=usleep,time -e '$| = 1; while (1) { $t = time; usleep(100000); $d = time - $t; printf "oversleep %.3f s at %.3f\n", $d, $t if $d > 1 }' >/tmp/seamless-oversleep.log 2>&1 </dev/null &
(
n=0
while :; do
  n=$((n + 1))
  agent=$(/usr/bin/pgrep -f opengl-guest-agent | /usr/bin/head -1)
  {
    /bin/date
    /bin/ps -axo pid,ppid,stat,etime,pcpu,command | /usr/bin/grep -E "$comm|/tmp/sg|ws-inject|WindowServer|tccd|perl" | /usr/bin/grep -v grep | /usr/bin/cut -c1-120
    /bin/launchctl list | /usr/bin/grep -iE "virtual|qemu|guest"
    /bin/cat /var/tmp/seamless-ws-press 2>/dev/null
    # Which way it's stuck: waiting on tty output is the transmit path, on input a lost receive.
    /bin/ps -o pid,stat,wchan,etime,command -p $agent | /usr/bin/tail -1 | /usr/bin/cut -c1-120
    /bin/stty -a -f /dev/cu.serial2 2>&1 | /usr/bin/tr '\n' ' ' | /usr/bin/cut -c1-400; echo
    /usr/bin/tail -3 /tmp/seamless-oversleep.log
    /usr/bin/tail -2 /var/log/system.log | /usr/bin/cut -c1-180
    if [ $((n % 5)) = 0 ]; then
      /usr/sbin/ioreg -l -w0 -r -c Apple16X50UARTSync 2>/dev/null | /usr/bin/grep -vE "^ *$" | /usr/bin/cut -c1-140 | /usr/bin/head -40
      /usr/sbin/ioreg -l -w0 -r -n Apple16X50Serial 2>/dev/null | /usr/bin/grep -iE "count|state|error|overrun|bytes" | /usr/bin/cut -c1-140 | /usr/bin/head -20
      /usr/bin/sample $agent 1 -file /tmp/seamless-watch.sample >/dev/null 2>&1
      /usr/bin/grep -A25 "Call graph" /tmp/seamless-watch.sample | /usr/bin/cut -c1-110
      /usr/sbin/lsof -p $agent 2>/dev/null | /usr/bin/grep -E "serial|cu\\." | /usr/bin/cut -c1-110
    fi
    echo
  } | report "$1"
  /bin/sleep 2
done
) >/tmp/seamless-watch.err 2>&1 </dev/null &
echo started
'''


def install_watcher():
    # Once, into a private copy of the test machine: the watcher as a launchd job, so it reports from boot, before the
    # agent may go quiet. Then a clean shutdown, and the clone kept as that copy, with its own identifier.
    copy = Path(arguments[arguments.index('install-watcher') + 1])
    script = WATCHER.replace('"$1"', str(WATCH_PORT))
    plist = ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
             '<key>Label</key><string>gold.samhenri.seamless-watch</string>'
             '<key>ProgramArguments</key><array><string>/bin/sh</string><string>/usr/local/libexec/seamless-watch.sh</string></array>'
             '<key>RunAtLoad</key><true/><key>AbandonProcessGroup</key><true/></dict></plist>')
    install = ('/bin/mkdir -p /usr/local/libexec && printf %s "$1" > /usr/local/libexec/seamless-watch.sh && '
               f"/bin/echo '{plist}' > /Library/LaunchDaemons/gold.samhenri.seamless-watch.plist && "
               '/usr/sbin/chown root:wheel /Library/LaunchDaemons/gold.samhenri.seamless-watch.plist && '
               '/bin/chmod 644 /Library/LaunchDaemons/gold.samhenri.seamless-watch.plist && echo installed')
    said = request({'Executable': '/bin/sh', 'Arguments': ['-c', install, 'sh', script]}, 60)
    print('install:', said, flush=True)
    if 'installed' not in (said.get('Stdout') or ''):
        return
    request({'Executable': '/bin/sh', 'Arguments': ['-c', '/sbin/shutdown -h +0 >/dev/null 2>&1 &']}, 30)
    clone = next((source/'Build/bench'/tag/'home/Library/Application Support/Light Click/Machines').glob('Clone of *.vintelmac'))
    for _ in range(120):
        running = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True).stdout
        if not any(f'Build/bench/{tag}/' in row and 'qemu-system' in row for row in running.splitlines()):
            break
        time.sleep(1)
    else:
        print('the guest never shut down, so nothing was kept', flush=True)
        return
    shutil.rmtree(copy, ignore_errors=True)
    subprocess.run(['cp', '-c', '-R', str(clone), str(copy)], check=True)
    (copy/'State/PendingConfiguration.plist').unlink(missing_ok=True)
    print('kept', copy, flush=True)


def watch_guest():
    # What the guest's doing, sent by the guest over its own network: when its agent stops answering, there's no asking it.
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind(('127.0.0.1', WATCH_PORT))
    except OSError:
        listener.bind(('127.0.0.1', 0))
    listener.listen(16)
    port = listener.getsockname()[1]
    target = results/f'{tag}-guest-watch.txt'
    target.write_text('')

    def receive():
        while True:
            client, _ = listener.accept()
            with client, target.open('ab') as file:
                while chunk := client.recv(65536):
                    file.write(chunk)
    threading.Thread(target=receive, daemon=True).start()
    # In one shell, so $PPID is the agent. A sample of it now and then says where it's stuck, if it is.
    script = WATCHER
    said = request({'Executable': '/bin/sh', 'Arguments': ['-c', script, 'sh', str(port)]}, 30)
    print('the watcher:', said, flush=True)
    if said.get('Error'):
        monitor_dump('the agent not answering the first request')
        # Whether the guest answers at all while silent: QEMU's bytes each way on the socket, around a few more requests.
        for _ in range(6):
            sockets = subprocess.run(['netstat', '-anv', '-f', 'unix'], capture_output=True, text=True).stdout.splitlines()
            print('## agent socket', [' '.join(row.split()[:10]) for row in sockets if 'guest-agent' in row], flush=True)
            print('## a request', request({'Executable': '/usr/bin/true', 'Arguments': []}, 20), flush=True)
    print('watching the guest:', target, flush=True)


def desktop(activation_only=False):
    # The Seamless button, on a running machine: press, the apps' windows appear and the machine's goes, a click reaches one, press,
    # and the machine's window is back.
    for old in results.glob(f'{tag}-*.png'):
        old.unlink()
    # Before anything else asks the agent for anything: it has been seen to stop right after staging.
    watch_guest()
    guest = stage(guest_tool)
    for app in ('Finder', 'TextEdit', 'Safari') if version_is_mojave() else ('TextEdit', 'Safari'):
        run(guest, ['open-app', '--app', app])
    time.sleep(12)
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    app_pid = next((row.split()[0] for row in listing.splitlines() if f'Build/bench/{tag}/' in row and 'Contents/MacOS/Light Click' in row), '0')
    meter = str(results/'seamless-present-meter')

    def rows():
        return subprocess.run([str(results/'seamless-guest'), 'list'], capture_output=True, text=True).stdout.splitlines()

    def machine_window():
        # AppKit's word: with the Mac's display asleep, WindowServer's list still says a hidden window's on screen.
        return request({'Action': 'seamless-state'}, 60).get('WindowVisible')

    def proxy_windows():
        running = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines()
        pids = {row.split()[0] for row in running if 'Seamless Apps/' in row and f'Build/bench/{tag}/' in row}
        return [row for row in rows() if re.search(r'pid=(\d+)', row).group(1) in pids and ' 0x0' not in row]

    checks = []

    def check(what, passed):
        checks.append(passed)
        print(f'{"PASS" if passed else "FAIL"} {what}', flush=True)

    def proxy_pid(name):
        found = next((row for row in proxy_windows() if f'owner="{name}' in row), '')
        match = re.search(r'pid=(\d+)', found)
        return int(match.group(1)) if match else 0

    for _ in range(240):
        state = request({'Action': 'seamless-state'}, 60)
        if state.get('Prepared') or 'Prepared' not in state:
            break
        time.sleep(1)
    # A second TextEdit window, in front of the first, for a press that only the host can tell apart.
    request({'Executable': '/bin/sh', 'Arguments': ['-c', 'echo second > /tmp/seamless-second.txt; chmod 644 /tmp/seamless-second.txt; '
                                                    '/tmp/sg/ig open-file --session --path /tmp/seamless-second.txt --with TextEdit']}, 120)
    time.sleep(70)
    print('before the press', request({'Action': 'seamless-state'}, 60), flush=True)
    print('the agent before the press:', request({'Executable': '/usr/bin/uname', 'Arguments': ['-r']}, 60), flush=True)
    print(next(iter(rows()), ''), flush=True)
    pressed = time.time()
    request({'Action': 'seamless-toggle'}, 60)
    windows = []
    first = None
    dumped = 0
    socket_at = 0
    while time.time() - pressed < 180 and (len(windows) < 2 or machine_window()):
        windows = proxy_windows()
        if windows and first is None:
            first = time.time() - pressed
        # While the agent's silent, not after: it has been seen to come back.
        # Bytes each way on the agent's socket, often, to tell an unanswered request from an answer that never arrives.
        if first is None and time.time() - pressed > 2 and time.time() - socket_at > 4:
            socket_at = time.time()
            sockets = subprocess.run(['netstat', '-anv', '-f', 'unix'], capture_output=True, text=True).stdout.splitlines()
            print(f'## {time.time() - pressed:.0f} s agent socket', [' '.join(row.split()[:10]) for row in sockets if 'guest-agent' in row], flush=True)
        if first is None and time.time() - pressed > 12 + dumped * 25 and dumped < 3:
            dumped += 1
            monitor_dump(f'{time.time() - pressed:.0f} s after a press with no windows yet')
        time.sleep(0.1)
    print(f'first window after {first} s, machine window gone after {time.time() - pressed:.1f} s', flush=True)
    for row in windows:
        print(row[:150], flush=True)
    check('windows appear for each app', len(windows) >= 2)
    if not windows:
        print('guest frame', capture(f'{tag}-no-windows.png'), flush=True)
        monitor_dump('no windows came')
        print('the agent after no windows:', request({'Executable': '/bin/sh', 'Arguments': ['-c', '/bin/cat /var/tmp/seamless-ws-press; /bin/ls -l /var/tmp /usr/lib/seamless-ws-hook.dylib; /usr/bin/pgrep -x WindowServer; /bin/ps -axo pid,etime,command | /usr/bin/grep -E "/tmp/sg|agent" | /usr/bin/head -20; /usr/bin/tail -30 /var/log/system.log']}, 120), flush=True)
    for _ in range(3):
        print('settling', time.time() - pressed, [row[-30:] for row in proxy_windows()], flush=True)
        time.sleep(1)
    windows = proxy_windows()
    check('the machine window hides', not machine_window())
    check('its windows are on their own surfaces', request({'Action': 'seamless-state'}, 60).get('OwnSurfaces'))
    if activation_only:
        # Using only what any build has: another app's window clicked, then whether the animating page keeps moving.
        page = next((re.search(r'id=(\d+)', row).group(1) for row in proxy_windows() if 'Seamless page' in row), None)

        def page_moving(when):
            said = subprocess.run([meter, page or '0', '5'], capture_output=True, text=True).stdout.strip()
            print(when, said, flush=True)
            found = re.search(r'presented ([0-9.]+)', said)
            return float(found.group(1)) if found else 0
        if not proxy_pid('TextEdit') or not proxy_pid('Safari'):
            print('guest frame', capture(f'{tag}-no-windows.png'), flush=True)
            check('there are windows to test', False)
            return
        before = page_moving('before')
        time.sleep(1)
        os.kill(proxy_pid('TextEdit'), signal.SIGUSR1)
        time.sleep(3)
        after = page_moving('with the other app active')
        os.kill(proxy_pid('Safari'), signal.SIGUSR1)
        time.sleep(7)
        back = page_moving('with the page clicked again')
        print('OwnSurfaces', request({'Action': 'seamless-state'}, 60).get('OwnSurfaces'), flush=True)
        check('the page moves before another app activates', before >= 30)
        check('and while it is active', after >= 30)
        check('and when it comes back', back >= 30)
        return
    # Two windows of one app overlapping in the guest and apart on the host: a press on the lower one is for it, not what's over it.
    lower = next((re.search(r'id=(\d+)', row).group(1) for row in proxy_windows() if 'seamless-note' in row), None)
    textedit_pid = next((int(re.search(r'pid=(\d+)', row).group(1)) for row in proxy_windows() if 'seamless-note' in row), 0)
    if lower and textedit_pid:
        command = results/f'{tag}-clicks.txt.command'
        report_file = results/f'{tag}-clicks.txt.command.report'

        def tell(what, wait=1.5):
            command.write_text(what)
            os.kill(textedit_pid, signal.SIGUSR2)
            time.sleep(wait)

        def report():
            # Front first: title, the proxy's place on the host, and what's added to the guest's place to get it.
            report_file.unlink(missing_ok=True)
            tell('report', 0.5)
            rows_said = [row.split('\t') for row in report_file.read_text().splitlines()]
            return [(row[0], *map(float, row[1:5])) for row in rows_said]

        # The windows overlap in the guest: the same place on the lower one gets the upper one, without the raise.
        tell('click-title seamless-second')
        tell('click-no-raise-title seamless-note')
        without = report()[0][0]
        tell('click-title seamless-note')
        raised = report()[0][0]
        print('front after a press on the covered window: without raising', without, 'and with', raised, flush=True)
        check('without the raise, that press goes to what covers it in the guest', without.startswith('seamless-second'))
        check('a press on a window that\'s covered in the guest reaches it', raised.startswith('seamless-note'))
        # Moved on the host, the guest's own idea follows, and nothing shows that on the host.
        tell('click-title seamless-second')
        start = next(row for row in report() if row[0].startswith('seamless-note'))
        tell('move-title seamless-note', 0)
        moved = None
        for _ in range(2):
            time.sleep(1)
            after = next(row for row in report() if row[0].startswith('seamless-note'))
            moved = moved or after
        guest_at = lambda row: (row[1] - row[3], row[2] - row[4])
        print('placed in the guest: from', guest_at(start), 'to', guest_at(after), 'on the host', after[1:3], flush=True)
        check('moved on the host, it stays where it was put', moved[1:3] == after[1:3] and after[1:3] != start[1:3])
        check('and the guest moves it too', guest_at(after) != guest_at(start))
    else:
        check('a press on a window that\'s covered in the guest reaches it', False)
    for row in windows:
        window = re.search(r'id=(\d+)', row).group(1)
        subprocess.run([str(results/'seamless-present-meter'), window, '0.2', '--save', str(results/f'{tag}-desktop-{window}.png')], capture_output=True)
    # Each proxy's material views against what the guest sent: one view per kind, covering the window, in its input view,
    # masked, and every region inside it. Only their existence and frames: how they look needs an awake display.
    said_materials = []
    command_file = results/f'{tag}-clicks.txt.command'
    for name in ('TextEdit', 'Safari', 'Finder'):
        pid = proxy_pid(name)
        if not pid:
            continue
        materials_file = results/f'{tag}-clicks.txt.command.materials'
        materials_file.unlink(missing_ok=True)
        command_file.write_text('materials-report')
        os.kill(pid, signal.SIGUSR2)
        time.sleep(0.5)
        for line in (materials_file.read_text().splitlines() if materials_file.exists() else []):
            print(f'materials {name}: {line}', flush=True)
            said_materials.append(line)
    # A SIGUSR2 with no command is a move: leave it that way for what follows.
    command_file.write_text('')
    sent = [line for line in said_materials if 'rows 0' not in line]
    def right(line):
        kinds = int(re.search(r'kinds (\d+)', line).group(1))
        views = re.search(r'views (.*)$', line).group(1)
        parts = [part for part in views.split(',') if part]
        return 'inside true' in line and len(parts) == kinds and all(part.endswith(':whole:in:mask') for part in parts)
    if sent:
        check('each material the guest sent has its view, over the whole window', all(right(line) for line in sent))
    else:
        print('no window had materials from the guest', flush=True)
    # What the surfaces hold, against what's just been read from the proxies.
    held = results/f'{tag}-surfaces'
    shutil.rmtree(held, ignore_errors=True)
    held.mkdir()
    request({'Action': 'seamless-save-surfaces', 'Directory': str(held)}, 60)
    print('surfaces saved', sorted(path.name for path in held.iterdir()), flush=True)
    clicks = results/f'{tag}-clicks.txt'
    safari = proxy_pid('Safari')
    window = next((re.search(r'id=(\d+)', row).group(1) for row in windows if 'Safari' in row), None)
    if safari and window:
        for _ in range(2):
            os.kill(safari, signal.SIGUSR1)
            time.sleep(1)
        clicks.write_text('')
        timing = subprocess.Popen([meter, window, '8', '--clicks', str(clicks)], stdout=subprocess.PIPE, text=True)
        for _ in range(6):
            os.kill(safari, signal.SIGUSR1)
            time.sleep(1)
        said = timing.communicate()[0]
        print(said, flush=True)
        check('input reaches a window', re.search(r'median \d+ ms', said) is not None)
    else:
        check('input reaches a window', False)
    time.sleep(6)
    for _ in range(4):
        print('bounds', time.time() - pressed, next((row[-40:] for row in rows() if f'id={window} ' in row), ''), flush=True)
        time.sleep(2)
    cpu_percent()
    framed = request({'Action': 'seamless-state'}, 60).get('SurfaceFrames', 0)
    moving = subprocess.run([meter, window or '0', '8'], capture_output=True, text=True).stdout
    print('moving', moving, 'frames from QEMU/s', (request({'Action': 'seamless-state'}, 60).get('SurfaceFrames', 0) - framed) / 8, flush=True)
    rate = re.search(r'presented ([0-9.]+)', moving)
    check('the window shows its page moving', rate is not None and float(rate.group(1)) >= 30)
    # Moved on the host, past where the machine's window was: the guest's doesn't follow, it still moves, and a click still lands.
    def place(of):
        row = next((row for row in rows() if f'id={of} ' in row), '')
        print('at', time.time() - pressed, row[-40:], flush=True)
        found = re.search(r'bounds=(-?[\d.]+),(-?[\d.]+)', row)
        return (float(found.group(1)), float(found.group(2))) if found else None
    if safari and window:
        (results/f'{tag}-clicks.txt.command').write_text('move')
        before = place(window)
        os.kill(safari, signal.SIGUSR2)
        time.sleep(2)
        after = place(window)
        print('moved from', before, 'to', after, flush=True)
        check('a window moves on the host', before is not None and after is not None and before != after)
        subprocess.run([str(results/'seamless-present-meter'), window, '0.2', '--save', str(results/f'{tag}-desktop-moved.png')], capture_output=True)
        clicks.write_text('')
        timing = subprocess.Popen([meter, window, '5', '--clicks', str(clicks)], stdout=subprocess.PIPE, text=True)
        for _ in range(4):
            os.kill(safari, signal.SIGUSR1)
            time.sleep(1)
        said = timing.communicate()[0]
        print(said, flush=True)
        check('input still reaches it there', re.search(r'median \d+ ms', said) is not None)
        check('it stayed there', place(window) == after)
        # Two apps' windows overlap in the guest. TextEdit's over Safari's, so apart on the host, Safari's must show its own page there,
        # dark from a click, and no TextEdit. Saved by each window's ID, for looking at.
        command = results/f'{tag}-clicks.txt.command'
        textedit = proxy_pid('TextEdit')
        other = next((re.search(r'id=(\d+)', row).group(1) for row in proxy_windows() if 'TextEdit' in row), None)
        command.write_text('move')
        if textedit:
            os.kill(textedit, signal.SIGUSR2)
        time.sleep(2)
        # An odd number of clicks, so its page is dark where TextEdit's white would otherwise be.
        (results/f'{tag}-clicks.txt').write_text('')
        os.kill(safari, signal.SIGUSR1)
        time.sleep(1.5)
        for name, wanted in (('safari', window), ('textedit', other)):
            if wanted:
                subprocess.run([str(results/'seamless-present-meter'), wanted, '0.2', '--save', str(results/f'{tag}-apart-{name}.png')], capture_output=True)
        command.write_text('resize')
        os.kill(safari, signal.SIGUSR2)
        time.sleep(1)
        during = subprocess.run([meter, window, '1'], capture_output=True, text=True).stdout
        subprocess.run([str(results/'seamless-present-meter'), window, '0.2', '--save', str(results/f'{tag}-resizing.png')], capture_output=True)
        time.sleep(4)
        print('during a resize', during, flush=True)
        print('after resize', next((row[-40:] for row in proxy_windows() if f'id={window} ' in row), ''), flush=True)
        subprocess.run([str(results/'seamless-present-meter'), window, '0.2', '--save', str(results/f'{tag}-resized.png')], capture_output=True)
        # Minimized in the guest, it's in the host's Dock, and back from there it's back in both.
        def on_screen():
            return any(f'id={window} ' in row for row in rows())
        def page_rate():
            said = subprocess.run([meter, window, '3'], capture_output=True, text=True)
            print('page rate read', said.stdout.strip(), said.stderr.strip()[:200], [row[-50:] for row in proxy_windows()], flush=True)
            found = re.search(r'presented ([0-9.]+)', said.stdout)
            return float(found.group(1)) if found else 0
        command.write_text('guest-minimize')
        os.kill(safari, signal.SIGUSR2)
        for _ in range(16):
            time.sleep(0.5)
            if not on_screen():
                break
        check('minimized in the guest, its window leaves the screen', not on_screen())
        time.sleep(1)
        command.write_text('host-restore')
        os.kill(safari, signal.SIGUSR2)
        for _ in range(16):
            time.sleep(0.5)
            if on_screen():
                break
        check('brought back on the host, its window returns', on_screen())
        time.sleep(7)
        rate = page_rate()
        print('after coming back', rate, flush=True)
        report_said = results/f'{tag}-clicks.txt.command.report'
        report_said.unlink(missing_ok=True)
        command.write_text('report')
        os.kill(safari, signal.SIGUSR2)
        time.sleep(0.5)
        print('its proxy says', report_said.read_text() if report_said.exists() else 'nothing', flush=True)
        check('and the guest has it back too', rate >= 30)
        command.write_text('host-minimize')
        os.kill(safari, signal.SIGUSR2)
        time.sleep(2)
        check('minimized on the host, its window leaves the screen', not on_screen())
        command.write_text('host-restore')
        os.kill(safari, signal.SIGUSR2)
        time.sleep(3)
        check('and returns', on_screen())
        for row in proxy_windows():
            if 'Finder' in row:
                subprocess.run([str(results/'seamless-present-meter'), re.search(r'id=(\d+)', row).group(1), '0.2', '--save', str(results/f'{tag}-materials.png')], capture_output=True)
        # Not a pass or a fail yet: what a real guest full screen does to this window, and to the others.
        command.write_text('guest-full-screen')
        print('before full screen', [row[-50:] for row in proxy_windows()], flush=True)
        (results/f'{tag}-clicks.txt.full-screen').unlink(missing_ok=True)
        os.kill(safari, signal.SIGUSR2)
        time.sleep(8)
        print('in full screen', [row[-50:] for row in proxy_windows()], flush=True)
        full_report = results/f'{tag}-clicks.txt.command.report'
        full_report.unlink(missing_ok=True)
        command.write_text('report')
        os.kill(safari, signal.SIGUSR2)
        time.sleep(0.5)
        print('in full screen its proxy says', full_report.read_text() if full_report.exists() else 'nothing', flush=True)
        print('in full screen moving', subprocess.run([meter, window, '3'], capture_output=True, text=True).stdout, flush=True)
        subprocess.run([str(results/'seamless-present-meter'), window, '0.2', '--save', str(results/f'{tag}-full-screen.png')], capture_output=True)
        os.kill(safari, signal.SIGUSR2)
        time.sleep(8)
        print('after full screen', [row[-50:] for row in proxy_windows()], flush=True)
        back_after_full_screen = any(f'id={window} ' in row and 'Seamless page' in row for row in rows())
        check('the same proxy window is there after full screen', back_after_full_screen)
        said = (results/f'{tag}-clicks.txt.full-screen')
        print('proxy says', said.read_text() if said.exists() else 'nothing (or the display was asleep, and it really did)', flush=True)
        frame = capture(f'{tag}-desktop-frame.png')
        print('guest frame', frame, flush=True)
    pressed = time.time()
    request({'Action': 'seamless-toggle'}, 60)
    while time.time() - pressed < 30 and (not machine_window() or proxy_windows()):
        time.sleep(0.1)
    print(f'back after {time.time() - pressed:.1f} s', flush=True)
    check('the machine window comes back', bool(machine_window()))
    check('the windows go', not proxy_windows())
    # A second go, which should be quick, since the tools are staged and the apps made.
    pressed = time.time()
    request({'Action': 'seamless-toggle'}, 60)
    while time.time() - pressed < 60 and machine_window():
        time.sleep(0.1)
    print(f'second press hid the window after {time.time() - pressed:.1f} s', flush=True)
    check('a second press works', not machine_window())
    request({'Action': 'seamless-toggle'}, 60)
    while time.time() - pressed < 120 and not machine_window():
        time.sleep(0.1)
    # The guest's Dock back, once it's had time to restart.
    time.sleep(20)
    capture(f'{tag}-desktop-after.png')
    said = request({'Executable': '/bin/sh', 'Arguments': ['-c', 'cat /tmp/seamless-leap-restore.log; /bin/ps -axo pid,ppid,pgid,command | /usr/bin/grep -E "/tmp/sg/" | /usr/bin/cut -c1-100']}, 60)
    print('restore log:', said.get('Stdout'), said.get('Error'), flush=True)
    check('the guest\'s Dock and shadows are put back', 'dock: 0' in (said.get('Stdout') or ''))
    said = request({'Executable': '/bin/sh', 'Arguments': ['-c', '/bin/ls -la /tmp/sg | /usr/bin/head -20; /usr/bin/grep -hE "placed window|raised window|is now|back from" /tmp/sg/leap-*.log /tmp/sg/*.log | /usr/bin/tail -40; true']}, 60)
    print('the tools saw:', said.get('Stdout'), said.get('Error'), flush=True)
    # Generated apps shouldn't stay known to the Mac after a clone's gone.
    for bundle in (source/'Build/bench'/tag).glob('**/Seamless Apps/*/*/*.app'):
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(bundle)])
    print('PASS seamless button' if all(checks) and machine_window() else 'FAIL seamless button', flush=True)


DOCK_STATE = ('user=$(/usr/bin/stat -f %Su /dev/console); home=$(eval echo ~$user); '
              'echo "user $user"; echo "autohide $(/usr/bin/sudo -u $user /usr/bin/defaults read com.apple.dock autohide 2>&1)"; '
              'echo "delay $(/usr/bin/sudo -u $user /usr/bin/defaults read com.apple.dock autohide-delay 2>&1)"; '
              '/bin/ls $home/Library/LaunchAgents/com.mac.virtualintelmac.seamless-restore.plist 2>&1; '
              '/bin/cat /tmp/seamless-leap-restore.log 2>&1 | /usr/bin/tail -5; echo "login item ran: $(/bin/cat $home/Library/Logs/seamless-restore.log 2>&1)"; true')


def hard_stop():
    # Seamless on, then the app and QEMU killed with no chance to clean up. The guest's disk, as that left it, is kept for
    # the next boot to show what comes back.
    copy = Path(arguments[arguments.index('hard-stop') + 1])
    guest = stage(guest_tool)
    run(guest, ['open-app', '--app', 'TextEdit'])
    for _ in range(240):
        if request({'Action': 'seamless-state'}, 60).get('Prepared'):
            break
        time.sleep(1)
    request({'Action': 'seamless-toggle'}, 60)
    for _ in range(120):
        if not request({'Action': 'seamless-state'}, 60).get('WindowVisible'):
            break
        time.sleep(1)
    # Long enough for anything the guest left to its own time to have reached its disk, as a user's would by then.
    time.sleep(70)
    print('in Seamless', request({'Action': 'seamless-state'}, 60), flush=True)
    # Not asked first: the agent is the press's while windows are out, and nothing's flushed for the guest either.
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines()
    ours = [row for row in listing if f'Build/bench/{tag}/' in row]
    app = [int(row.split()[0]) for row in ours if 'Contents/MacOS/Light Click' in row]
    qemu = [int(row.split()[0]) for row in ours if 'qemu-system' in row]
    for pid in app + qemu:
        os.kill(pid, signal.SIGKILL)
    print('killed the app', app, 'and QEMU', qemu, flush=True)
    time.sleep(3)
    clone = next((source/'Build/bench'/tag/'home/Library/Application Support/Light Click/Machines').glob('Clone of *.vintelmac'))
    shutil.rmtree(copy, ignore_errors=True)
    subprocess.run(['cp', '-c', '-R', str(clone), str(copy)], check=True)
    (copy/'State/PendingConfiguration.plist').unlink(missing_ok=True)
    print('kept', copy, flush=True)


def hard_stop_check():
    # The next boot of what a hard stop left: the Dock's preference back as it was, and what put it back gone.
    time.sleep(60)
    said = request({'Executable': '/bin/sh', 'Arguments': ['-c', DOCK_STATE]}, 60).get('Stdout') or ''
    print('after the next boot:', said, flush=True)
    back = 'autohide 1' not in said and 'seamless-restore.plist' in said and 'No such file' in said
    print('PASS the Dock is back after a hard stop' if back else 'FAIL the Dock is back after a hard stop', flush=True)


def desktop_with_old_hook():
    # A guest an earlier build left with the hook in WindowServer's job: a press takes the entry out and stays on the display's frames
    # for this start. Done without restarting the guest: a press from the next start is the ordinary one.
    plist = '/System/Library/LaunchDaemons/com.apple.WindowServer.plist'
    guest = stage(guest_tool)
    run(guest, ['open-app', '--app', 'TextEdit'])
    # Before pre-arming can inject: it starts about 20 s in, and this is what a guest with the old entry has at its start anyway.
    add = (f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" {plist} || true; '
           f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string /var/tmp/seamless-ws-hook.dylib" {plist}')
    request({'Executable': '/bin/sh', 'Arguments': ['-c', add]}, 60)

    def lines():
        result = request({'Executable': '/bin/sh', 'Arguments': ['-c', f'/usr/bin/grep -c seamless-ws-hook {plist}; true']}, 60)
        said = result.get('Stdout', '').strip()
        print('hook lines in the plist:', said if said else result, flush=True)
        return said

    print('PASS' if lines() == '1' else 'FAIL', 'the entry is there to start with', flush=True)
    for _ in range(240):
        if request({'Action': 'seamless-state'}, 60).get('Prepared'):
            break
        time.sleep(1)
    request({'Action': 'seamless-toggle'}, 60)
    pressed = time.time()
    while time.time() - pressed < 60 and request({'Action': 'seamless-state'}, 60).get('WindowVisible'):
        time.sleep(1)
    now = request({'Action': 'seamless-state'}, 60)
    print('in Seamless', now, 'after', time.time() - pressed, flush=True)
    # The agent is the press's while windows are out, so this waits for it back, as the Dock's restore does.
    request({'Action': 'seamless-toggle'}, 60)
    time.sleep(30)
    removed = lines() == '0'
    print('PASS' if removed else 'FAIL', 'a press removes the entry', flush=True)
    print('PASS' if now.get('Active') and not now.get('OwnSurfaces') else 'FAIL', 'and shows windows from the display this start', flush=True)
    print('PASS old hook' if removed and now.get('Active') and not now.get('OwnSurfaces') else 'FAIL old hook', flush=True)


def capture_bench():
    guest = stage(guest_tool)
    run(guest, ['capture-bench', '--app', 'Safari', '--open'])
    run(guest, ['capture-bench', '--app', 'TextEdit', '--open'])


def proxy(seconds):
    # One guest app as a host app: a generated .app with its own Dock tile, its windows, its menu and its input, with the VM
    # hidden. The Mac's display may be asleep, so what's checked is what WindowServer and LaunchServices report.
    install_hook()
    guest = stage(guest_tool)
    tool = stage(results/'seamless-integration-guest')
    setup = (f'mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp "$1" /tmp/sg/g; cp "$2" /tmp/sg/ig; chmod 755 /tmp/sg/g /tmp/sg/ig; '
             '/usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "'
             + ' '.join(f"INSERT OR REPLACE INTO access (service,client,client_type,allowed,prompt_count) VALUES "
                        f"('kTCCServiceAccessibility','{client}',1,1,1);"
                        for client in ('/private/tmp/sg/ig', '/tmp/sg/ig', '/private/tmp/sg/g', '/usr/bin/sudo', '/usr/bin/env',
                                       # 10.9 asks TCC about the responsible process, and from a daemon that's the agent.
                                       '/Library/Application Support/Virtual Intel Mac/GuestTools/opengl-install-bootstrap')) +
             '"; /usr/bin/killall tccd; sleep 2')
    print(request({'Executable': '/bin/sh', 'Arguments': ['-c', setup, 'sh', guest, tool]}, 120), flush=True)
    apps = request({'Executable': '/tmp/sg/ig', 'Arguments': ['apps']}, 300).get('Stdout', '')
    line = next((l for l in apps.splitlines() if l.startswith('[')), '[]')
    (results/f'{tag}-apps.json').write_text(line)
    icon = base64.b64decode(request({'Executable': '/tmp/sg/ig', 'Arguments': ['icon', '--path', '/Applications/TextEdit.app']}, 300).get('Stdout', '').strip() or b'')
    (results/f'{tag}.icns').write_bytes(icon)
    socket_path = f'/tmp/lc-seamless-{os.getpid()}.sock'
    bundles = results/'proxies'
    shutil.rmtree(bundles, ignore_errors=True)
    made = subprocess.run([str(results/'SeamlessMakeProxy'), 'write', str(results/f'{tag}-apps.json'), 'TextEdit', 'clone', 'Mavericks', '/nonexistent',
                           str(bundles), str(results/'SeamlessProxy'), socket_path, str(results/f'{tag}.icns')], capture_output=True, text=True)
    print('# proxy:', made.stdout, made.stderr, flush=True)
    bundle = made.stdout.strip()
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    app_pid = next((line.split()[0] for line in listing.splitlines() if f'Build/bench/{tag}/' in line and 'Contents/MacOS/Light Click' in line), '0')
    port = free_port()
    prefix = results/f'{tag}-window'
    for old in list(results.glob(f'{tag}-window-*.png')) + list(results.glob(f'{tag}-screen-*.png')):
        old.unlink()
    viewer = subprocess.Popen([str(results/'seamless-viewer'), '--tree', '--port', str(port), '--exit-after', str(seconds + 5), '--png', str(prefix),
                               '--screenshots', str(results/f'{tag}-screen'), '--session-socket', socket_path, '--hide-pid', app_pid,
                               '--test-input', '200,100', '--test-menu', 'Edit/Select All'], stdout=subprocess.PIPE, text=True)
    time.sleep(1)
    subprocess.run(['/usr/bin/open', bundle], check=True)
    evidence = []

    def look():
        time.sleep(seconds * 0.7)
        rows = subprocess.run(['/bin/sh', '-c', 'lsappinfo list | grep -A4 "TextEdit (Mavericks)"'], capture_output=True, text=True).stdout
        evidence.append(rows)
        windows = subprocess.run([str(results/'seamless-guest'), 'list'], capture_output=True, text=True).stdout
        evidence.append('\n'.join(w for w in windows.splitlines() if 'TextEdit (' in w or f'pid={app_pid} ' in w))
        evidence.append(f'(VM app pid {app_pid}: any row above with it is still on screen)')
        # The proxy's own menu bar, read back through the host's Accessibility.
        menu = subprocess.run([str(results/'seamless-integration-guest'), 'menu', '--app', 'TextEdit (Mavericks)'], capture_output=True, text=True).stdout
        tree = next((row for row in menu.splitlines() if row.startswith('[')), '')
        try:
            import json
            top = json.loads(tree)
            evidence.append('Host menu bar of the proxy: ' + ', '.join(item.get('title', '') for item in top) +
                            f' ({sum(len(item.get("children") or []) for item in top)} items in those menus)')
        except ValueError:
            evidence.append(f'Host menu bar of the proxy: unreadable: {menu[:300]}')

    watcher = threading.Thread(target=look)
    watcher.start()
    status, _ = run('/usr/bin/env', ['SEAMLESS_RUN_IN_PLACE=1', '/tmp/sg/g', 'tree', '--app', 'TextEdit', '--open', '--hook', '--menu-tool', '/tmp/sg/ig', '--port', str(port), '--seconds', str(seconds)])
    watcher.join()
    print(f'# guest exit {status}', flush=True)
    try:
        report, _ = viewer.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        viewer.terminate()
        report, _ = viewer.communicate()
    print(f'== Session on the host, exit {viewer.returncode}')
    print(report)
    print('== What the host reports about the proxy')
    print('\n'.join(evidence), flush=True)
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    for row in listing.splitlines():
        if f'{bundle}/Contents/MacOS/SeamlessProxy' in row:
            os.kill(int(row.split()[0]), signal.SIGKILL)
    time.sleep(1)
    print(subprocess.run([str(results/'SeamlessMakeProxy'), 'remove', bundle], capture_output=True, text=True).stdout)


if arguments[0] == 'capture-bench':
    capture_bench()
elif arguments[0] == 'placement':
    placement()
elif 'hard-stop' in arguments:
    hard_stop()
elif 'hard-stop-check' in arguments:
    hard_stop_check()
elif 'install-watcher' in arguments:
    install_watcher()
elif arguments[0] == 'desktop' and 'activation' in arguments:
    desktop(activation_only=True)
elif arguments[0] == 'desktop' and 'old-hook' in arguments:
    desktop_with_old_hook()
elif arguments[0] == 'desktop':
    desktop()
elif arguments[0] == 'windowed':
    windowed(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'mojave':
    mojave(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'tree-bench':
    tree_bench(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'proxy':
    proxy(int(arguments[1]) if len(arguments) > 1 else 28)
elif arguments[0] == 'motion':
    motion()
elif arguments[0] == 'gl':
    gl()
elif arguments[0] == 'safari':
    safari(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'diag':
    diag()
elif arguments[0] == 'stream':
    stream(int(arguments[1]) if len(arguments) > 1 else 20)
elif arguments[0] == 'input':
    input_probe()
elif arguments[0] == 'input-live':
    input_live(int(arguments[1]) if len(arguments) > 1 else 60)
elif arguments[0] == 'tree':
    tree(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'hook':
    hook(int(arguments[1]) if len(arguments) > 1 and arguments[1].isdigit() else 22)
else:
    display(arguments[1:] or default_ladder)
