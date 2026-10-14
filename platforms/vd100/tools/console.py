#!/usr/bin/env python3
"""console.py - run a shell command on the VD100 Linux console (USB-UART) and print its output.

    console.py [--port /dev/ttyUSB0] [--timeout S] '<command>'

The command is followed by an echo of a unique tag with its exit status; the output up to the tag
is printed and the command's status becomes this script's (124 on timeout). The board must be at
a root shell prompt (the ALINX PetaLinux logs in automatically).
"""
import argparse, os, re, select, sys, termios, time


def open_port(port):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0; a[1] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[3] = 0
    a[4] = a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def read_for(fd, t):
    buf, end = b"", time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try: buf += os.read(fd, 65536)
            except BlockingIOError: pass
    return buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=os.environ.get("PORT", "/dev/ttyUSB0"))
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("command")
    a = ap.parse_args()
    fd = open_port(a.port)
    read_for(fd, 0.3)                                   # drop stale output
    tag = "__OCV_DONE_%d__" % (int(time.time() * 1000) % 1000000)
    os.write(fd, (a.command + "; echo " + tag + "=$?\n").encode())
    pat = re.compile((r"\n" + tag + r"=(\d+)").encode())
    buf, end = b"", time.time() + a.timeout
    while time.time() < end:
        if select.select([fd], [], [], 0.2)[0]:
            try: buf += os.read(fd, 65536)
            except BlockingIOError: pass
            m = pat.search(buf.replace(b"\r", b""))
            if m:
                text = buf.replace(b"\r", b"")[:m.start()].decode(errors="replace")
                lines = text.split("\n")
                # drop the echoed command line(s): everything up to the one that carries the tag
                for i, l in enumerate(lines):
                    if tag in l or "=$?" in l:
                        lines = lines[i + 1:]
                        break
                print("\n".join(lines))
                sys.exit(int(m.group(1)))
    print(buf.decode(errors="replace"))
    print("console.py: no end of command after %.0f s" % a.timeout, file=sys.stderr)
    sys.exit(124)


if __name__ == "__main__":
    main()
