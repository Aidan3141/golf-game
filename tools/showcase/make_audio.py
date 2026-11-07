# soundtrack for the showcase: soft ambient pad + plucks (made here, no samples) under the
# games own sounds (ambience, impact, land) at the cue times from the renderer
# usage: python3 -I make_audio.py cues.json total_secs offset_secs sounds_dir out.wav
import json
import sys
import wave

import numpy as np

cues = json.load(open(sys.argv[1]))
total = float(sys.argv[2])
offset = float(sys.argv[3])  # title card length, cues are relative to the main clip
sounds = sys.argv[4]
out = sys.argv[5]
SR = 48000
N = int(total * SR)
rng = np.random.default_rng(7)


def load(name):
    w = wave.open(f"{sounds}/{name}.wav")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    return x


def midi(n):
    return 440 * 2 ** ((n - 69) / 12)


def fft_lowpass(x, hz):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / np.sqrt(1 + (f / hz) ** 4)  # gentle 2nd order-ish rolloff
    return np.fft.irfft(X, len(x))


# --- music ---------------------------------------------------------------
# D major, soft + open. each chord ~3.9s (62 bpm-ish feel)
chords = [
    [50, 57, 61, 64, 69],  # Dmaj9-ish (D A C# E A)
    [47, 54, 57, 61, 66],  # Bm9 (B F# A C# F#)
    [43, 50, 54, 57, 62],  # Gmaj7 (G D F# A D)
    [45, 52, 57, 59, 64],  # Asus (A E A B E)
]
chord_len = 3.9
t = np.arange(N) / SR
pad = np.zeros((N, 2), np.float32)
for ci in range(int(total / chord_len) + 2):
    notes = chords[ci % 4]
    start = ci * chord_len - 0.6
    seg = (t >= start) & (t < start + chord_len + 2.2)
    tt = t[seg] - start
    env = np.minimum(tt / 1.3, 1) * np.clip((chord_len + 2.2 - tt) / 2.0, 0, 1)
    for k, n in enumerate(notes):
        for ch, det in enumerate([-0.07, 0.07]):
            f = midi(n + 12) * 2 ** (det / 12)
            ph = rng.uniform(0, 2 * np.pi)
            # warm: sine + a bit of 2nd/3rd harmonic
            v = np.sin(2 * np.pi * f * tt + ph) + 0.25 * np.sin(4 * np.pi * f * tt + ph) + 0.08 * np.sin(6 * np.pi * f * tt)
            pad[seg, ch] += (0.05 / (1 + 0.3 * k)) * env * v
    # sub
    pad[seg, :] += (0.06 * env * np.sin(2 * np.pi * midi(notes[0] - 12) * tt))[:, None]

# plucks, 8ths, chord tones up high, start after the title
plucks = np.zeros((N, 2), np.float32)
step = chord_len / 8
k = 0
pt = 2.6
while pt < total - 2:
    ci = int((pt + 0.6) / chord_len) % 4
    tones = chords[ci][1:] + [chords[ci][2] + 12]
    n = tones[[0, 2, 1, 3, 2, 4, 3, 1][k % 8]] + 12
    L = int(1.6 * SR)
    i0 = int(pt * SR)
    i1 = min(i0 + L, N)
    tt = np.arange(i1 - i0) / SR
    f = midi(n)
    v = (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(4 * np.pi * f * tt) * np.exp(-tt * 8)) * np.exp(-tt * 3.2)
    v *= np.minimum(tt / 0.004, 1)
    pan = 0.5 + 0.3 * np.sin(k * 1.7)
    g = 0.045 * (0.8 + 0.2 * rng.random())
    plucks[i0:i1, 0] += g * (1 - pan) * v
    plucks[i0:i1, 1] += g * pan * v
    k += 1
    pt += step

music = pad + plucks
for ch in range(2):
    music[:, ch] = fft_lowpass(music[:, ch], 3500)


# reverb: convolve w/ decaying noise
def reverb(x, secs=2.8, wet=0.35):
    L = int(secs * SR)
    out = np.empty_like(x)
    for ch in range(x.shape[1]):
        ir = rng.standard_normal(L) * np.exp(-np.arange(L) / SR * 6.9 / secs)
        ir = fft_lowpass(ir, 5000)
        ir /= np.sqrt(np.sum(ir ** 2))
        n = len(x) + L
        y = np.fft.irfft(np.fft.rfft(x[:, ch], n) * np.fft.rfft(ir, n), n)[: len(x)]
        out[:, ch] = (1 - wet) * x[:, ch] + wet * y
    return out


music = reverb(music)

# fades
fade_in = np.minimum(t / 1.5, 1)
fade_out = np.clip((total - t) / 2.5, 0, 1)
music *= (fade_in * fade_out)[:, None]

# duck the music a bit under each impact
duck = np.ones(N)
for c in cues:
    if "impact" in c:
        c0 = c["t"] + offset
        d = np.exp(-np.maximum(t - c0, 0) / 0.5) * (t >= c0 - 0.05)
        duck *= 1 - 0.45 * d
music *= duck[:, None]

# --- game sounds ---------------------------------------------------------
fx = np.zeros((N, 2), np.float32)
amb = load("ambience")
reps = int(np.ceil(N / len(amb))) + 1
amb_long = np.tile(amb, reps)[:N]
fx += (0.22 * amb_long * fade_in * fade_out)[:, None]

impact = load("impact")
land = load("land")


def place(x, at, gain, rate=1.0):
    if rate != 1.0:
        # slow mo: pitch it down (resample), cap at half speed so it still reads as a hit
        r = max(rate, 0.5)
        idx = np.arange(0, len(x) - 1, r)
        x = np.interp(idx, np.arange(len(x)), x)
    i0 = int(at * SR)
    i1 = min(i0 + len(x), N)
    if i0 >= N or i1 <= 0:
        return
    fx[i0:i1, :] += gain * x[: i1 - i0, None]


for c in cues:
    at = c["t"] + offset
    if "impact" in c:
        place(impact, at, 0.9, c.get("rate", 1.0))
    if "land" in c:
        place(land, at, 0.5)

fx = reverb(fx, secs=1.2, wet=0.15)
mix = 0.9 * music + fx
mix /= max(1e-6, np.max(np.abs(mix))) / 0.85
pcm = (np.clip(mix, -1, 1) * 32767).astype(np.int16)
w = wave.open(out, "wb")
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(SR)
w.writeframes(pcm.tobytes())
w.close()
print("wrote", out, round(total, 2), "s")
