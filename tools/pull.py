#!/usr/bin/env python3
"""Pull a file back from the remote host, base64-decoded.

    python3 tools/pull.py /Library/LaunchDaemons/foo.plist [localname]
"""
import subprocess, base64, sys, os

here = os.path.dirname(os.path.abspath(__file__))
remote = sys.argv[1]
local = sys.argv[2] if len(sys.argv) > 2 else remote.split("/")[-1]

r = subprocess.run(["python3", os.path.join(here, "sshexec.py"),
                    f"base64 -i {remote} 2>/dev/null"],
                   capture_output=True, text=True)

# sshexec echoes the remote command output verbatim; drop the password-prompt
# line and keep whatever base64 came back.
lines = [l for l in r.stdout.splitlines()
         if l.strip() and "password:" not in l.lower()]
blob = "".join(lines).strip()
try:
    data = base64.b64decode(blob + "=" * (-len(blob) % 4))
except Exception as e:
    print("DECODE FAIL", e)
    print(r.stdout[:400])
    sys.exit(1)

open(local, "wb").write(data)
print(f"{remote} -> {local} ({len(data)} bytes)")
