#!/usr/bin/env python3
"""Run one command on a remote host over SSH, driving the password prompt.

The Mac this was written against uses password auth and no key, so the
password has to be fed through a pty.  It is read from MAC_SSH_PASS rather
than being baked into the script:

    export MAC_SSH_PASS='...'
    python3 tools/sshexec.py 'uptime'

If the variable is unset the password is prompted for interactively.
"""
import os, pty, sys, time, select, re

HOST = os.environ.get("MAC_SSH_HOST", "mac.lan")
USER = os.environ.get("MAC_SSH_USER", os.environ.get("USER", "yukari"))
PW = os.environ.get("MAC_SSH_PASS")

cmd = sys.argv[1]

pid, fd = pty.fork()
if pid == 0:
    os.execvp("ssh", ["ssh", "-o", "StrictHostKeyChecking=accept-new",
                      "-o", "PreferredAuthentications=password",
                      "-o", "PubkeyAuthentication=no",
                      "-o", "NumberOfPasswordPrompts=1",
                      f"{USER}@{HOST}", cmd])

buf = b""
sent_pw = False
start = time.time()
deadline = 120
while time.time() - start < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if fd in r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    if not sent_pw and re.search(rb"(password:|Password:)", buf):
        if PW is None:
            import getpass
            PW = getpass.getpass("SSH password: ")
        time.sleep(0.3)
        os.write(fd, PW.encode() + b"\n")
        sent_pw = True

_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else 0)
