"""Original Felt audition: a cushioned wooden tap, followed by a lower closing tap.

The brief, noise-excited body resonances stay fixed in pitch. A soft contact
transient supplies texture without a sharp click or a sustained electronic tone.
This module only returns samples; it does not play audio or modify app settings.
"""

import math
import random


def make_pair(sample_rate):
    """Return (start, stop) mono float samples at the requested sample rate."""
    if not isinstance(sample_rate, (int, float)) or not math.isfinite(sample_rate):
        raise ValueError("sample_rate must be a finite positive number")
    if sample_rate < 8000:
        raise ValueError("sample_rate must be at least 8000 Hz")

    start = _tap(
        sample_rate, duration=0.155, frequency=330.0,
        decay=0.025, contact=0.010, seed=1729, peak=0.29,
    )
    stop = _tap(
        sample_rate, duration=0.140, frequency=260.0,
        decay=0.022, contact=0.012, seed=2718, peak=0.27,
    )
    return start, stop


def _tap(sample_rate, *, duration, frequency, decay, contact, seed, peak):
    rng = random.Random(seed)
    count = round(duration * sample_rate)

    # Inharmonic wooden-body modes, increasingly damped toward the upper end.
    modes = []
    for ratio, weight, damping in (
        (1.00, 0.54, 1.00),
        (1.61, 0.31, 0.67),
        (2.43, 0.12, 0.45),
        (3.36, 0.03, 0.32),
    ):
        angle = 2.0 * math.pi * frequency * ratio / sample_rate
        radius = math.exp(-1.0 / (sample_rate * decay * damping))
        modes.append([radius * math.cos(angle), radius * math.sin(angle),
                      weight, 0.0, 0.0])

    contact_lowpass = 0.0
    lowpass_amount = 1.0 - math.exp(-2.0 * math.pi * 1250.0 / sample_rate)
    samples = []
    for frame in range(count):
        time = frame / sample_rate
        noise = rng.uniform(-1.0, 1.0)
        # A cushioned strike spreads the excitation over several milliseconds.
        contact_envelope = math.sin(math.pi * time / contact) ** 2 if time < contact else 0.0
        excitation = noise * contact_envelope
        contact_lowpass += lowpass_amount * (excitation - contact_lowpass)

        body = 0.0
        for mode in modes:
            cosine, sine, weight, real, imaginary = mode
            next_real = cosine * real - sine * imaginary + excitation
            next_imaginary = sine * real + cosine * imaginary
            mode[3], mode[4] = next_real, next_imaginary
            body += weight * next_imaginary

        envelope = _smoothstep(time / 0.003) * _smoothstep((duration - time) / 0.030)
        samples.append((body + 0.45 * contact_lowpass) * envelope)

    # Remove residual DC without adding a discontinuity at either boundary.
    correction_window = [math.sin(math.pi * i / (count - 1)) ** 2 for i in range(count)]
    correction = sum(samples) / sum(correction_window)
    samples = [sample - correction * window
               for sample, window in zip(samples, correction_window)]
    maximum = max(abs(sample) for sample in samples)
    samples = [sample * peak / maximum for sample in samples]
    samples[0] = samples[-1] = 0.0
    return samples


def _smoothstep(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)
