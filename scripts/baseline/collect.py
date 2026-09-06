#!/usr/bin/env python3
"""Collect read-only installed-app samples and summarize explicit fixture runs."""
import argparse
import hashlib
import json
import math
import platform
import socket
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = Path('/Applications/Voxa.app')
EXECUTABLES = [APP / 'Contents/MacOS/Voxa', APP / 'Contents/Resources/bin/voxa-daemon']


def command(args):
    result = subprocess.run(args, text=True, capture_output=True, cwd=ROOT)
    return {'exit_code': result.returncode, 'output': (result.stdout + result.stderr).strip()}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def provenance():
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT
    ).decode().split('\0')
    hashes = {name: digest(ROOT / name) for name in sorted(set(names))
              if name and (ROOT / name).is_file()}
    return {
        'captured_at': datetime.now(timezone.utc).isoformat(),
        'branch': command(['git', 'branch', '--show-current'])['output'],
        'head': command(['git', 'rev-parse', 'HEAD'])['output'],
        'dirty': bool(command(['git', 'status', '--porcelain'])['output']),
        'source_sha256': hashes,
        'installed_executable_sha256': {str(p): digest(p) for p in EXECUTABLES if p.exists()},
        'installed_source_revision': 'unknown; installed artifact is separate from source fixture build',
        'os': command(['sw_vers']), 'machine': platform.machine(),
        'hardware': command(['sysctl', '-n', 'hw.model']),
        'swift': command(['swift', '--version']), 'rust': command(['rustc', '--version']),
    }


def request(method):
    # A fresh socket and handshake mirror IPCTransport.request. Read-only methods only.
    assert method in ('health', 'get_state')
    path = Path.home() / 'Library/Application Support/voxa/run/daemon.sock'
    start = time.perf_counter_ns()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        reader = connection.makefile('rb')
        with reader:
            def receive():
                line = reader.readline(1024 * 1024)
                if not line.endswith(b'\n'):
                    raise RuntimeError('Missing or oversized IPC frame')
                return json.loads(line)

            connection.sendall(b'{"type":"hello","api_version":"1.0","client":"baseline"}\n')
            if receive().get('type') != 'hello_ok':
                raise RuntimeError('IPC handshake failed')
            message = {'type': 'request', 'id': 'baseline', 'method': method, 'params': {}}
            connection.sendall((json.dumps(message) + '\n').encode())
            reply = receive()
            if reply.get('type') != 'response' or reply.get('id') != 'baseline' or not reply.get('ok'):
                raise RuntimeError('Read-only IPC request failed')
            return reply['result'], (time.perf_counter_ns() - start) / 1_000_000


def process_sample():
    result = subprocess.run(['ps', '-axo', 'pid=,rss=,time=,comm='], capture_output=True, text=True, check=True)
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4 or fields[3] not in {str(p) for p in EXECUTABLES}:
            continue
        pid, rss, cpu, executable = fields
        days = 0
        if '-' in cpu:
            day, cpu = cpu.split('-', 1)
            days = int(day)
        seconds = 0.0
        for part in cpu.split(':'):
            seconds = seconds * 60 + float(part)
        rows.append({'pid': int(pid), 'rss_kib': int(rss),
                     'cpu_seconds': days * 86400 + seconds, 'executable': executable})
    return rows


def live_samples(count, interval):
    result = {'kind': 'installed_app', 'clock': 'time.perf_counter_ns',
              'metrics_ms': {}, 'resource_samples': [], 'limitations': [
                  'Read-only IPC; no recording, paste, restart, Keychain read, or external request',
                  'IPC timings include a fresh connection and handshake from Python, not a Swift hotkey',
                  'CPU is derived from ps cumulative CPU time; RSS may count shared pages twice']}
    try:
        state, _ = request('get_state')
        if state.get('state') != 'idle':
            raise RuntimeError('Installed daemon is not idle')
        for method in ('health', 'get_state'):
            measurements = []
            for i in range(count + 3):
                reply, elapsed = request(method)
                if method == 'get_state' and reply.get('state') != 'idle':
                    raise RuntimeError('Recording state changed during measurement')
                if i >= 3:
                    measurements.append(elapsed)
            result['metrics_ms'][method + '_fresh_connection'] = measurements
        for i in range(count):
            state, _ = request('get_state')
            rows = process_sample()
            if state.get('state') != 'idle' or len(rows) != 2:
                raise RuntimeError('Idle installed app and daemon are both required for resource sampling')
            result['resource_samples'].append({'monotonic_ns': time.perf_counter_ns(), 'processes': rows})
            if i + 1 < count:
                time.sleep(interval)
        result['status'] = 'complete'
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        result['status'] = 'incomplete'
        result['reason'] = str(error)
    return result


def stats(values):
    ordered = sorted(values)
    return {'n': len(values), 'median': statistics.median(ordered),
            'p95_nearest_rank': ordered[math.ceil(len(ordered) * .95) - 1],
            'min': ordered[0], 'max': ordered[-1]}


def summarize(folder):
    report = {'schema_version': 1, 'metrics': {}, 'pending': [
        'actual hotkey to first microphone buffer', 'stop to real upload initiation',
        'live transcription service latency', 'cold and warm signed-app startup',
        'real foreground-app paste', 'peak memory at recording limits',
        'speech clipping, hotkeys, permissions, device changes, and sleep/wake']}
    for filename in ('fixture-metrics.json', 'installed-metrics.json', 'output-metrics.json'):
        path = folder / filename
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        for name, values in data.get('metrics_ms', {}).items():
            if values:
                report['metrics'][data['kind'] + '/' + name] = {'unit': 'ms', **stats(values)}
        if data.get('status') == 'incomplete':
            report.setdefault('limitations', []).append(data['reason'])
        if data.get('status') == 'complete' and data.get('resource_samples'):
            samples = data['resource_samples']
            rss = [sum(p['rss_kib'] for p in s['processes']) / 1024 for s in samples]
            cpu = []
            for a, b in zip(samples, samples[1:]):
                if {p['pid'] for p in a['processes']} != {p['pid'] for p in b['processes']}:
                    continue
                delta = sum(p['cpu_seconds'] for p in b['processes']) - sum(p['cpu_seconds'] for p in a['processes'])
                cpu.append(100 * delta / ((b['monotonic_ns'] - a['monotonic_ns']) / 1e9))
            report['metrics']['installed_app/combined_idle_rss'] = {'unit': 'MiB', **stats(rss)}
            if cpu:
                report['metrics']['installed_app/combined_idle_cpu'] = {'unit': '% of one core', **stats(cpu)}
    save(folder / 'summary.json', report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--provenance-only', action='store_true')
    args = parser.parse_args()
    if args.provenance_only:
        save(args.directory / 'provenance.json', provenance())
    else:
        before = json.loads((args.directory / 'provenance.json').read_text())
        if before['source_sha256'] != provenance()['source_sha256']:
            raise SystemExit('Source changed during fixture build; rerun with a stable checkout')
        save(args.directory / 'installed-metrics.json', live_samples(30, 1))
        summarize(args.directory)
        print(args.directory / 'summary.json')
