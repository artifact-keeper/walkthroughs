#!/usr/bin/env python3
"""Record a command's terminal output as an asciicast v2 file (Python standard library only).

    rec.py OUT.cast [--title T] [--idle 1.5] [--cols 120] [--rows 34] -- command [args...]

The command runs in a pseudo-terminal; every chunk it writes becomes an "o" event. Pauses
longer than --idle seconds (a download, a model loading) are cut to --idle in the file, the
way `asciinema rec --idle-time-limit` does, so a ten-minute step plays back in about a minute.
The cast plays in asciinema-player or `asciinema play`. Used by demo/record.sh.
"""
import argparse, json, os, pty, select, signal, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--title", default="")
    ap.add_argument("--idle", type=float, default=1.5)
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--rows", type=int, default=34)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    header = {"version": 2, "width": a.cols, "height": a.rows, "timestamp": int(time.time()),
              "title": a.title, "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"}}
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", COLUMNS=str(a.cols), LINES=str(a.rows))
        os.execvp(cmd[0], cmd)
    try:  # tell the child its window size
        import fcntl, struct, termios
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))
    except OSError:
        pass
    t_play, last = 0.0, time.monotonic()
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(json.dumps(header) + "\n")
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 1.0)
            except InterruptedError:
                continue
            if not r:
                continue
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            now = time.monotonic()
            t_play += min(now - last, a.idle)
            last = now
            text = data.decode("utf-8", "replace")
            f.write(json.dumps([round(t_play, 3), "o", text]) + "\n")
            sys.stdout.write(text); sys.stdout.flush()
    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    main()
