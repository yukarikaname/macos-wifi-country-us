#!/usr/bin/env python3
"""Push a local file to the remote host, base64-chunked.

The remote's `base64 -d` wants the payload on stdin, so the file is shipped as
a series of appended chunks and decoded there.  Chunking keeps each SSH
command short enough to survive shell quoting.

    python3 tools/push.py local.sh remote.sh
"""
import subprocess, base64, sys, os

here = os.path.dirname(os.path.abspath(__file__))
local = sys.argv[1]
remote = sys.argv[2] if len(sys.argv) > 2 else os.path.basename(local)

data = open(local, "rb").read()
b64 = base64.b64encode(data).decode()
chunks = [b64[i:i+1500] for i in range(0, len(b64), 1500)]

cmd = f"rm -f /tmp/opencode/{remote}.b64 /tmp/opencode/{remote}; "
cmd += "; ".join(f"printf '%s' '{c}' >> /tmp/opencode/{remote}.b64" for c in chunks)
cmd += f"; base64 -d < /tmp/opencode/{remote}.b64 > /tmp/opencode/{remote}"
cmd += f"; chmod +x /tmp/opencode/{remote}; wc -c /tmp/opencode/{remote}"

r = subprocess.run(["python3", os.path.join(here, "sshexec.py"), cmd],
                   capture_output=True, text=True)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
