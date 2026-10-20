import math, struct, sys, wave
SR = 44100
def note(midis, dur=1.6, vel=0.5):
    n = int(SR * dur); out = [0.0] * n
    for m in midis:
        f0 = 440.0 * 2 ** ((m - 69) / 12)
        for k in range(1, 9):
            f = f0 * k * math.sqrt(1 + 0.0004 * k * k)       # slight string inharmonicity
            if f > SR / 2: break
            amp = vel / k ** 1.2
            decay = 1.5 + 0.9 * k
            w = 2 * math.pi * f / SR
            for i in range(n):
                t = i / SR
                env = min(1.0, t / 0.004) * math.exp(-decay * t)
                out[i] += amp * env * math.sin(w * i)
    return out
def silence(d): return [0.0] * int(SR * d)
seq = silence(1.0)
for midis in ([69], [60], [64], [60, 64, 67], [57, 64, 72]):
    seq += note(midis) + silence(0.8)
peak = max(abs(x) for x in seq) or 1
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<h', int(32000 * 0.8 * x / peak)) for x in seq))
print('wrote', sys.argv[1], round(len(seq) / SR, 1), 's')
