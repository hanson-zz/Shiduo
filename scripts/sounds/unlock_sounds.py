#!/usr/bin/env python3
"""拾掇 Pro 解锁庆祝动画的音效（全部用代码合成的原创声音，MIT）。

用法：python3 scripts/sounds/unlock_sounds.py Resources/Sounds
需要 numpy。输出单声道 22.05 kHz 16-bit WAV，每个都小于 60 KB，峰值约 -6 dBFS（提示音更轻）。
左右声道的位置由 App 播放时用 AVAudioPlayer.pan 控制。
"""
import os
import sys
import wave

import numpy as np

SR = 22050
OUT = sys.argv[1] if len(sys.argv) > 1 else "Resources/Sounds"
RNG = np.random.default_rng(2026)


def t(d):
    return np.arange(int(SR * d)) / SR


def note(m):
    return 440 * 2 ** ((m - 69) / 12)


def attack(x, a=0.004):
    n = max(1, int(a * SR))
    x[:n] *= np.linspace(0, 1, n)
    return x


def lowpass(x, k):
    return np.convolve(x, np.ones(k) / k, "same")


def mix(parts, dur):
    out = np.zeros(int(SR * dur))
    for start, sig in parts:
        i = int(start * SR)
        n = min(len(sig), len(out) - i)
        out[i:i + n] += sig[:n]
    return out


def save(name, x, peak_db=-6.0):
    x = x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20)
    fade = int(0.02 * SR)
    x[-fade:] *= np.linspace(1, 0, fade)
    path = os.path.join(OUT, name)
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((x * 32767).astype("<i2").tobytes())
    w.close()
    size = os.path.getsize(path)
    assert size < 60_000, (name, size)
    print(f"{name}: {size} bytes")


def bell(m, d, decay=3.0):
    f = note(m)
    x = t(d)
    s = (np.sin(2 * np.pi * f * x) * np.exp(-x * decay)
         + 0.35 * np.sin(2 * np.pi * f * 2.0 * x) * np.exp(-x * decay * 1.6)
         + 0.15 * np.sin(2 * np.pi * f * 3.01 * x) * np.exp(-x * decay * 2.6)
         + 0.06 * np.sin(2 * np.pi * f * 4.2 * x) * np.exp(-x * decay * 4))
    return attack(s, 0.003)


# 1 弹窗登场：轻柔的「呼——嘣」（滤过的噪声扫上去 + 一个向上弹的音）
def whoosh():
    d = 0.6
    x = t(d)
    noise = RNG.standard_normal(len(x))
    env = np.sin(np.pi * np.clip(x / 0.45, 0, 1)) ** 2
    air = lowpass(noise, 9) * env * 0.35
    f = 220 * (1 + 1.4 * np.clip(x / 0.25, 0, 1)) * (1 + 0.04 * np.sin(2 * np.pi * 11 * x) * np.exp(-x * 6))
    boing = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-np.clip(x - 0.05, 0, None) * 7)
    boing[: int(0.05 * SR)] *= np.linspace(0, 1, int(0.05 * SR))
    return air + boing * 0.8


# 2 王冠落下：轻「啵」
def pop():
    d = 0.16
    x = t(d)
    f = 170 + 600 * np.exp(-x * 60)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-x * 34)
    click = lowpass(RNG.standard_normal(len(x)), 6) * np.exp(-x * 170) * 0.3
    return attack(body + click, 0.002)


# 3a 烟花升空：上扬的口哨
def whistle():
    d = 0.32
    x = t(d)
    f = 900 + 1700 * (x / d) ** 1.4
    s = np.sin(2 * np.pi * np.cumsum(f) / SR)
    s += lowpass(RNG.standard_normal(len(x)), 4) * 0.15
    env = np.clip(x / 0.06, 0, 1) * (1 - 0.6 * (x / d))
    return s * env


# 3b 烟花绽放：柔和的噼啪声（低沉的一声 + 一串随机的小火花）
def crackle():
    d = 0.9
    x = t(d)
    thump = np.sin(2 * np.pi * np.cumsum(90 + 120 * np.exp(-x * 30)) / SR) * np.exp(-x * 14) * 0.7
    sparks = np.zeros(len(x))
    for _ in range(70):
        start = RNG.uniform(0.03, 0.75) ** 1.3
        i = int(start * SR)
        n = int(RNG.uniform(0.004, 0.012) * SR)
        if i + n >= len(x):
            continue
        burst = RNG.standard_normal(n) * np.exp(-np.arange(n) / (n / 4))
        sparks[i:i + n] += burst * RNG.uniform(0.2, 0.6) * (1 - start)
    sparks = sparks - lowpass(sparks, 5) * 0.6
    return thump + sparks * 0.9


# 4 功能标签：很轻的「叮」，一个比一个高
def ting(i):
    m = [88, 90, 92, 93, 95, 97][i]
    s = bell(m, 0.32, decay=11)
    return s


# 5 小熊猫挥手：温暖的成功和弦（大三和弦分解）
def chime():
    d = 1.2
    parts = [(0.0, bell(72, 1.15, 2.6) * 0.8), (0.07, bell(76, 1.1, 2.8) * 0.7),
             (0.14, bell(79, 1.05, 3.0) * 0.65), (0.24, bell(84, 0.95, 3.4) * 0.55)]
    return mix(parts, d)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    save("unlock-whoosh.wav", whoosh())
    save("unlock-pop.wav", pop())
    save("unlock-whistle.wav", whistle(), -9)
    save("unlock-crackle.wav", crackle())
    for i in range(6):
        save(f"unlock-ting-{i + 1}.wav", ting(i), -16)
    save("unlock-chime.wav", chime())
