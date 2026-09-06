#!/usr/bin/env python3
"""Build original start/stop auditions; does not modify the app's selected sounds."""
import array
import json
import math
from pathlib import Path
import sys
import wave

RATE = 44100
OUT = Path(__file__).resolve().parents[2] / 'dist' / 'sound-options'


def smoothstep(value):
    x = max(0.0, min(1.0, value))
    return x * x * (3.0 - 2.0 * x)


def tone(frequency, duration, decay, attack=0.006, partials=((1.0, 1.0),)):
    frames = round(duration * RATE)
    out = []
    for i in range(frames):
        t = i / RATE
        envelope = smoothstep(t / attack) * math.exp(-t / decay)
        envelope *= smoothstep((duration - t) / 0.028)
        sample = sum(gain * math.sin(math.tau * frequency * ratio * t)
                     for ratio, gain in partials)
        out.append(sample * envelope)
    out[0] = out[-1] = 0.0
    return out


def layer(duration, notes):
    out = [0.0] * round(duration * RATE)
    for offset, signal, gain in notes:
        start = round(offset * RATE)
        for i, value in enumerate(signal):
            if start + i < len(out):
                out[start + i] += value * gain
    out[0] = out[-1] = 0.0
    return out


def soft_ping():
    # Fixed pitches, a round onset, very little harmonic brightness.
    return (
        tone(783.99, .19, .047, .006, ((1, 1), (2, .025))),
        tone(587.33, .175, .044, .006, ((1, 1), (2, .020))),
    )


def glass():
    # A tiny resonant glass bell, with rapidly fading upper partials.
    def bell(frequency):
        return layer(.26, [
            (0, tone(frequency, .26, .062, .004), 1),
            (0, tone(frequency * 2.76, .12, .021, .003), .11),
            (0, tone(frequency * 4.08, .08, .013, .003), .025),
        ])
    return bell(1046.50), bell(783.99)


def two_notes():
    # Two discrete overlapping notes instead of a sliding or bubbling pitch.
    def pair(first, second):
        return layer(.25, [
            (0, tone(first, .15, .037, .008, ((1, 1), (2, .018))), .88),
            (.08, tone(second, .17, .044, .008, ((1, 1), (2, .018))), 1),
        ])
    return pair(587.33, 783.99), pair(783.99, 587.33)


def normalize(signal, target_db=-27.0):
    # Compare active sound rather than silence; apply a peak ceiling afterwards.
    active = signal[:min(len(signal), round(.2 * RATE))]
    rms = math.sqrt(sum(x * x for x in active) / len(active))
    gain = (10 ** (target_db / 20)) / max(rms, 1e-12)
    gain = min(gain, .22 / max(abs(x) for x in signal))
    return [x * gain for x in signal]


def write_wave(path, samples):
    assert all(math.isfinite(x) and abs(x) <= .23 for x in samples)
    pcm = array.array('h', (round(max(-1, min(1, x)) * 32767) for x in samples))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(pcm.tobytes())
    with wave.open(str(path), 'rb') as f:
        assert f.getnframes() == len(samples)
        assert f.getframerate() == RATE


def main():
    from felt_sound import make_pair
    OUT.mkdir(parents=True, exist_ok=True)
    variants = [
        ('01-soft-ping', 'Soft ping', soft_ping()),
        ('02-felt-tap', 'Felt tap', make_pair(RATE)),
        ('03-glass', 'Glass', glass()),
        ('04-two-notes', 'Two notes', two_notes()),
    ]
    report = []
    for slug, title, signals in variants:
        start, stop = map(normalize, signals)
        for kind, signal in [('start', start), ('stop', stop)]:
            assert abs(signal[0]) < .0001 and abs(signal[-1]) < .0001
            peak = max(abs(x) for x in signal)
            step = max(abs(a - b) for a, b in zip(signal, signal[1:]))
            assert step < .07, (slug, kind, step)
            write_wave(OUT / f'{slug}-{kind}.wav', signal)
            report.append({'option': title, 'cue': kind, 'seconds': round(len(signal)/RATE, 3),
                           'peak': round(peak, 4), 'max_sample_step': round(step, 4)})
        # All clips share the same timing: start at .2 s and stop at 1.3 s.
        audition = layer(2.2, [(.2, start, 1), (1.3, stop, 1)])
        write_wave(OUT / f'{slug}.wav', audition)
    (OUT / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    print(f'Wrote previews to {OUT}')


if __name__ == '__main__':
    main()
