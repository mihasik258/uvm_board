# День с платой: что на карте и что запускать

Всё собрано заранее; с картой остаётся сложить папку, скопировать и прогнать.

## 1. Папка для SD-карты (на ПК)

```bash
cd verif-diplom
P=examples/cv32e40p/build/prog
hw/cpu/make_sd.sh -o build/sd \
    examples/cv32e40p/cv32e40p.bind $P/hello-world.hex $P/dhrystone.hex $P/coremark.hex -- \
    examples/scr1/scr1.bind examples/scr1/programs/hello.hex examples/scr1/programs/dhrystone21.hex -- \
    examples/cva6/cva6.bind $P/hello-world.hex $P/dhrystone.hex $P/coremark.hex
examples/cv32e40p/uvm_fast/sd.sh build/sd          # тест 1: UVM core-v-verif на ARM
```

Содержимое `build/sd` целиком — на раздел FAT карты (BOOT.BIN — образ первого ядра, CV32E40P).
Проверка перед копированием: даты `BOOT_*.BIN` — после последней сборки образа (`hw/cpu/run.sh <bind> vd100`).

## 2. На плате (root, консоль)

```sh
F=/run/media/FAT-mmcblk1p1
# CV32E40P (загружается по умолчанию)
sh $F/ocv/cpu/cv32e40p/board_run.sh                 # сгенерированный тест (jit, fast, задержки памяти, 30 программ) + программы
sh $F/ocv/cpu/cv32e40p/uvm_fast/board_uvm.sh        # тест 1: hello, dhrystone, coremark через UVM-тестбенч
# другое ядро: образ, перезагрузка, его прогон
sh $F/ocv/cpu/use.sh scr1 && reboot                 # затем: sh $F/ocv/cpu/scr1/board_run.sh
sh $F/ocv/cpu/use.sh cva6 && reboot                 # затем: sh $F/ocv/cpu/cva6/board_run.sh  (тест 2)
```

## 3. С чем сравнивать (ПК, уже замерено)

| тест | ПК | замер на плате |
|---|---|---|
| тест 1, dhrystone (157 тыс. команд) | чистый UVM 104–129 с; тест 1 с ПЛИС в Verilator 3.2 с | |
| тест 1, coremark (2.79 млн) | чистый UVM 1856–2257 с; тест 1 с ПЛИС в Verilator 15.8 с | |
| тест 2, CVA6, сгенерированные программы | 52 тыс. команд/с на одно ядро ПК (Verilator -O3) | |

Если что-то не так: строка `MISMATCH` называет канал и запись; тот же прогон на ПК —
`hw/cpu/run.sh <bind> cosim <программа>` (тот же seed — та же программа).

## 4. DMA-кольца (этап 2, образ `examples/scr1/build/vd100/scr1_dma/sdcard`)

Образ SCR1, у которого поток команд уходит в память PS по AXI → NoC → DDR (`OCV_GEN_FLAGS="--dma 128"`).
Скопировать `sdcard/` целиком на FAT-раздел, загрузиться, затем:

```sh
F=/run/media/FAT-mmcblk1p1/ocv
# 0. что за процессор и память под кольца
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
grep -i huge /proc/meminfo; cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
$F/run.sh --info                                            # хаб; у выхода retire в KIND есть DMA (бит 15)
# 1. DMA против шины, одна и та же программа (время прогона и профиль)
OCV_DMA_VERBOSE=1 $F/run.sh --model-opt program=$F/dhrystone21.hex --profile
$F/run.sh --model-opt program=$F/dhrystone21.hex --profile --no-dma
OCV_DMA_VERBOSE=1 $F/run.sh --model-opt program=$F/random_s1.hex --profile
$F/run.sh --model-opt program=$F/random_s1.hex --profile --no-dma
# 2. со свёрткой
$F/run.sh --model-opt program=$F/random_s1.hex --squash 256 --profile
```

Что смотреть:
- строка `OCV: outputs over DMA rings in PS memory: retire (...)`. Если её нет, не нашлась память:
  `OCV_DMA_VERBOSE=1` скажет почему. Тогда `echo 4 > /proc/sys/vm/nr_hugepages` и повтор;
- `PASS` в обоих режимах и время прогона;
- в профиле — долю «drain outputs (bus reads)»: с DMA она должна почти исчезнуть.

Если прогон с DMA зависает или даёт `DMA stuck` / `DMA write error`, снять вывод `--info` и
`devmem 0x80080054` (DMA_STAT выхода retire: слот 2, слоты по 256 КиБ).
