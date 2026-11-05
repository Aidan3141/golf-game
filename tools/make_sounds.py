# makes all the game sounds from scratch so theres no licensing stuff.
# run: python3 tools/make_sounds.py  -> Apps/VisionOS/Resources/Sounds/*.wav (48k mono 16 bit)
import os
import wave

import numpy as np

SR = 48_000
OUT = os.path.join(os.path.dirname(__file__), "..", "Apps", "VisionOS", "Resources", "Sounds")
rng = np.random.default_rng(7)  # fixed seed so reruns give the same files


def t(secs):
    return np.arange(int(SR * secs)) / SR


def env(x, attack, decay):
    # quick attack, exp decay
    a = np.clip(x / max(attack, 1e-6), 0, 1)
    return a * np.exp(-x / decay)


def lowpass(x, cutoff):
    # one pole, good enough
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def save(name, x, peak=0.9):
    x = x / (np.max(np.abs(x)) + 1e-9) * peak
    data = (x * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", name, f"{len(x) / SR:.2f}s")


def impact():
    # iron on ball: sharp click + short metal ring + low thump
    x = t(0.45)
    click = highpass(rng.standard_normal(len(x)), 2500) * env(x, 0.0005, 0.006)
    ring = sum(np.sin(2 * np.pi * f * x) * g for f, g in [(2150, 1.0), (3420, 0.6), (5230, 0.35), (7400, 0.2)])
    ring *= env(x, 0.0005, 0.05) * 0.35
    thump = np.sin(2 * np.pi * 110 * x) * env(x, 0.001, 0.035) * 0.8
    turf = lowpass(rng.standard_normal(len(x)), 1800) * env(x, 0.003, 0.06) * 0.5
    save("impact.wav", click + ring + thump + turf)


def land():
    # ball hitting grass: soft low thud
    x = t(0.35)
    thud = np.sin(2 * np.pi * 75 * x) * env(x, 0.002, 0.06)
    grass = lowpass(rng.standard_normal(len(x)), 900) * env(x, 0.004, 0.09) * 0.6
    save("land.wav", thud + grass, peak=0.8)


def chirp(secs, f0, f1):
    x = t(secs)
    f = np.linspace(f0, f1, len(x)) + 120 * np.sin(2 * np.pi * 28 * x)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.sin(np.pi * x / secs) ** 2


def ambience():
    # 16s seamless loop: brown-ish wind w/ slow gusts + a few birds
    secs = 16
    n = SR * secs
    x = np.arange(n) / SR
    white = rng.standard_normal(n)
    brown = np.cumsum(white)
    brown -= lowpass(brown, 0.5)  # kill drift
    wind = lowpass(brown, 500)
    wind /= np.max(np.abs(wind)) + 1e-9
    gust = 0.55 + 0.45 * np.sin(2 * np.pi * x / secs) * np.sin(2 * np.pi * 3 * x / secs + 1.3)
    out = wind * gust * 0.5
    for start in [1.7, 2.0, 6.4, 9.1, 9.35, 13.2]:
        c = chirp(rng.uniform(0.08, 0.16), rng.uniform(3200, 4200), rng.uniform(4400, 5600))
        i = int(start * SR)
        out[i:i + len(c)] += c * 0.08
    # crossfade the tail into the head so the loop has no click
    fade = SR // 2
    w = np.linspace(0, 1, fade)
    out[:fade] = out[:fade] * w + out[-fade:] * (1 - w)
    save("ambience.wav", out[:-fade], peak=0.5)


def ticks():
    # tempo trainer: 3 soft ticks back, 1 bright tock down
    x = t(0.08)
    tick = np.sin(2 * np.pi * 1000 * x) * env(x, 0.0005, 0.012)
    tock = (np.sin(2 * np.pi * 1600 * x) + 0.5 * np.sin(2 * np.pi * 2400 * x)) * env(x, 0.0005, 0.02)
    save("tick.wav", tick, peak=0.6)
    save("tock.wav", tock, peak=0.8)


if __name__ == "__main__":
    impact()
    land()
    ambience()
    ticks()
