# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""What the user sees: each Ultra word gets the online tracker's label from the nearest 2 s window (threshold 0.30).
Scored per word whose midpoint is in single-speaker reference speech, many-to-one per cluster.
analyze_words.py <rttm> <words.json> <windows.json>"""
import json, sys
from collections import Counter, defaultdict
import numpy as np
ref = [(float(f[3]), float(f[3]) + float(f[4]), f[7]) for f in (l.split() for l in open(sys.argv[1]))]
words = json.load(open(sys.argv[2]))["words"]; rows = json.load(open(sys.argv[3]))["rows"]
sums, mids, labs = [], [], []
for r in rows:
    e = np.asarray(r["emb"], dtype=float); e /= np.linalg.norm(e)
    sims = [float(e @ (c / np.linalg.norm(c))) for c in sums]
    if sims and max(sims) >= 0.30:
        k = int(np.argmax(sims)); sums[k] = sums[k] + e
    else:
        k = len(sums); sums.append(e.copy())
    mids.append((r["start"] + r["end"]) / 2); labs.append(k)
mids = np.array(mids); by = defaultdict(Counter); n = 0
for w in words:
    m = (w["start"] + w["end"]) / 2
    who = {s for a, b, s in ref if a <= m < b}
    if len(who) != 1 or not len(mids):
        continue
    by[labs[int(np.argmin(abs(mids - m)))]][next(iter(who))] += 1; n += 1
ok = sum(max(c.values()) for c in by.values())
print(f"  {len(words)} words, {n} in single-speaker speech: word accuracy {ok / n:.1%}, clusters {len(sums)}, reference speakers {len({s for _, _, s in ref})}")
