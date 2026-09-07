#!/usr/bin/env python3
"""Run repeatable Swift fixtures against loopback HTTP; never use the user's key or microphone."""
import argparse
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'apps/voxa-menubar/Sources/VoxaMenuBar'


def stats(values):
    ordered = sorted(values)
    return dict(n=len(values), median=statistics.median(values),
                p95=ordered[math.ceil(len(values) * .95) - 1], min=min(values), max=max(values))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(folder, fixture):
    folder.mkdir(parents=True, exist_ok=False, mode=0o700)
    sources = [SOURCE / x for x in ['Models.swift', 'AudioCaptureDevice.swift', 'AudioWAVEncoder.swift',
               'AudioRecorder.swift', 'TranscriptionClient.swift', 'ClipboardPaste.swift', 'TranscriptOutput.swift']]
    sources.append(Path(__file__).with_name('NativeBaseline.swift'))
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sources + [Path(__file__)]}
    build = ROOT / 'apps/voxa-menubar/.build/native-baseline'
    build.mkdir(parents=True, exist_ok=True)
    executable = build / 'native-baseline'
    with (folder / 'build.log').open('w') as log:
        subprocess.run(['swiftc', '-O', '-parse-as-library', '-warnings-as-errors',
                        '-target', platform.machine() + '-apple-macosx13.0', '-module-cache-path', str(build / 'module-cache'),
                        *map(str, sources), '-o', str(executable)], check=True, stdout=log, stderr=subprocess.STDOUT)
    audio = fixture.read_bytes()
    assert len(audio) == 320044
    received = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get('Content-Length', '0'))
            if length > 1024 * 1024:
                self.send_error(413)
                return
            body = self.rfile.read(length)
            valid = (self.path == '/v1/audio/transcriptions'
                     and self.headers.get('Authorization') == 'Bearer fixture-only' and audio in body)
            received.append(valid)
            if not valid:
                self.send_error(400)
                return
            time.sleep(.05)
            response = b'{"text":"fixture transcript"}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with (folder / 'run.log').open('w') as log:
            subprocess.run([str(executable), str(folder), str(fixture),
                            f'http://127.0.0.1:{server.server_port}/v1/audio/transcriptions'],
                           check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    finally:
        server.shutdown()
        server.server_close()
    assert len(received) == 33 and all(received)
    assert source_hashes == {str(p.relative_to(ROOT)): digest(p) for p in sources + [Path(__file__)]}
    report = json.loads((folder / 'fixture-metrics.json').read_text())
    save(folder / 'summary.json', {k: stats(v) for k, v in report['metrics_ms'].items()})
    save(folder / 'provenance.json', dict(captured_at=datetime.now(timezone.utc).isoformat(),
         head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
         source_sha256=source_hashes, fixture_sha256=digest(fixture), executable_sha256=digest(executable),
         swift=subprocess.check_output(['swift', '--version'], text=True).strip(),
         os=subprocess.check_output(['sw_vers'], text=True).strip(),
         hardware=subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip(),
         loopback_requests=len(received), no_real_audio_or_credentials=True))
    print((folder / 'summary.json').read_text())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--fixture', type=Path, required=True)
    args = parser.parse_args()
    run(args.directory.resolve(), args.fixture.resolve())
