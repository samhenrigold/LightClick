# Host side of scripts/seamless-integration-try. Runs inside scripts/guest-bench, which supplies channel, request, source,
# stage and tag, and has already booted the clone. Prints each measurement as it goes, then a table.
import base64
import http.server
import importlib.util
import json
import os
import re
import shutil
import threading
import time

results = source/'Build/seamless'
results.mkdir(parents=True, exist_ok=True)
tool_home = '/private/tmp/lc-seamless'
tool = f'{tool_home}/seamless-integration-guest'
table = []


def note(name, value):
    table.append((name, str(value)))
    print(f'{name}: {value}', flush=True)


def shell(script, timeout=300):
    result = request({'Executable': '/bin/sh', 'Arguments': ['-c', script]}, timeout)
    return result.get('ExitCode'), (result.get('Stdout') or '') + (result.get('Stderr') or ''), result


def helper(*arguments, timeout=180):
    result = request({'Executable': tool, 'Arguments': [*arguments, '--session']}, timeout)
    return result.get('ExitCode'), result.get('Stdout') or ''


def background(name, *arguments):
    """Starts the tool in the session, logging to a file, since a request blocks until its program ends."""
    words = ' '.join(f"'{word}'" for word in [tool, *arguments, '--session'])
    log = f'{tool_home}/{name}.log'
    shell(f'rm -f {log}; nohup {words} > {log} 2>&1 < /dev/null &')
    return log


def read_log(log):
    return shell(f'cat {log} 2>/dev/null')[1]


def wait_log(log, pattern, timeout=30):
    deadline = time.time()+timeout
    while time.time() < deadline:
        text = read_log(log)
        if re.search(pattern, text):
            return text
        time.sleep(1)
    return read_log(log)


def measure_after(text, key):
    found = re.search(rf'{key} ([\d.]+)', text)
    return found.group(1) if found else 'none'


def step(name, body):
    print(f'== {name}', flush=True)
    try:
        body()
    except Exception as error:
        note(f'{name}_error', repr(error)[:300])


def setup():
    staged = stage(results/'seamless-integration-guest')
    shell(f'mkdir -p {tool_home}; chmod 777 {tool_home}; cp {staged} {tool}; chmod 755 {tool}')
    version = shell('/usr/bin/uname -r; /usr/bin/sw_vers -productVersion')[1].split()
    note('guest', ' '.join(version))
    # AX needs a TCC row. Reading HIServices on both versions found no exemption for root, so the agent writes one, as
    # guest preparation would. The grant names the tool and what launches it into the session.
    database = '/Library/Application Support/com.apple.TCC/TCC.db'
    rows = []
    # 10.9 asks about the responsible process, which from a daemon is the agent, so that needs a row too. A row for the tool
    # alone didn't work on Mavericks.
    for client in (tool, '/usr/bin/sudo', '/usr/bin/env', '/bin/launchctl',
                   '/Library/Application Support/Virtual Intel Mac/GuestTools/opengl-install-bootstrap'):
        rows.append(f"INSERT OR REPLACE INTO access (service,client,client_type,allowed,prompt_count) VALUES "
                    f"('kTCCServiceAccessibility','{client}',1,1,1);")
    status, output, _ = shell(f"/usr/bin/sqlite3 '{database}' \"{' '.join(rows)}\"; /usr/bin/killall tccd; sleep 2")
    note('tcc_grant', f'exit {status} {output.strip()[:200]}')


apps = []


def discovery():
    status, output = helper('apps')
    lines = output.splitlines()
    for line in lines:
        if line.startswith('['):
            apps.extend(json.loads(line))
    note('apps_found', len(apps))
    note('apps_time', next((line for line in lines if line.startswith('# apps')), 'none'))
    note('apps_with_document_types', sum(1 for app in apps if app['documentTypes']))
    status, output = helper('icon', '--path', '/Applications/TextEdit.app')
    if status == 0:
        target = results/f'{tag}-TextEdit.icns'
        target.write_bytes(base64.b64decode(output.strip()))
        note('icon_bytes_over_agent', target.stat().st_size)


def open_document(path, app=None):
    # In the console user's session, so LaunchServices is theirs.
    arguments = ['open-file', '--path', path]
    if app:
        arguments += ['--with', app]
    return helper(*arguments)


def menus():
    shell(f'printf "hello\\n" > {tool_home}/note.txt; chmod 666 {tool_home}/note.txt')
    open_document(f'{tool_home}/note.txt', 'TextEdit')
    helper('open-file', '--path', '/Applications/Calculator.app')
    time.sleep(5)
    log = background('watch', 'menu-watch', '--app', 'Calculator', '--seconds', '40')
    time.sleep(3)
    for app in ('TextEdit', 'Finder', 'Calculator'):
        full, top = [], []
        for _ in range(3):
            status, output = helper('menu', '--app', app)
            full.append(measure_after(output, 'menu_read_ms'))
            status, part = helper('menu', '--app', app, '--top', 'File')
            top.append(measure_after(part, 'menu_read_ms'))
        note(f'{app}_full_bar_read_ms', ' '.join(full))
        note(f'{app}_one_menu_read_ms', ' '.join(top))
        if 'trusted 0' in output:
            note('ax_trusted', 'NO: the grant did not take')
        note(f'{app}_items', measure_after(output, 'items'))
        for line in output.splitlines():
            if line.startswith('['):
                tree = json.loads(line)
                (results/f'{tag}-{app}-menu.json').write_text(line)
                note(f'{app}_top', [item['title'] for item in tree])

                def count(items, key):
                    return sum(bool(item.get(key)) + count(item.get('children') or [], key) for item in items)
                note(f'{app}_alternates_marks_keys', (count(tree, 'isAlternate'), count(tree, 'mark'), count(tree, 'key')))
    status, before = helper('menu', '--app', 'Calculator', '--top', 'View')
    start = time.time()
    status, press = helper('press', '--app', 'Calculator', '--path', 'View/Scientific')
    note('press_result', f'exit {status} {press.strip()}')
    status, after = helper('menu', '--app', 'Calculator', '--top', 'View')
    note('press_changed_marks', before != after)
    helper('press', '--app', 'Calculator', '--path', 'View/Basic')
    note('press_round_trip_s', f'{time.time()-start:.1f} through the agent')
    time.sleep(2)
    note('menu_notifications', read_log(log).replace('\n', ' | ')[:800])
    note('extras', helper('extras', '--app', 'SystemUIServer')[1].strip()[:400])


def badge():
    log = background('badge', 'badge-self', '--seconds', '30')
    text = wait_log(log, r'ready pid (\d+)')
    found = re.search(r'ready pid (\d+)', text)
    if not found:
        note('badge', text[:200])
        return
    time.sleep(2)
    status, output = helper('status', '--pid', found.group(1))
    note('badge_and_attention_from_outside', output.replace('\n', ' | ')[:500])


screen = {}


def tablet(x, y, button=None):
    events = [{'type': 'abs', 'data': {'axis': 'x', 'value': int(x*32767/screen['w'])}},
              {'type': 'abs', 'data': {'axis': 'y', 'value': int(y*32767/screen['h'])}}]
    if button is not None:
        events.append({'type': 'btn', 'data': {'button': 'left', 'down': button}})
    request({'Action': 'input', 'Events': events}, 30)


def window_frame(app):
    status, output = helper('title', '--app', app)
    for line in output.splitlines():
        if line.startswith('['):
            windows = json.loads(line)
            if windows:
                return windows[0]
    return None


def drag(backend, file, target, name, start=(40, 40)):
    log = background(f'drag-{backend}', 'drag-in', '--backend', backend, '--file', file)
    watch = background(f'watch-{backend}', 'drag-watch', '--seconds', '60')
    text = wait_log(log, 'ready')
    if 'ready' not in text:
        note(f'{name}_helper', text[:300])
        return ''
    tablet(*start, False)
    time.sleep(1)
    began = time.time()
    tablet(*start, True)
    time.sleep(3)
    for fraction in (0.25, 0.5, 0.75, 0.97, 1):
        tablet(start[0]+(target[0]-start[0])*fraction, start[1]+(target[1]-start[1])*fraction)
        time.sleep(0.5)
    time.sleep(2)
    frame = request({'Action': 'capture'}, 180)
    if frame.get('Captured') and (channel/'Frame.png').exists():
        shutil.copyfile(channel/'Frame.png', results/f'{tag}-{name}-hover.png')
    tablet(*target, False)
    text = wait_log(log, 'drag_ended', 30)
    note(f'{name}_seconds', f'{time.time()-began:.1f} including the agent poll')
    note(f'{name}_tool', text.replace('\n', ' | ')[:400])
    note(f'{name}_pasteboard_seen', read_log(watch).replace('\n', ' | ')[:400])
    return text


def drags():
    status, output = helper('screen')
    found = re.search(r'screen (\d+) (\d+)', output)
    if not found:
        raise RuntimeError(f'no screen: {output}')
    screen.update(w=int(found.group(1)), h=int(found.group(2)))
    note('screen', output.strip())
    source_file = f'{tool_home}/Dropped Note.txt'
    shell(f"printf 'dropped\\n' > '{source_file}'; chmod 644 '{source_file}'")
    for backend in ('ns', 'coredrag'):
        # A real app, with a real destination: copying into a Finder window, and its highlight, is the proof.
        folder = f'{tool_home}/drop-{backend}'
        shell(f'rm -rf {folder}; mkdir -p {folder}; chmod 777 {folder}')
        helper('open-file', '--path', folder)
        time.sleep(4)
        window = window_frame('Finder')
        if not window:
            note(f'finder_{backend}', 'no Finder window')
            continue
        target = (window['x']+window['w']/2, window['y']+window['h']/2)
        drag(backend, source_file, target, f'drop_on_finder_{backend}')
        time.sleep(2)
        note(f'finder_{backend}_copied', shell(f'ls {folder}')[1].strip() or 'nothing arrived')
        # And TextEdit, which takes a file by inserting it, marking its document edited.
        window = window_frame('TextEdit')
        if window:
            helper('open-file', '--path', f'{tool_home}/note.txt', '--with', 'TextEdit')
            time.sleep(2)
            drag(backend, source_file, (window['x']+window['w']/2, window['y']+window['h']/2), f'drop_on_textedit_{backend}')
            time.sleep(2)
            note(f'textedit_{backend}_title', helper('title', '--app', 'TextEdit')[1].strip()[:200])


def drag_out():
    # The sink stands where a drag goes after leaving a proxy. The source is the tool here; see the doc for Finder.
    sink = background('sink', 'drag-sink', '--seconds', '60', '--promises', f'{tool_home}')
    wait_log(sink, 'ready')
    source_file = f'{tool_home}/Dropped Note.txt'
    # The shield and the sink share a level, and the later one is on top, so only the source's first click needs it gone.
    drag('ns', source_file, (screen['w']/2, screen['h']/2), 'drag_out_to_sink')
    text = wait_log(sink, 'sink_concluded', 15)
    note('drag_out_sink', text.replace('\n', ' | ')[:600])
    image = shell(f'ls -la {tool_home}/drag-image.png')[1].strip()
    note('drag_out_image', image[:200])


def transports():
    big = results/f'{tag}-64MiB.bin'
    # The guest agent, the only path needing no network. Small: before Metal it sends 256 bytes per acknowledged write,
    # and a stage that passes guest-bench's 900 s ends the whole run.
    big.write_bytes(os.urandom(2 << 20))
    start = time.time()
    stage(big)
    note('agent_write_MB_s', f'{2/(time.time()-start):.3f}')
    big.write_bytes(os.urandom(1 << 20)*64)
    # Over slirp, which is what any TCP share travels. Loopback only on the host side.

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *handler_arguments, **options):
            super().__init__(*handler_arguments, directory=str(results), **options)

        def log_message(self, *ignored):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Quiet)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    status, output, _ = shell(f"/usr/bin/curl -s -o /dev/null -w '%{{time_total}}' http://10.0.2.2:{server.server_address[1]}/{big.name}")
    note('slirp_tcp_to_guest', f'exit {status}, {output.strip()} s for 64 MiB')
    server.shutdown()
    big.unlink()


def file_identity():
    spec = importlib.util.spec_from_file_location('nfs3_server', source/'probes/nfs3-server.py')
    nfs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nfs)
    share = results/f'{tag}-share'
    shutil.rmtree(share, ignore_errors=True)
    share.mkdir()
    document = share/'Report.txt'
    document.write_text('host original\n')
    (share/'large.bin').write_bytes(os.urandom(1 << 20)*256)
    server, listener, port = nfs.listen(str(share))
    mount = '/Volumes/LightClickHost'
    status, output, _ = shell(f'mkdir -p {mount}; /sbin/mount_nfs -o vers=3,tcp,port={port},mountport={port},nolocks,nfsvers=3 10.0.2.2:/ {mount}', 120)
    note('nfs_mount', f'exit {status} {output.strip()[:300]}')
    if status != 0:
        return
    note('nfs_guest_sees', shell(f'ls -la {mount}')[1].strip()[:300])
    status, output, _ = shell(f'/usr/bin/time /bin/dd if={mount}/large.bin of=/dev/null bs=1048576 2>&1')
    note('nfs_read_256MiB_in_place', output.strip().replace('\n', ' | ')[:300])
    status, output, _ = shell(f'/usr/bin/time /bin/dd if=/dev/zero of={mount}/written.bin bs=1048576 count=64 2>&1')
    note('nfs_write_64MiB', output.strip().replace('\n', ' | ')[:300])
    note('nfs_host_sees_write', (share/'written.bin').stat().st_size if (share/'written.bin').exists() else 'no')
    # Forks and type codes, written the way old apps do, and where they land.
    finder_info = 'TEXTttxt'.encode().hex() + '00'*24
    shell(f'/usr/bin/xattr -wx com.apple.FinderInfo {finder_info} {mount}/Report.txt; /usr/bin/xattr -w com.apple.ResourceFork x {mount}/Report.txt')
    note('type_code_read_back_in_guest', shell(f'/usr/bin/xattr -l {mount}/Report.txt | head -5')[1].strip()[:200])
    note('sidecars_on_host', sorted(entry.name for entry in share.iterdir() if entry.name.startswith('._')))
    # A lock is only local to the guest with nolocks.
    note('flock_in_guest', shell(f"/usr/bin/python -c \"import fcntl;f=open('{mount}/Report.txt');fcntl.flock(f,fcntl.LOCK_EX);print('locked')\"")[1].strip()[:200])
    # The whole point: open it from the share, change it, save in place.
    before = document.stat().st_ino
    open_document(f'{mount}/Report.txt', 'TextEdit')
    time.sleep(6)
    note('document_window', helper('title', '--app', 'TextEdit')[1].strip()[:200])
    request({'Action': 'input', 'Events': [{'type': 'key', 'data': {'key': {'type': 'qcode', 'data': 'x'}, 'down': True}},
                                           {'type': 'key', 'data': {'key': {'type': 'qcode', 'data': 'x'}, 'down': False}}]}, 30)
    time.sleep(2)
    note('save_press', helper('press', '--app', 'TextEdit', '--path', 'File/Save')[1].strip()[:200])
    time.sleep(5)
    note('saved_on_host', repr(document.read_text()[:80]))
    note('save_kept_inode', document.stat().st_ino == before)
    note('left_on_host', sorted(entry.name for entry in share.iterdir()))
    shell(f'/sbin/umount -f {mount}')
    listener.close()
    shutil.rmtree(share, ignore_errors=True)


step('setup', setup)
step('discovery', discovery)
step('menus', menus)
step('badge', badge)
step('drags', drags)
step('drag_out', drag_out)
step('transports', transports)
step('file_identity', file_identity)

print('== Results')
for name, value in table:
    print(f'{name}: {value}')
print(f'# Hover frames, menus and the icon are in {results}/{tag}-*. Check the Finder window highlights in each hover frame.')
