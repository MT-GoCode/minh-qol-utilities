# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""Speaker accuracy at 0.1 s resolution over reference single-speaker speech (many-to-one mapping per cluster).

analyze_frames.py <rttm> <seconds> windows <windows.json> | lseend <lseend.json>
"""
import json, sys
from collections import Counter, defaultdict
import numpy as np

rttm, horizon, mode, path = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
shift = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0  # score a later repeat of the same audio
N = int(horizon * 10)
refs = defaultdict(list)
for row in open(rttm):
    f = row.split(); s, d = float(f[3]), float(f[4])
    if s < horizon:
        refs[f[7]].append((s, s + d))
ref = [set() for _ in range(N)]
for spk, iv in refs.items():
    for s, e in iv:
        for i in range(int(s * 10), min(N, int(e * 10))):
            ref[i].add(spk)
single = [i for i in range(N) if len(ref[i]) == 1]
def score(hyp, tag, n):
    by = defaultdict(Counter); unl = 0
    for i in single:
        if hyp[i] is None:
            unl += 1
        else:
            by[hyp[i]][next(iter(ref[i]))] += 1
    ok = sum(max(c.values()) for c in by.values())
    print(f"  {tag}: clusters {n:3d} accuracy {ok / len(single):.1%}  unlabelled {unl / len(single):.1%}")
print(f"{len(single) / 10:.0f} s single-speaker reference speech, {len(refs)} speakers")
data = json.load(open(path))
if mode == "windows":
    rows = data["rows"]
    for thr in [0.25, 0.30, 0.35, 0.40, 0.45, 0.50]:
        sums, hyp = [], [None] * N
        for r in rows:
            e = np.asarray(r["emb"], dtype=float); e /= np.linalg.norm(e)
            sims = [float(e @ (c / np.linalg.norm(c))) for c in sums]
            if sims and max(sims) >= thr:
                k = int(np.argmax(sims)); sums[k] = sums[k] + e
            else:
                k = len(sums); sums.append(e.copy())
            mid = (r["start"] + r["end"]) / 2
            hop = rows[1]["start"] - rows[0]["start"]
            for i in range(int((mid - hop / 2) * 10), min(N, int((mid + hop / 2) * 10))):
                hyp[i] = k
        # frames in the window edges inside speech take the nearest label
        last = None
        for i in range(N):
            last = hyp[i] if hyp[i] is not None else last
            if hyp[i] is None and ref[i] and last is not None:
                hyp[i] = last
        score(hyp, f"thr {thr:.2f}", len(sums))
else:
    hyp = [None] * N
    segs = [g for g in data["segments"] if g["end"] - shift > 0 and g["start"] - shift < horizon]
    for g in segs:
        for i in range(max(0, int((g["start"] - shift) * 10)), min(N, int((g["end"] - shift) * 10))):
            hyp[i] = g["spk"]
    score(hyp, "lseend", len({g["spk"] for g in segs}))
