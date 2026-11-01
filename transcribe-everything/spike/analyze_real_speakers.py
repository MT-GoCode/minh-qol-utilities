# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""Planned segmenter + CentroidTracker on real meeting audio with reference labels (RTTM).

Reports the share of speech time in segments holding more than one speaker, cluster count and purity, per threshold.
"""
import json, sys
from collections import Counter, defaultdict
import numpy as np

lines = json.load(open(sys.argv[1]))["lines"]
horizon = max(l["end"] for l in lines)
ref = []
for row in open(sys.argv[2]):
    f = row.split()
    s, d, spk = float(f[3]), float(f[4]), f[7]
    if s < horizon:
        ref.append((s, s + d, spk))
speakers = {r[2] for r in ref}
def overlap(l):
    c = Counter()
    for s, e, spk in ref:
        o = min(e, l["end"]) - max(s, l["start"])
        if o > 0:
            c[spk] += o
    return c
ov = [overlap(l) for l in lines]
tot = sum(sum(c.values()) for c in ov)
mixed = sum(sum(c.values()) for c in ov if len([v for v in c.values() if v >= 0.3]) > 1)
pure = sum(max(c.values()) for c in ov if c)
print(f"{len(lines)} segments over {horizon:.0f} s, {len(speakers)} reference speakers")
print(f"speech time in segments with >1 speaker (>=0.3 s each): {mixed / tot:.1%}; best possible purity with one label per segment: {pure / tot:.1%}")
for thr in [0.25, 0.30, 0.35, 0.40, 0.45]:
    sums, label, prev = [], [], 0
    for l in lines:
        dur = l["end"] - l["start"]
        if dur < 2.0 or "emb" not in l:
            label.append(prev)
            continue
        e = np.asarray(l["emb"], dtype=float); e /= np.linalg.norm(e)
        sims = [float(e @ (c / np.linalg.norm(c))) for c in sums]
        if sims and max(sims) >= thr:
            i = int(np.argmax(sims)); sums[i] = sums[i] + e
        else:
            i = len(sums); sums.append(e.copy())
        label.append(i); prev = i
    by = defaultdict(Counter)
    for lb, c in zip(label, ov):
        by[lb].update(c)
    score = sum(max(c.values()) for c in by.values() if c)
    print(f"  thr {thr:.2f}: clusters {len(sums):3d}  purity {score / tot:.1%}")
