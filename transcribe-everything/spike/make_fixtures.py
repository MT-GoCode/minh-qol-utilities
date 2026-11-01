# /// script
# dependencies = ["soundfile", "numpy"]
# ///
"""Build spike fixtures from LibriSpeech test-clean.

conversation.wav: utterances from 3 speakers interleaved round-robin with 0.8 s gaps.
conversation.json: ground truth [{speaker, start, end, text}] for each utterance.
embed/<speaker>/<utt>.wav: single-utterance clips for embedding separation tests.
"""
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

root, out = Path(sys.argv[1]), Path(sys.argv[2])
SR, GAP = 16000, 0.8
speakers = sorted(p for p in root.iterdir() if p.is_dir())
out.mkdir(parents=True, exist_ok=True)

def utterances(spk):
    for chap in sorted(spk.iterdir()):
        trans = dict(l.split(" ", 1) for l in (chap / f"{spk.name}-{chap.name}.trans.txt").read_text().splitlines())
        for flac in sorted(chap.glob("*.flac")):
            yield flac, trans[flac.stem].strip()

# Embedding set: 20 speakers x 8 utterances.
for spk in speakers[:20]:
    d = out / "embed" / spk.name
    d.mkdir(parents=True, exist_ok=True)
    for i, (flac, _) in enumerate(utterances(spk)):
        if i == 8:
            break
        audio, sr = sf.read(flac, dtype="float32")
        assert sr == SR
        sf.write(d / f"{flac.stem}.wav", audio, SR, subtype="FLOAT")

# Held-out embedding set (speakers never used to pick thresholds): speakers 23-39.
for spk in speakers[23:]:
    d = out / "embed-heldout" / spk.name
    d.mkdir(parents=True, exist_ok=True)
    for i, (flac, _) in enumerate(utterances(spk)):
        if i == 8:
            break
        audio, sr = sf.read(flac, dtype="float32")
        sf.write(d / f"{flac.stem}.wav", audio, SR, subtype="FLOAT")

# Long-session embedding set: held-out speakers, every utterance (full length only).
for spk in speakers[23:]:
    d = out / "embed-long" / spk.name
    d.mkdir(parents=True, exist_ok=True)
    for flac, _ in utterances(spk):
        audio, sr = sf.read(flac, dtype="float32")
        sf.write(d / f"{flac.stem}.wav", audio, SR, subtype="FLOAT")

# Continuous: one speaker's utterances, edge silence trimmed (20 ms frames, RMS < 0.01 = -40 dBFS),
# joined with 0.15 s gaps (< minSilence 0.5 s) until > 40 s.
def trim(a, frame=320, thr=0.01):
    rms = np.sqrt(np.convolve(a * a, np.ones(frame) / frame, mode="same"))
    idx = np.nonzero(rms >= thr)[0]
    return a[idx[0]:idx[-1] + 1]
cont, ctext = [], []
for flac, text in list(utterances(speakers[20]))[4:]:
    a, _ = sf.read(flac, dtype="float32")
    cont += [trim(a), np.zeros(int(0.15 * SR), dtype=np.float32)]
    ctext.append(text)
    if sum(len(x) for x in cont) / SR > 40:
        break
sf.write(out / "continuous.wav", np.concatenate(cont), SR, subtype="FLOAT")
(out / "continuous.json").write_text(json.dumps({"text": " ".join(ctext)}))

# Conversation: 3 speakers, 4 turns each, round-robin.
convo = [list(utterances(s))[:4] for s in speakers[20:23]]
pieces, truth, t = [], [], 0.0
for turn in range(4):
    for spk, utts in zip(speakers[20:23], convo):
        flac, text = utts[turn]
        audio, _ = sf.read(flac, dtype="float32")
        pieces += [audio, np.zeros(int(GAP * SR), dtype=np.float32)]
        truth.append({"speaker": spk.name, "start": round(t, 3), "end": round(t + len(audio) / SR, 3), "text": text})
        t += len(audio) / SR + GAP
sf.write(out / "conversation.wav", np.concatenate(pieces), SR, subtype="FLOAT")
(out / "conversation.json").write_text(json.dumps(truth, indent=1))
print(f"conversation {t:.1f}s, {len(truth)} turns; embed set {len(list((out / 'embed').glob('*/*.wav')))} clips")
