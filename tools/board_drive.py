#!/usr/bin/env python3
"""board_drive.py LOG - every step of ocv/measure.sh on the board, over the serial console: run a step, reboot
into the next image, wait for the shell, again - until measure.sh says ALL DONE (or a step does not end as
expected). All the console prints goes to LOG. The board must be booted with the step's image."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_con as bc

log = open(sys.argv[1], "a", buffering=1)
fd = bc.open_tty()


def say(s):
    log.write(f"\n##DRIVE {time.strftime('%H:%M:%S')} {s}\n")


def send(s):
    for ch in (s + "\n").encode():          # slowly: the console drops characters on long lines
        os.write(fd, bytes([ch])); time.sleep(0.004)


def wait(rx, tmo):
    out = bc.wait(fd, rx, tmo, None, False)
    log.write(out)
    return out


for k in range(12):
    say(f"step run {k + 1}")
    send("sh /run/media/FAT-mmcblk1p1/ocv/measure.sh; echo MEAS_END_$((100+$?))")
    out = wait(r"MEAS_END_\d{3}", 4 * 3600)
    if "MEAS_END_" not in out: say("TIMEOUT"); sys.exit(2)
    if "ALL DONE" in out: say("ALL DONE"); sys.exit(0)
    if "Next:" not in out: say("STEP DID NOT END AS EXPECTED"); sys.exit(1)
    time.sleep(2)
    send("sync; reboot")
    if "login" not in wait(r"automatic login\)|login:", 600): say("NO LOGIN AFTER REBOOT"); sys.exit(3)
    time.sleep(8)
    send("echo READY_$((40+2))"); wait(r"READY_42", 30)
say("TOO MANY STEPS"); sys.exit(4)
