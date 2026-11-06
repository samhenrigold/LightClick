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


def desktop():
    # The Seamless button, on a running machine: press, the apps' windows appear and the machine's goes, a click reaches one, press,
    # and the machine's window is back.
    guest = stage(guest_tool)
    for app in ('TextEdit', 'Safari'):
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
        pids = {row.split()[0] for row in running if 'Seamless Apps/' in row}
        return [row for row in rows() if re.search(r'pid=(\d+)', row).group(1) in pids and ' 0x0' not in row]

    checks = []

    def check(what, passed):
        checks.append(passed)
        print(f'{"PASS" if passed else "FAIL"} {what}', flush=True)

    def proxy_pid(name):
        found = next((row for row in proxy_windows() if f'owner="{name}' in row), '')
        match = re.search(r'pid=(\d+)', found)
        return int(match.group(1)) if match else 0

    check('the machine window shows before the press', bool(machine_window()))
    print(next(iter(rows()), ''), flush=True)
    pressed = time.time()
    request({'Action': 'seamless-toggle'}, 60)
    windows = []
    first = None
    while time.time() - pressed < 180 and (len(windows) < 2 or machine_window()):
        windows = proxy_windows()
        if windows and first is None:
            first = time.time() - pressed
        time.sleep(0.1)
    print(f'first window after {first} s, machine window gone after {time.time() - pressed:.1f} s', flush=True)
    for row in windows:
        print(row[:150], flush=True)
    check('windows appear for each app', len(windows) >= 2)
    for _ in range(3):
        print('settling', time.time() - pressed, [row[-30:] for row in proxy_windows()], flush=True)
        time.sleep(1)
    check('the machine window hides', not machine_window())
    for row in windows:
        window = re.search(r'id=(\d+)', row).group(1)
        subprocess.run(['screencapture', '-x', '-o', '-l', window, str(results/f'{tag}-desktop-{window}.png')])
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
    moving = subprocess.run([meter, window or '0', '8'], capture_output=True, text=True).stdout
    print('moving', moving, flush=True)
    # Moved on the host, past where the machine's window was: the guest's doesn't follow, it still moves, and a click still lands.
    def place(of):
        row = next((row for row in rows() if f'id={of} ' in row), '')
        print('at', time.time() - pressed, row[-40:], flush=True)
        found = re.search(r'bounds=(-?[\d.]+),(-?[\d.]+)', row)
        return (float(found.group(1)), float(found.group(2))) if found else None
    if safari and window:
        before = place(window)
        os.kill(safari, signal.SIGUSR2)
        time.sleep(2)
        after = place(window)
        print('moved from', before, 'to', after, flush=True)
        check('a window moves on the host', before is not None and after is not None and before != after)
        subprocess.run(['screencapture', '-x', '-o', '-l', window, str(results/f'{tag}-desktop-moved.png')])
        clicks.write_text('')
        timing = subprocess.Popen([meter, window, '5', '--clicks', str(clicks)], stdout=subprocess.PIPE, text=True)
        for _ in range(4):
            os.kill(safari, signal.SIGUSR1)
            time.sleep(1)
        said = timing.communicate()[0]
        print(said, flush=True)
        check('input still reaches it there', re.search(r'median \d+ ms', said) is not None)
        check('it stayed there', place(window) == after)
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
    # Generated apps shouldn't stay known to the Mac after a clone's gone.
    for bundle in (source/'Build/bench'/tag).glob('**/Seamless Apps/*/*/*.app'):
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(bundle)])
    print('PASS seamless button' if all(checks) and machine_window() else 'FAIL seamless button', flush=True)


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
