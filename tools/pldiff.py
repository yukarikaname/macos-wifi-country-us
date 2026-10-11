#!/usr/bin/env python3
"""Diff each override plist against the /System original it was cloned from.

Confirms the only difference is the added DYLD_INSERT_LIBRARIES key -- anything
else means the override has drifted and should be regenerated with
tools/mkoverride.py.

    python3 tools/pldiff.py [job ...]     (defaults to airportd, countryd)
"""
import plistlib, os, sys

def load(p):
    with open(p, "rb") as f:
        return plistlib.load(f)

def flat(d, pre=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flat(v, pre + "/" + str(k)))
    else:
        out[pre] = repr(d)
    return out

jobs = sys.argv[1:] or ["com.apple.airportd", "com.apple.countryd"]

for job in jobs:
    print("---", job)
    a = load("/System/Library/LaunchDaemons/%s.plist" % job)
    cp = "/Library/LaunchDaemons/%s.plist" % job
    if not os.path.exists(cp):
        print("  CLONE MISSING")
        continue
    b = load(cp)
    fa, fb = flat(a), flat(b)
    print("  MISSING in clone:", [k for k in fa if k not in fb] or "none")
    print("  EXTRA   in clone:", [k for k in fb if k not in fa] or "none")
    print("  DIFFERING      :", {k: (fa[k], fb[k])
                                 for k in fa if k in fb and fa[k] != fb[k]} or "none")
