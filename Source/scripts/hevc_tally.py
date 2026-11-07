"""Read-only preservation and parsing of Engine's existing periodic text tallies.

TrStats fields repeat global translator counters in every vCPU file; monitor lock counters aggregate all vCPUs into c0. Never sum those fields.
A file publication is asynchronous; timestamps below describe host observations, not exact draw boundaries.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import threading
import time

GLOBAL_LABELS = {'cold blocks', 'cold x86 insns', 'cold ARM words', 'blocks invalidated'}


def parse_tally(text):
    if not text.startswith('# hvdbt tally.'):
        raise ValueError('not an Engine tally')
    elapsed = re.search(r'^seconds since hand-off: ([0-9.]+)$', text, re.M)
    if not elapsed or not math.isfinite(float(elapsed[1])):
        raise ValueError('missing tally elapsed time')
    result = dict(elapsed_since_handoff_seconds=float(elapsed[1]), per_cpu={}, per_cpu_gauges={}, global_translator={}, global_monitor={},
                  fallbacks={}, fallback_sites=[], svc={}, host_calls={}, invalidation_profile={})
    section = ''
    for line in text.splitlines():
        if line.startswith('==') or line.startswith('monitor calls by SVC_'):
            section = line
        count = re.fullmatch(r'(.+?)\s{2,}(\d+)\s+\d+/s', line)
        if count:
            label = count[1].strip()
            group = 'global_translator' if label in GLOBAL_LABELS else 'per_cpu_gauges' if label == 'deepest monitor stack, bytes' else 'per_cpu'
            result[group][label] = int(count[2])
        if section.startswith('== stops and fallbacks'):
            row = re.fullmatch(r'\s*(\d+)\s+([0-9.]+)\s{2,}(.+)', line)
            if row:
                result['fallbacks'][row[3]] = dict(count=int(row[1]), tcg_wall_away_milliseconds=float(row[2]))
        elif section.startswith('== by site:'):
            row = re.fullmatch(r'\s*(\d+)\s{2,}(.+)\s+@(0x[0-9a-f]+)\s+(0x[0-9a-f]+)', line)
            if row:
                result['fallback_sites'].append(dict(count=int(row[1]), key=row[2].strip(), first_rip=row[3], detail=row[4]))
        elif section.startswith('monitor calls by SVC_'):
            row = re.fullmatch(r'\s*(\d+),\s+[0-9.]+/s\s+(\d+)', line)
            if row:
                result['svc'][row[2]] = int(row[1])
        elif section.startswith('== sampled invalidation cost'):
            row = re.fullmatch(r'(invalidation_[a-z_]+) (\d+)', line)
            if row:
                result['invalidation_profile'][row[1]] = int(row[2])
        elif section.startswith('== where the time goes:'):
            row = re.fullmatch(r'\s*(\d+)\s+([0-9.]+)\s+([0-9.]+)\s+(\d+)', line)
            if row:
                result['host_calls'][row[4]] = dict(count=int(row[1]), total_seconds=float(row[2]))
    translation = re.search(r'^translation time\s+([0-9.]+) ms$', text, re.M)
    if translation:
        result['global_translator']['translation_milliseconds'] = float(translation[1])
    wait = re.search(r'^monitor lock waited ([0-9.]+) s; held, s: (.+)$', text, re.M)
    if wait:
        result['global_monitor']['monitor_lock_wait_seconds'] = float(wait[1])
        for name, value in re.findall(r'(other|view switch|before translating|after|fault|table store) ([0-9.]+)', wait[2]):
            result['global_monitor']['monitor_lock_hold_' + name.replace(' ', '_') + '_seconds'] = float(value)
    invalidate = re.search(r'^page invalidations: (\d+), ([0-9.]+) s waiting for the translator lock, ([0-9.]+) s in all$', text, re.M)
    if invalidate:
        result['per_cpu'].update(page_invalidations=int(invalidate[1]),
                                 page_invalidation_lock_wait_seconds=float(invalidate[2]),
                                 page_invalidation_seconds=float(invalidate[3]))
    required_cpu = {'shadow fills', 'interrupts delivered', 'arm steps to a boundary', 'page_invalidations'}
    required_global = {'cold blocks', 'blocks invalidated', 'translation_milliseconds'}
    if (not required_cpu <= result['per_cpu'].keys() or not required_global <= result['global_translator'].keys()
            or 'monitor_lock_wait_seconds' not in result['global_monitor']):
        raise ValueError('tally lacks required phase counters')
    return result


def differences(before, after):
    """Cumulative dictionary subtraction. Missing-at-start rows start at zero; disappearing/regressing rows are errors."""
    out = {}
    for key in sorted(set(before) | set(after)):
        a, b = before.get(key, 0), after.get(key)
        if b is None:
            raise ValueError('counter disappeared: ' + key)
        if isinstance(b, dict):
            if not isinstance(a, dict) and a != 0:
                raise ValueError('counter shape changed: ' + key)
            out[key] = differences(a if isinstance(a, dict) else {}, b)
        else:
            if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or b < a:
                raise ValueError('counter regressed: ' + key)
            out[key] = b - a
    return out


def interval(before, after):
    if after['parsed']['elapsed_since_handoff_seconds'] <= before['parsed']['elapsed_since_handoff_seconds']:
        raise ValueError('tally interval did not advance')
    result = dict(host_observed_start=before['observed_monotonic_seconds'],
                  host_observed_end=after['observed_monotonic_seconds'],
                  tally_elapsed_seconds=after['parsed']['elapsed_since_handoff_seconds'] - before['parsed']['elapsed_since_handoff_seconds'],
                  start_snapshot=before['file'], end_snapshot=after['file'])
    for key in ('per_cpu', 'global_translator', 'global_monitor', 'fallbacks', 'host_calls', 'invalidation_profile'):
        # Enabled/profile mode is configuration, not an accumulatable counter.
        a, b = dict(before['parsed'][key]), dict(after['parsed'][key])
        if key == 'invalidation_profile':
            enabled = b.pop('invalidation_profile_enabled', None)
            if a.pop('invalidation_profile_enabled', None) != enabled:
                raise ValueError('invalidation profiling mode changed')
            result['invalidation_profile_enabled'] = enabled
        result[key] = differences(a, b)
    a, b = before['parsed']['svc'], after['parsed']['svc']
    result['svc_count_deltas_common_top20'] = {key: b[key]-a[key] for key in set(a)&set(b) if b[key] >= a[key]}
    result['svc_newly_printed_end_counts'] = {key: b[key] for key in set(b)-set(a)}
    result['svc_no_longer_printed'] = sorted(set(a)-set(b))
    result['svc_common_rows_regressed'] = sorted(key for key in set(a)&set(b) if b[key] < a[key])
    result['svc_note'] = 'Top20 rows only: newly printed end counts are cumulative, not interval deltas; disappearing rows may rank out.'
    result['per_cpu_gauges'] = {'start': before['parsed']['per_cpu_gauges'], 'end': after['parsed']['per_cpu_gauges'],
                               'note': 'High-water gauges; do not subtract as a measure of stack depth.'}
    a = {row['key']: row['count'] for row in before['parsed']['fallback_sites']}
    b = {row['key']: row['count'] for row in after['parsed']['fallback_sites']}
    # Only top 200 sites are printed. A disappearing row may have fallen below the cutoff, not reset.
    result['fallback_site_count_deltas_common'] = {key: b[key]-a[key] for key in set(a) & set(b) if b[key] >= a[key]}
    result['fallback_sites_newly_printed_end_counts'] = {key: b[key] for key in set(b)-set(a)}
    result['fallback_sites_no_longer_printed'] = sorted(set(a)-set(b))
    result['fallback_site_note'] = 'Top200 rows only. Newly printed cumulative counts cannot be attributed to this interval.'
    return result


class TallyCollector:
    def __init__(self, prefix, cpu_count, output):
        self.paths = [Path(str(prefix) + ('' if cpu == 0 else '.cpu' + str(cpu))) for cpu in range(cpu_count)]
        self.output = Path(output)
        self.output.mkdir()
        self.samples = [[] for _ in self.paths]
        self.errors = []
        self.stop_event = threading.Event()
        self.lock = threading.Lock()
        self.worker = None

    def poll(self):
        for cpu, path in enumerate(self.paths):
            try:
                info = path.lstat()
                if not path.is_file() or path.is_symlink() or not 0 < info.st_size <= 16 * 1024 * 1024:
                    raise ValueError('invalid tally file')
                data = path.read_bytes()
                digest = hashlib.sha256(data).hexdigest()
                with self.lock:
                    if self.samples[cpu] and self.samples[cpu][-1]['sha256'] == digest:
                        continue
                parsed = parse_tally(data.decode('utf-8'))
                observed = time.monotonic()
                with self.lock:
                    name = 'cpu%d-%06d.txt' % (cpu, len(self.samples[cpu]))
                    (self.output/name).write_bytes(data)
                    row = dict(cpu=cpu, file=name, sha256=digest, observed_monotonic_seconds=observed,
                               source_mtime_ns=info.st_mtime_ns, parsed=parsed)
                    self.samples[cpu].append(row)
                    with (self.output/'index.jsonl').open('a') as file:
                        file.write(json.dumps(row, sort_keys=True)+'\n')
            except FileNotFoundError:
                continue
            except (OSError, UnicodeError, ValueError) as error:
                with self.lock:
                    if len(self.errors) < 100:
                        self.errors.append(dict(cpu=cpu, error=repr(error), at=time.monotonic()))

    def start(self):
        def monitor():
            while not self.stop_event.is_set():
                self.poll()
                self.stop_event.wait(.25)
        self.worker = threading.Thread(target=monitor, name='hevc-tally-reader', daemon=True)
        self.worker.start()

    def stop(self):
        self.stop_event.set()
        if self.worker:
            self.worker.join(timeout=10)
            if self.worker.is_alive():
                raise RuntimeError('tally collector did not stop')

    def phase(self, start, end):
        """Use publications observed strictly inside the phase, excluding its coarsely observed edges."""
        result = dict(start_monotonic_seconds=start, end_monotonic_seconds=end, per_cpu={}, errors=[],
                      note='Periodic ~2s publications; no exact draw-boundary or per-process attribution. Translator fields repeat across vCPUs; monitor lock counters aggregate all vCPUs into c0. Neither is summed.')
        with self.lock:
            for cpu, rows in enumerate(self.samples):
                selected = [row for row in rows if start + 2.5 <= row['observed_monotonic_seconds'] <= end]
                try:
                    if len(selected) < 2:
                        raise ValueError('fewer than two interior publications')
                    delta = interval(selected[0], selected[-1])
                    global_fields = {key: delta.pop(key) for key in ('global_translator', 'global_monitor', 'invalidation_profile', 'invalidation_profile_enabled')}
                    if cpu == 0:
                        result.update(global_fields)
                    result['per_cpu'][str(cpu)] = delta
                except ValueError as error:
                    result['errors'].append(dict(cpu=cpu, error=str(error)))
        result['global_translator_source_cpu'] = 0
        result['global_monitor_source_cpu'] = 0
        result['timing_interpretation'] = ('Fallback wall-away time is not TCG CPU. Host-call elapsed time overlaps page-invalidation time and sampled invalidation substeps; never add them into total CPU. Each vCPU has its own asynchronous publication interval.')
        result['all_expected_vcpus_present'] = len(result['per_cpu']) == len(self.paths)
        return result
