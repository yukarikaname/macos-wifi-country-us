#!/usr/bin/env python3
"""Clone a system launchd plist into an override, adding the dylib env var.

The override has to be a byte-for-byte clone of the /System plist apart from
one added EnvironmentVariables key, or launchd may behave differently for the
overridden job in some subtle way.  Copying via plistlib rather than editing
text also keeps the file in the canonical format.

    python3 tools/mkoverride.py <src-plist> <dst-plist> <label> [dylib-path]
"""
import plistlib, sys

src, dst, label = sys.argv[1], sys.argv[2], sys.argv[3]
dylib = sys.argv[4] if len(sys.argv) > 4 else "/usr/local/lib/libcountryus.dylib"

with open(src, "rb") as f:
    d = plistlib.load(f)

d["Label"] = label
ev = d.setdefault("EnvironmentVariables", {})
ev["DYLD_INSERT_LIBRARIES"] = dylib

with open(dst, "wb") as f:
    plistlib.dump(d, f)
print("wrote", dst, "label=", label, "env=", ev)
