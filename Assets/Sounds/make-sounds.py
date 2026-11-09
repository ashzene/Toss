"""Toss upload cues: harmonic synth plucks (no bells), 44.1 kHz 24-bit stereo AIFF, loudness-normalized.
Regenerate: python3 Assets/Sounds/make-sounds.py Assets/Sounds [E|F]   (E = shipped success variant)"""
import math, struct, sys
RATE = 44100

def pluck(freq, start, length, d0, dk, tilt=1.0, glide=0.0, pan=0.5, detune=0.003, level=1.0, cutoff=9000, attack_s=0.002):
    """Harmonics k*f with amplitude 1/k^tilt, each decaying at d0 + dk*k per second (a soft lowpass pluck).
    glide > 0 sags the pitch over 120 ms, glide < 0 lifts it."""
    n = int(length * RATE); L = [0.0] * n; R = [0.0] * n
    ks = [k for k in range(1, 40) if k * freq < cutoff]
    for ch, (buf, det, gain) in enumerate(((L, 1 - detune / 2, math.cos(pan * math.pi / 2)), (R, 1 + detune / 2, math.sin(pan * math.pi / 2)))):
        for k in ks:
            amp, decay, phase = level * gain / k ** tilt, d0 + dk * k, 0.0
            for i in range(n):
                t = i / RATE
                f = freq * det * k * (1 - glide * min(t / 0.12, 1))
                phase += 2 * math.pi * f / RATE
                attack = 0.5 - 0.5 * math.cos(math.pi * min(t / attack_s, 1))
                buf[i] += amp * attack * math.exp(-decay * t) * math.sin(phase)
    return start, L, R

def mix(parts, total):
    n = int(total * RATE); L = [0.0] * n; R = [0.0] * n
    for start, pl, pr in parts:
        o = int(start * RATE)
        for i in range(min(len(pl), n - o)):
            L[o + i] += pl[i]; R[o + i] += pr[i]
    fade = int(0.04 * RATE)
    for i in range(fade):
        g = 0.5 + 0.5 * math.cos(math.pi * i / fade); L[n - fade + i] *= g; R[n - fade + i] *= g
    return L, R

def lufs(L, R):
    # Measured on a copy padded with 1 s of silence (as ffmpeg ebur128 checks were), so clips under 400 ms still gate.
    pad = [0.0] * RATE; L = list(L) + pad; R = list(R) + pad
    def biquad(x, b, a):
        y, x1, x2, y1, y2 = [], 0, 0, 0, 0
        for v in x:
            o = b[0]*v + b[1]*x1 + b[2]*x2 - a[1]*y1 - a[2]*y2; x2, x1, y2, y1 = x1, v, y1, o; y.append(o)
        return y
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    K = math.tan(math.pi * f0 / RATE); Vh = 10 ** (G / 20); Vb = Vh ** 0.4996667741545416; a0 = 1 + K/Q + K*K
    sb = [(Vh + Vb*K/Q + K*K)/a0, 2*(K*K - Vh)/a0, (Vh - Vb*K/Q + K*K)/a0]; sa = [1, 2*(K*K-1)/a0, (1 - K/Q + K*K)/a0]
    f0, Q = 38.13547087602444, 0.5003270373238773; K = math.tan(math.pi * f0 / RATE); a0 = 1 + K/Q + K*K
    hb, ha = [1, -2, 1], [1, 2*(K*K-1)/a0, (1-K/Q+K*K)/a0]
    kw = [biquad(biquad(c, sb, sa), hb, ha) for c in (L, R)]
    blk, hop = int(0.4 * RATE), int(0.1 * RATE)
    z = [sum(sum(v*v for v in c[s:s+blk]) / blk for c in kw) for s in range(0, len(L) - blk + 1, hop)]
    Lf = lambda p: -0.691 + 10 * math.log10(p)
    g = [p for p in z if Lf(p) > -70]; rel = Lf(sum(g)/len(g)) - 10; g = [p for p in g if Lf(p) > rel]
    return Lf(sum(g) / len(g))

def write_aiff(path, L, R, target_lufs, peak_ceiling_db=-6.0):
    now = lufs(L, R); gain = 10 ** ((target_lufs - now) / 20)
    peak = max(max(abs(v) for v in L), max(abs(v) for v in R)) * gain
    if 20 * math.log10(peak) > peak_ceiling_db:
        gain *= 10 ** (peak_ceiling_db / 20) / peak
    full = 2 ** 23 - 1
    pcm = bytearray()
    for a, b in zip(L, R):
        for v in (a, b): pcm += int(round(max(-1, min(1, v * gain)) * full)).to_bytes(3, 'big', signed=True)
    e = int(math.floor(math.log2(RATE))); m = int(RATE / 2 ** (e - 63))
    comm = struct.pack('>hIh', 2, len(L), 24) + struct.pack('>HQ', e + 16383, m)
    ssnd = struct.pack('>II', 0, 0) + bytes(pcm)
    body = b'AIFF' + b'COMM' + struct.pack('>I', len(comm)) + comm + b'SSND' + struct.pack('>I', len(ssnd)) + ssnd
    open(path, 'wb').write(b'FORM' + struct.pack('>I', len(body)) + body)
    Lg = [v * gain for v in L]; Rg = [v * gain for v in R]
    pk = max(max(abs(v) for v in Lg), max(abs(v) for v in Rg))
    print(f"{path.split('/')[-1]}: {len(L)/RATE:.3f} s, {lufs(Lg, Rg):.2f} LUFS, peak {20*math.log10(pk):.2f} dBFS")

out = sys.argv[1]
# Success (v2, 2026-10-24: v1 at A5->E6 was too sharp and too close to Codex's tick + thump).
# Round mid-register tones, 9 ms attack (no click), almost no upper harmonics.
variant = sys.argv[2] if len(sys.argv) > 2 else "E"
if variant == "E":   # two round notes up a fourth, G4 -> C5: "放好了"
    L, R = mix([pluck(392.0, 0.000, 0.42, 7, 14, tilt=2.4, pan=0.45, cutoff=2400, attack_s=0.009),
                pluck(523.25, 0.085, 0.50, 5, 12, tilt=2.4, pan=0.55, cutoff=2400, attack_s=0.009)], 0.62)
else:                # "F": one soft tone lifting from A4 towards D5: a single "whoop" up
    L, R = mix([pluck(440.0, 0.000, 0.50, 5, 13, tilt=2.6, glide=-0.33, pan=0.5, cutoff=2200, attack_s=0.010),
                pluck(220.0, 0.000, 0.22, 16, 30, tilt=3.0, level=0.25, pan=0.5, cutoff=1200, attack_s=0.010)], 0.55)
write_aiff(f"{out}/Toss-Success.aiff", L, R, target_lufs=-27.0)
# Failure: soft downward minor third, E4 -> C#4, darker and duller, slight pitch sag. "Didn't land."
L, R = mix([pluck(329.63, 0.000, 0.30, 12, 22, tilt=1.6, pan=0.46, cutoff=3500),
            pluck(277.18, 0.095, 0.45, 9, 18, tilt=1.6, glide=0.03, pan=0.54, cutoff=3000)], 0.55)
write_aiff(f"{out}/Toss-Failure.aiff", L, R, target_lufs=-29.0)
