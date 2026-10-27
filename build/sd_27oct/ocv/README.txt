OCV, 27.10: OTBN+KMAC (ML-DSA-87) and the 64-bit CVA6 - UVM tests by the contract on the board.
BOOT.BIN = otbn (45 MHz). Other images: BOOT_otbn_fault22.BIN, BOOT_cva6_64.BIN, BOOT_cva6_64_fault.BIN.

F=/run/media/FAT-mmcblk1p1/ocv
sh $F/otbn/board_run.sh 10            # 10 rounds keygen+sign (PC: ~2 min 20 s per round)
sh $F/use.sh otbn_fault22 && reboot   # then: sh $F/otbn/board_run.sh 30   (PC: caught in round 5, ~16 min)
sh $F/use.sh cva6_64 && reboot        # then: sh $F/cva6_64/board_run.sh ; sh $F/cva6_64/board_run.sh long
sh $F/use.sh cva6_64_fault && reboot  # then: sh $F/cva6_64/board_run.sh minstret64 ; ... long
Logs: next to each board_run.sh.
