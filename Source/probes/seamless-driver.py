# Host side of scripts/seamless-try. Runs inside scripts/guest-bench, which supplies arguments, channel, request, source,
# stage and tag, and has already booted the clone.
import re
import shutil
import socket
import subprocess
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


def tree(seconds):
    print(f'== Every window of a demo app, for {seconds} s', flush=True)
    guest = stage(guest_tool)
    port = free_port()
    prefix = results/f'{tag}-window'
    for old in results.glob(f'{tag}-window-*.png'):
        old.unlink()
    viewer = subprocess.Popen([str(results/'seamless-viewer'), '--tree', '--port', str(port), '--exit-after', str(seconds + 5),
                               '--png', str(prefix)], stdout=subprocess.PIPE, text=True)
    status, _ = run(guest, ['program-tree', '--port', str(port), '--seconds', str(seconds)])
    print(f'# guest exit {status}', flush=True)
    try:
        report, _ = viewer.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        viewer.terminate()
        report, _ = viewer.communicate()
    print(f'== Viewer on the host, exit {viewer.returncode}')
    print(report)
    print(f'# Each window is in {prefix}-<id>.png. Look for the shadow around the document window, the popover past its '
          'edge, the panel, the menu and the sheet.')


def ws_probe():
    # Uses a reboot, since launchd only reads a job's environment when it loads. This is a clone, so the edit goes with it.
    print('== Read-only probe inside WindowServer', flush=True)
    version = request({'Executable': '/usr/bin/uname', 'Arguments': ['-r']}, 60).get('Stdout', '')
    if not version.startswith('13.'):
        raise SystemExit(f'This probe is for 10.9, with its symbol names; this is Darwin {version.strip()}.')
    staged = stage(results/'seamless-ws-probe.dylib')
    plist = '/System/Library/LaunchDaemons/com.apple.WindowServer.plist'
    install = ('set -e; cp "$1" /var/tmp/seamless-ws-probe.dylib; chmod 755 /var/tmp/seamless-ws-probe.dylib; '
               'rm -f /var/tmp/seamless-ws-probe.log; '
               f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" {plist} || true; '
               f'/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string '
               f'/var/tmp/seamless-ws-probe.dylib" {plist}; /usr/bin/plutil -lint {plist}')
    result = request({'Executable': '/bin/sh', 'Arguments': ['-c', install, 'sh', staged]}, 120)
    print(result.get('Stdout', ''), result.get('Stderr', ''), flush=True)
    if result.get('ExitCode') != 0:
        raise SystemExit('Could not install the probe')
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
        if log.count('-- sample') >= 4:
            break
        time.sleep(15)
    target = results/f'{tag}.log'
    target.write_text(log)
    state = request({'Executable': '/usr/bin/pgrep', 'Arguments': ['-lx', 'WindowServer']}, 60)
    print(f'# WindowServer: {state.get("Stdout", "").strip() or "NOT RUNNING"}')
    print(f'# {len(log.splitlines())} lines in {target}. First lines:')
    print('\n'.join(log.splitlines()[:30]))
    size = capture(f'{tag}-frame.png')
    print(f'# frame {size}: does the desktop still look right?')


if arguments[0] == 'stream':
    stream(int(arguments[1]) if len(arguments) > 1 else 20)
elif arguments[0] == 'input':
    input_probe()
elif arguments[0] == 'input-live':
    input_live(int(arguments[1]) if len(arguments) > 1 else 60)
elif arguments[0] == 'tree':
    tree(int(arguments[1]) if len(arguments) > 1 else 22)
elif arguments[0] == 'ws-probe':
    ws_probe()
else:
    display(arguments[1:] or default_ladder)
