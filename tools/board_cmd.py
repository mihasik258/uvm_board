#!/usr/bin/env python3
"""board_cmd.py - one command on the board's console, typed slowly (the console drops characters of long lines),
then its output until it has ended (a marker echoed after it) or the timeout; the exit code is the command's.

    tools/board_cmd.py "command" [timeout_s]           (default 600)
    tools/board_cmd.py --reboot "command before reboot" [timeout_s]   then wait for the automatic login
"""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_con as bc

fd = bc.open_tty()


def send(s):
    for ch in (s + "\n").encode():
        os.write(fd, bytes([ch])); time.sleep(0.004)


def main():
    a = sys.argv[1:]
    reboot = bool(a) and a[0] == "--reboot"
    if reboot: a = a[1:]
    cmd, tmo = a[0], float(a[1]) if len(a) > 1 else 600
    if reboot:
        send(f"{cmd}; sync; reboot")
        out = bc.wait(fd, r"automatic login\)|login:", tmo, None, True)
        if not re.search(r"automatic login\)|login:", out): print("\nboard_cmd: no login after reboot"); return 3
        time.sleep(8)
        send("echo READY_$((40+2))")
        return 0 if "READY_42" in bc.wait(fd, r"READY_42", 30, None, True) else 4
    send(f"{cmd}; echo CMD_END_$((1000+$?))")
    out = bc.wait(fd, r"CMD_END_1\d{3}", tmo, None, True)
    m = re.search(r"CMD_END_1(\d{3})", out)
    if not m: print("\nboard_cmd: timeout"); return 2
    return int(m.group(1))


if __name__ == "__main__":
    sys.exit(main())
