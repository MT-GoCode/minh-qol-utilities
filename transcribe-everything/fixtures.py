# /// script
# requires-python = ">=3.12"
# dependencies = ["soundfile", "numpy", "pyarrow", "requests"]
# ///
"""Test fixtures and the FluidAudio CLI oracle. fixtures.py <cache> <fluidaudiocli>. Every stage skips if its output exists."""
import io
import json
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import requests
import soundfile as sf

cache, cli = Path(sys.argv[1]), sys.argv[2]
F, D = cache / "fixtures", cache / "downloads"
(F / "turns").mkdir(parents=True, exist_ok=True)
(F / "oracle").mkdir(exist_ok=True)
D.mkdir(exist_ok=True)
SR, GAP = 16000, 0.8
SPEAKERS = ["4970", "4992", "5105"]  # sorted indices 20-22 of LibriSpeech test-clean


def download(url, name):
    path = D / name
    if not path.exists():
        part = path.with_suffix(".part")
        with urllib.request.urlopen(url) as r, open(part, "wb") as o:
            shutil.copyfileobj(r, o)
        part.rename(path)
    return path


# LibriSpeech
libri = D / "librispeech"
if not libri.exists():
    tgz = download("https://www.openslr.org/resources/12/test-clean.tar.gz", "test-clean.tar.gz")
    part = libri.with_suffix(".part")
    with tarfile.open(tgz, "r|gz") as t:
        for m in t:
            if any(m.name.startswith(f"LibriSpeech/test-clean/{s}/") for s in SPEAKERS):
                t.extract(m, part, filter="data")
    part.rename(libri)
root = libri / "LibriSpeech/test-clean"


def utterances(spk):
    d = root / spk
    for chap in sorted(d.iterdir()):
        trans = dict(l.split(" ", 1) for l in (chap / f"{spk}-{chap.name}.trans.txt").read_text().splitlines())
        for flac in sorted(chap.glob("*.flac")):
            yield flac, trans[flac.stem].strip()


def trim(a, frame=320, thr=0.01):
    rms = np.sqrt(np.convolve(a * a, np.ones(frame) / frame, mode="same"))
    idx = np.nonzero(rms >= thr)[0]
    return a[idx[0]:idx[-1] + 1]


# continuous: one speaker's clips, edges trimmed at -40 dBFS, 0.15 s gaps (under minSilence), > 40 s
if not (F / "continuous.wav").exists():
    cont, ctext = [], []
    for flac, text in list(utterances(SPEAKERS[0]))[4:]:
        a, _ = sf.read(flac, dtype="float32")
        cont += [trim(a), np.zeros(int(0.15 * SR), dtype=np.float32)]
        ctext.append(text)
        if sum(len(x) for x in cont) / SR > 40:
            break
    sf.write(F / "continuous.wav", np.concatenate(cont), SR, subtype="FLOAT")
    (F / "continuous.json").write_text(json.dumps({"text": " ".join(ctext)}))

# conversation: 3 speakers x 4 turns, round-robin, plus per-turn clips
if not (F / "conversation.wav").exists():
    convo = [list(utterances(s))[:4] for s in SPEAKERS]
    pieces, truth, t = [], [], 0.0
    for turn in range(4):
        for spk, utts in zip(SPEAKERS, convo):
            flac, text = utts[turn]
            audio, _ = sf.read(flac, dtype="float32")
            pieces += [audio, np.zeros(int(GAP * SR), dtype=np.float32)]
            truth.append({"speaker": spk, "start": round(t, 3), "end": round(t + len(audio) / SR, 3), "text": text})
            t += len(audio) / SR + GAP
    sf.write(F / "conversation.wav", np.concatenate(pieces), SR, subtype="FLOAT")
    (F / "conversation.json").write_text(json.dumps(truth, indent=1))
audio, sr = sf.read(F / "conversation.wav", dtype="float32")
truth = json.loads((F / "conversation.json").read_text())
for i, t in enumerate(truth):
    clip = audio[int(t["start"] * sr):int(t["end"] * sr)]
    assert len(clip) < 480_000  # FluidAudio's disk-backed path starts above this; the oracle must be the samples path
    if not (F / f"turns/{i:02d}.wav").exists():
        sf.write(F / f"turns/{i:02d}.wav", clip, sr, subtype="FLOAT")

# AMI: first 900 s, the length the speaker numbers were measured on
if not (F / "ami.wav").exists():
    a, sr = sf.read(download("https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav", "ES2004a.wav"), frames=900 * SR, dtype="int16")
    assert sr == SR
    sf.write(F / "ami.wav", a, SR, subtype="PCM_16")
    rows = []
    for l in download("https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/ES2004a.rttm", "ES2004a.rttm").read_text().splitlines():
        f = l.split()
        s, d = float(f[3]), float(f[4])
        if s < 900:
            f[4] = f"{min(d, 900 - s):.3f}"
            rows.append(" ".join(f))
    (F / "ami.rttm").write_text("\n".join(rows) + "\n")

# VoxConverse: the clips the speaker bounds were measured on
WANT = {2: 572.2, 3: 430.7, 4: 513.4, 6: 172.3, 9: 225.0}
if not all((F / f"vox{n}.wav").exists() for n in WANT):
    base = "https://huggingface.co/datasets/diarizers-community/voxconverse/resolve/main"
    api = requests.get("https://huggingface.co/api/datasets/diarizers-community/voxconverse", timeout=60).json()
    got = set()
    for f in [s["rfilename"] for s in api["siblings"] if s["rfilename"].endswith(".parquet") and "test" in s["rfilename"]]:
        for r in pq.read_table(io.BytesIO(requests.get(f"{base}/{f}", timeout=600).content)).to_pylist():
            n, dur = len(set(r["speakers"])), max(r["timestamps_end"])
            if n in WANT and n not in got and 120 < dur < 900:
                a, sr = sf.read(io.BytesIO(r["audio"]["bytes"]))
                assert sr == SR
                sf.write(F / f"vox{n}.wav", a, sr)
                (F / f"vox{n}.rttm").write_text("".join(f"SPEAKER vox{n} 1 {s:.3f} {e - s:.3f} <NA> <NA> {x} <NA> <NA>\n" for s, e, x in zip(r["timestamps_start"], r["timestamps_end"], r["speakers"])))
                got.add(n)
        if len(got) == len(WANT):
            break
for n, secs in WANT.items():
    assert abs(sf.info(F / f"vox{n}.wav").duration - secs) < 1.0, n
    assert len({l.split()[7] for l in (F / f"vox{n}.rttm").read_text().splitlines()}) == n

# Oracle: FluidAudio's own path
for i in range(len(truth)):
    out = F / f"oracle/{i:02d}.json"
    if not out.exists():
        subprocess.run([cli, "transcribe", F / f"turns/{i:02d}.wav", "--model-version", "ultra", "--output-json", out], check=True)
print("fixtures ready")
