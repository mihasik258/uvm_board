#!/usr/bin/env python3
"""board_con.py - the board's serial console (USB-UART, 115200) from the PC.

    board_con.py "command" [timeout_s] [until_regex]     send a line, print what comes back until the regex
                                                          matches (or nothing new for IDLE s / the timeout)
    board_con.py --send local.gz remote_path              put a gzip file on the board (base64 chunks, each
                                                          checked with md5sum; unpacked by python3 there)

The console drops bytes when pushed: chunks are short and checked. OCV_TTY: the device (default /dev/ttyUSB0)."""
import base64, hashlib, os, re, select, sys, termios, time

DEV = os.environ.get("OCV_TTY", "/dev/ttyUSB0")


def open_tty():
    fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = 0; a[1] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[3] = 0
    a[4] = a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def wait(fd, rx, tmo, idle=None, echo=True):
    buf = ""; t0 = time.time(); last = t0
    while time.time() - t0 < tmo:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            d = os.read(fd, 65536).decode(errors="replace"); buf += d; last = time.time()
            if echo: sys.stdout.write(d); sys.stdout.flush()
            if rx and re.search(rx, buf): break
        elif idle and time.time() - last > idle:
            break
    return buf


def line(fd, s):
    os.write(fd, (s + "\n").encode())


def send(src, dst):
    fd = open_tty()
    line(fd, "stty -echo; rm -f /tmp/x.b64"); time.sleep(0.5); wait(fd, None, 1, 0.5, False)
    data = base64.b64encode(open(src, "rb").read()).decode()
    n = retries = 0
    for i in range(0, len(data), 512):
        k = data[i:i + 512]; want = hashlib.md5(k.encode()).hexdigest()
        for _ in range(8):
            line(fd, f"printf %s {k} > /tmp/c; md5sum /tmp/c")
            m = re.search(r"([0-9a-f]{32})  /tmp/c", wait(fd, r"[0-9a-f]{32}  /tmp/c", 10, None, False))
            if m and m.group(1) == want:
                line(fd, "cat /tmp/c >> /tmp/x.b64; echo A_$((1+1))"); wait(fd, r"A_2", 10, None, False); break
            retries += 1; wait(fd, None, 0.3, 0.3, False)
        else:
            print("board_con: chunk", n, "failed"); return 1
        n += 1
    line(fd, "python3 -c \"import base64,gzip; open('/tmp/x.bin','wb').write(gzip.decompress(base64.b64decode("
             "open('/tmp/x.b64').read())))\"; " f"cat /tmp/x.bin > {dst}; md5sum {dst}; stty echo; echo DONE_$((5+5))")
    out = wait(fd, r"DONE_10", 60, None, False)
    m = re.search(r"([0-9a-f]{32})  " + re.escape(dst), out)
    print(f"board_con: {dst} md5 {m.group(1) if m else '?'} ({n} chunks, {retries} retries)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--send":
        sys.exit(send(sys.argv[2], sys.argv[3]))
    fd = open_tty()
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd or os.environ.get("NL"): line(fd, cmd)
    wait(fd, re.compile(sys.argv[3]).pattern if len(sys.argv) > 3 else None,
         float(sys.argv[2]) if len(sys.argv) > 2 else 10, float(os.environ.get("IDLE", "3")))
