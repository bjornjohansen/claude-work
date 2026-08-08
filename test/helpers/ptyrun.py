#!/usr/bin/env python3
"""Run a command under a pty and answer its prompts.

claude-work deliberately refuses to act on its destructive prompts unless stdin
is a terminal, so those paths cannot be tested by piping input. This runs the
command on a real pty and writes the Nth answer after seeing the Nth prompt.

Usage:
    ptyrun.py <answer> [<answer>...] -- <command> [args...]

Exits with the command's exit status; the command's output goes to stdout.
"""

import os
import pty
import select
import sys
import time

PROMPT = b"[y/N]"
TIMEOUT_SECONDS = 60


def main() -> int:
    try:
        sep = sys.argv.index("--")
    except ValueError:
        print("pty.py: missing -- separator", file=sys.stderr)
        return 2

    answers = [a.encode() + b"\n" for a in sys.argv[1:sep]]
    command = sys.argv[sep + 1 :]
    if not command:
        print("pty.py: no command given", file=sys.stderr)
        return 2

    # CI and containers hand us TERM=dumb (or nothing), and tmux refuses to
    # attach to a terminal that cannot clear. We are supplying a real pty, so
    # advertise a terminal type that tmux will accept.
    if os.environ.get("TERM", "dumb") in ("", "dumb", "unknown"):
        os.environ["TERM"] = "xterm"

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)
        os._exit(127)

    output = bytearray()
    sent = 0
    deadline = time.time() + TIMEOUT_SECONDS

    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.5)
        if readable:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk

        # Answer the Nth prompt only once it has actually appeared, so a slow
        # step earlier in the run cannot consume an answer meant for later.
        if sent < len(answers) and output.count(PROMPT) > sent:
            os.write(fd, answers[sent])
            sent += 1

    os.close(fd)
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(output.decode("utf-8", errors="replace"))
    sys.stdout.flush()

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 1


if __name__ == "__main__":
    sys.exit(main())
