# Диплом: «Система функциональной верификации на основе гибридных вычислительных систем»

Исследовательские заметки. Дата: 11.10.2026.
**Статус:** этап ОЗНАКОМЛЕНИЯ с задачей и формулировки цели. Решения НЕ принимать, пока пользователь
явно не скажет.

---

## 00. Входные данные от пользователя (11.10.2026)

1. **Платы:** их будет 2. Будет Zynq, но пока есть **Alinx VD100 (Versal AI Edge XCVE2302)**.
2. **SV/UVM не обязателен.** Как один из вариантов рассмотреть обязательно. Для полной проверки по эталону
   UVM очевидно не нужен.
   - UVM тащить только если это не бессмысленный труд.
   - Если UVM-решение окажется лучше существующих без дорогих эмуляторов — «будет очень круто».
3. **Объекты проверки:** важны и RISC-V ядра, и IP-блоки; **начинаем с RISC-V ядер**.
4. **Гибридная система = ПЛИС + ARM.** Научная новизна не обязательна, но проект должен быть **качественным**.
5. **Поправка:** ARM заметно слабее ПК, поэтому **нагружать ARM вычислениями помимо эталонной модели —
   плохая идея**. Всё, что в разделах 5–6 ниже отдаёт ARM агрегацию, сжатие, распаковку стимулов и подобное,
   нужно пересмотреть с учётом этого.
6. Пользователь положит в папку свои наработки. **Не все идеи в них верны**: читать критически и опираться
   на выводы этого обзора.

### Факты о VE2302 / VD100 (AMD Versal AI Edge Product Selection Guide, GitHub alinxalinx/VD100_2023.2)
- **APU:** 2× Cortex-A72 (L1 48 КБ / 32 КБ, L2 1 МБ), около 18.9K DMIPS.
  **RPU:** 2× Cortex-R5F (TCM 256 КБ).
- **PL:** 150 272 LUT (328 720 system logic cells), 464 DSP, BRAM 5.4 Мб, **URAM 43.6 Мб**, 34 тайла AIE-ML.
- **PCIe:** 1× PL PCIE4 Gen4x8, без CPM и без встроенного DMA; 8 GTYP. DDR4 до 25.6 ГБ/с.
- **Плата:** 4 ГБ DDR4, разъём PCIe 3.0 x4 (endpoint это или root — **не выяснено**), 2× GbE (один на PS,
  один на PL), 2× SFP+, JTAG. Среда Vivado/Vitis/PetaLinux 2023.2.
- По сравнению с Zynq-7000: A72 заметно сильнее A9 и A53, но всё равно слабее ПК. Ресурсов ПЛИС больше
  (вмещаются ядра крупнее PicoRV32). У Versal своя связь PS↔PL через NoC/CIPS, а не порты HP/GP.
  Латентность и полосу нужно будет **мерить**.
- Сайт alinx.com закрыт JS-защитой от ботов: руководство пользователя скачать не удалось. Попросить у пользователя
  при необходимости.

---

## 0. Короткий вывод

- Идея актуальна. С 2023 по 2025 год вышла целая серия работ про верификацию на SoC-FPGA (ARM + ПЛИС), см. раздел 4.
  Это и хорошо (тема признана), и опасно: идея «ISS на ARM, ядро в ПЛИС, сравниваем» **уже опубликована**
  (FERIVer, CF'25, Zynq-7020). Новизну нужно искать в другом месте (раздел 6).
- **ARM сам по себе не быстрее x86-хоста.** Cortex-A9 на 667 МГц и A53 на 1.2 ГГц на одно ядро в разы слабее
  настольного x86. Перенос тяжёлых вычислений на ARM ничего не ускоряет. Выигрыш даёт другое:
  1. **латентность**: связь ARM↔ПЛИС внутри кристалла (AXI) против PCIe/JTAG/Ethernet до хоста;
  2. **сокращение данных у источника**: ARM фильтрует, сжимает и агрегирует, на хост уходят только расхождения и покрытие;
  3. **конвейеризация**: ПЛИС, ARM и хост работают одновременно;
  4. **дешёвое масштабирование**: ферма из дешёвых плат вместо эмулятора (ZynqParrot: около $100 на плату в год).
- Главный фундаментальный факт из литературы: когда DUT в ПЛИС, узким местом становится **связь DUT↔эталон**,
  а не сама симуляция. DiffTest-H: на FPGA DUT в одиночку быстрее RTL-симуляции примерно в 10000 раз, а ко-симуляция
  с эталоном быстрее всего в 20 раз, потому что **больше 98% времени уходит на коммуникацию**. Именно здесь гибридная
  SoC с ARM рядом с ПЛИС имеет реальное преимущество. На этом стоит строить работу.

---

## 1. Почему большие UVM-тесты медленные

- Тестбенч однопоточный и выполняется в отдельных временных слотах, не параллельно с DUT. Многоядерные симуляторы
  (Xcelium MC, VCS FGP) параллелят только RTL, но не тестбенч (DVCon, «Crafting a Million Instructions/Sec RISCV-DV»).
- Самое дорогое обычно `randomize()`: решатель ограничений и требование равномерного распределения из LRM.
  Лишние вызовы randomize дорого обходятся.
- Алгоритмический код на SV на порядок медленнее C/C++: у каждой переменной неявное событие изменения значения.
- Обмен через DPI тоже имеет накладные расходы.
- Прочее: логирование и строки, запись транзакций и волн, `uvm_config_db` в run-фазе, тысячи объектов и сборщик мусора,
  сэмплирование covergroup на каждом такте.
- Правило из DVCon (Meade, «UVM Testbench Considerations for Acceleration»): **прежде чем ускорять, профилируй.**
  Если основное время тратит тестбенч, а не DUT, аппаратное ускорение DUT не поможет (закон Амдала).

## 2. Как ускоряют в индустрии (общие приёмы)

### 2.1 Программные
| Приём | Суть | Порядок эффекта |
|---|---|---|
| Save/Restore, Dynamic Test Load (Xcelium) | не повторять reset/init; загружать новую последовательность в сохранённый снапшот | компиляция и запуск ≈5 мин → 1 мин |
| Многопоточный RTL-движок (Xcelium MC, VCS FGP, Verilator `--threads`) | параллелизм внутри DUT | разы, тестбенч не ускоряется |
| Инкрементальная и параллельная сборка | | время компиляции |
| Регрессионная ферма и ML-отбор тестов | запускать только «новые» тесты | Xcelium ML ≈3×; в работах до −85% RTL-времени при том же покрытии |
| Генераторы на нативном языке | riscv-dv на SV ≈10k инстр/с; параллельный порт на eUVM (D) даёт **миллионы инстр/с, >100×** | |
| GPU-симуляция RTL | RTLflow: в 40 раз быстрее 80-поточного CPU при *пакетных стимулах*; GEM (DAC'25, NVIDIA): до 64× | хорошо, когда много независимых стимулов |
| Распределённый UVM (AMD, DVCon) | SoC-тестбенч режется на IP-тестбенчи в разных процессах; TLM через ZeroMQ + UVMC | масштабирование, но теряется потактовость на границах |
| Снапшоты через fork() (LightSSS, XiangShan) | copy-on-write снимок процесса; при ошибке волны только за последние N тактов | дешёвая отладка длинных тестов |

### 2.2 Аппаратные
- **Эмуляторы** (Palladium, ZeBu, Veloce): около 500 кГц – единицы МГц; RTL-симулятор для большого ядра — единицы кГц.
  Дорого.
- **FPGA-прототипы**: десятки МГц, плохая видимость сигналов.
- **Transaction-Based Acceleration (TBA) / ко-эмуляция**, стандарт Accellera **SCE-MI 2.x**:
  - тестбенч делится на **HVL** (нетактируемый: UVM-последовательности, scoreboard, покрытие на хосте)
    и **HDL** (синтезируемые BFM/транзакторы рядом с DUT);
  - между частями ходят только транзакции, через функции DPI и потоковые **pipes**;
  - получают «100× и больше», если тестбенч быстро генерирует транзакции и редко синхронизируется
    (Aldec HES: 130× на NoC с UVM).
- **Hybrid emulation**: *виртуальный прототип* (ARM Fast Models) плюс эмулятор. Внимание: здесь «гибрид» означает
  не ARM+ПЛИС. В тексте диплома термин нужно определить явно, чтобы не путать.
- **Portable Stimulus (PSS)**: одна модель генерирует UVM-последовательности для IP и C-тесты для встроенного
  процессора. Тесты переносятся из симуляции в эмуляцию и в кремний. Это связано с идеей «тест исполняется на ARM».
- **Синтезируемые ассерты (SVA → RTL)** и **счётчики покрытия в железе**. Проблема: миллионы счётчиков занимают
  ресурсы и требуют трассировки к хосту.

## 3. Процессоры: миллионы и миллиарды инструкций

- **Lock-step ко-симуляция с ISS**: на каждом retire сравнивается архитектурное состояние.
  Эталоны: Spike, Dromajo, NEMU, ImperasDV (стандарт интерфейса **RVVI**). Ядра отдают трассу через RVFI/RVVI.
- **Недетерминированные события** (прерывания, MMIO) приходится синхронизировать из DUT в эталон. Это ломает
  простое пакетирование.
- **FPGA ко-симуляция**:
  - Fromajo (FireSim + Dromajo, SonicBOOM): больше 1 МГц ко-симуляции на 100-МГц ПЛИС.
  - **DiffTest-H** (MICRO'25, XiangShan, ICT CAS): 7.8 МГц на FPGA, 478 кГц на Palladium; в 78–80 раз быстрее
    базового DiffTest, около 1945× против 16-поточного Verilator; нашёл 151 баг.
    - Модель накладных расходов: `Overhead = N_invokes·T_sync + N_bytes/BW + T_software`.
    - Приёмы:
      - **Batch**: плотная упаковка разнородных событий в одну передачу; при фиксированных смещениях
        больше 60% пакета — пузыри;
      - **Squash**: слияние событий, порядок проверки отделён от порядка передачи, NDE передаются с тегами;
      - **Replay**: при ошибке заново обработать неслитые события вокруг точки сбоя, чтобы сохранить
        отладку с точностью до инструкции;
      - неблокирующая передача.
    - Цифры: в исходном DiffTest около 15 обменов и 1.2 КБ данных **на такт**. Упаковка 256 событий по 16 Б
      в одну передачу 4 КБ уменьшает число стартов обмена в 256 раз.
    - Таблица платформ: RTL-симулятор около 3 кГц, эмулятор около 500 кГц, FPGA около 50 МГц.
- **Фаззинг процессоров**:
  - DifuzzRTL: покрытие по регистрам управления, FireSim/AWS F1;
  - ProcessorFuzz: покрытие по CSR;
  - MorFuzz;
  - **TurboFuzz** (2025): цикл генерация → исполнение → покрытие целиком на ПЛИС; в 2.23 раза больше покрытия,
    до 571× быстрее находит баги;
  - **Lyra** (2025): DUT и REF на FPGA-SoC плюс генеративная модель (LyraGen); от 107 до 3343× end-to-end.
- **Отладка после расхождения** (видимость в ПЛИС ограничена):
  - DESSERT (FPL'18): снапшоты через scan-chain, повтор на триллионах тактов;
  - FERIVer: PCAP readback конфигурационной памяти;
  - Hassert: снапшот всей ПЛИС при срабатывании ассерта;
  - DiffTest-H: replay-буфер.
  - Общий принцип: **быстро в железе, детально в софте**. Ошибку воспроизводят в симуляторе от ближайшего
    чекпойнта.

## 4. Прямые аналоги на гибридных SoC (ARM + ПЛИС). Это PRIOR ART, читать внимательно

| Работа | Платформа | ARM (PS) | ПЛИС (PL) | Результат |
|---|---|---|---|---|
| **FERIVer** (TUM, CF'25) | Zynq XC7Z020, хост Ryzen | QEMU как ISS (RV32I), драйверы | PicoRV32 + Arbiter (сравнение GPR каждые N инструкций) + PCAP-мост | до **5.31 MIPS**; 20–35× против Verilator, 150–177× против XSim; 0.6K slices; при расхождении JSON-чекпойнт → cocotb + iverilog на хосте → GTKWave |
| **ENCORE** (ICT CAS, FPGA'23) | FPGA SoC с hard-ядрами | программный эмулятор (REF) | DUT + аппаратные мониторы и компараторы регистров, пауза при расхождении | >44000× против программной симуляции; снапшот уходит в софт-симулятор |
| **Hercules** (FPGA'25) | то же | C/C++ модель HLS-дизайна | HLS-RTL + автоматически сгенерированные пробы | **IP-блоки**, не только CPU |
| **Hassert** (ASPLOS'24) | FPGA | | SVA → ПЛИС; смена ассертов через **частичную реконфигурацию** | снапшот при срабатывании |
| **ZynqParrot** (UW, 2025, BSD-3, github black-parrot-hdk/zynq-parrot) | Zynq-7020, Ultra96v2, ZCU102 | PetaLinux/PYNQ, C++ хост-модели (DRAM, системные вызовы) | DUT + **P-Shell** (CSR + SB-FIFO через GP0) + **clock gating DUT** для потактовой точности и невмешательства | 1–10 МГц; **тот же C++ код** работает в Verilator и на плате; около $100 на ПЛИС в год против $2000–5000 в облаке |
| Cocotb-Pynq (FPL'25) | PYNQ | Python-код хоста | RTL | ко-симуляция Python+RTL без генерации битстрима |
| Lyra (2025) | FPGA SoC | | DUT + REF + покрытие | генеративная модель |

**Слабые места FERIVer**, которые можно улучшить в дипломе:
1. QEMU TCG однопоточный: одно ядро A9 загружено, второе простаивает. QEMU занимает около 250 МБ из 512 МБ DDR.
2. Состояние снимается через PCAP readback: максимум около 140 МБ/с, много padding, JTAG приходится отключать.
   Сравниваются только GPR.
3. DUT маленький и многотактный (PicoRV32), поэтому 5 MIPS легко достигаются.
4. При росте доли ошибок скорость падает: каждое расхождение реконструируется на хосте.
5. Нет UVM, нет покрытия, нет генерации стимулов (бенчмарки ssort, qsort, md5).
6. Только Zynq-7000.

Группа Kan Shi и Yungang Bao (ICT CAS) — главный «конкурент» по этой линии: ENCORE, Hassert, Hercules, TurboFuzz,
Lyra, DiffTest-H. **Ни одна из этих работ не интегрируется с UVM**: везде C, Python или собственные фреймворки.
Это пробел.

## 5. Анализ «что куда переносить» (три уровня: ПЛИС / ARM / x86-хост)

> ⚠️ Таблица ниже — первоначальный вариант. По поправке пользователя (раздел 00, п.5) ARM должен считать
> **только эталонную модель** (и минимальную обвязку обмена). Строки, где ARM агрегирует, распаковывает
> или триажит, — кандидаты на перенос в ПЛИС или на ПК. Это не решение, а пометка к обсуждению.

| Задача | Где лучше | Почему |
|---|---|---|
| DUT | ПЛИС | |
| BFM/транзакторы, clock gating, буферы трасс | ПЛИС | потактовая работа |
| Сравнение широкого состояния на каждом такте, ассерты, счётчики покрытия, LFSR-генераторы, сжатие трасс | ПЛИС | параллельно, без связи |
| Пошаговая эталонная модель (ISS step, C++ модель IP), scoreboard, синхронизация NDE, управление потоком, «распаковка» стимулов из seed/параметров, агрегация покрытия, первичный триаж | **ARM** | малая латентность до ПЛИС, данные не уходят с кристалла |
| Решатель ограничений SV/UVM, план тестов, ML-закрытие покрытия, слияние БД покрытия (UCIS), реконструкция волн и отладка, отчёты | x86-хост | вычислительно тяжело, нужны лицензии и симулятор |

- Модель стоимости: расширить формулу DiffTest-H на три уровня. При конвейеризации
  `T ≈ max(T_DUT, T_ARM, T_link_PS-PL, T_link_host, T_host)`. Это даёт **аналитическую часть диплома**:
  куда ставить границу и каким делать размер пакета.
- Параметры Zynq-7000 (UG585, теоретические):
  - HP: 4 порта по 64 бит, 150 МГц, 1200 МБ/с чтение и 1200 МБ/с запись на порт;
  - GP: 32 бит;
  - ACP: 64 бит, когерентный с L1/L2, низкая латентность.
  - Реально: AXI DMA 32 бит на 100 МГц на Zybo Z7-10 упирается в `copy_to_user` при 400 МБ/с теории.
    → нужен **zero-copy** (udmabuf / UIO / u-dma-buf).
- Zynq UltraScale+ (Ultra96v2, **Kria KV260**: 4×A53 1.2–1.33 ГГц, 2×R5F, около 256K логических ячеек, 4 ГБ DDR,
  около $199–284). Порты HP/HPC/ACP. На этой SoC можно разделить роли: **R5 для жёсткой синхронизации
  в реальном времени, A53 для эталона** (OpenAMP). В литературе показана суб-микросекундная латентность между
  блоками US+.

## 6. Идеи для реализации (кандидаты, ещё не выбраны)

**I1. Методика разбиения задач верификации на три уровня + аналитическая модель + экспериментальная проверка.**
Научное ядро. Измерить разбивку времени (DUT / старт обмена / передача / софт) для разных вариантов размещения
и размеров пакета. Сравнить с предсказанием модели.

**I2. UVM поверх гибридной SoC: «SCE-MI для бедных».**
- UVM-окружение на хосте (Questa/VCS/Xcelium, если есть; иначе Verilator ≥ 5.04x с UVM 2017).
- Драйвер шлёт не сигналы, а **пакеты транзакций или seed+параметры** через TCP/ZeroMQ на ARM.
- ARM разворачивает их и гонит в ПЛИС через AXI DMA.
- Обратно идут только расхождения и счётчики покрытия. Они попадают в обычный UVM scoreboard и covergroup
  (через DPI или sample).
- Цель: тестбенч пишется «как обычно», а исполнение аппаратное.
- **Пробел в литературе: аналоги не используют UVM.**

**I3. Улучшенный FERIVer для RISC-V** (сильная база для сравнения: тот же PicoRV32 на Zynq-7020).
- Вместо PCAP — **поток трассы RVFI через AXI-Stream DMA**.
- Вместо QEMU — лёгкий ISS (Spike под aarch64 или свой).
- Задействовать оба или все четыре ядра: одно принимает и распаковывает, остальные исполняют REF.
- Batch/Squash по мотивам DiffTest-H.
- Replay-буфер в ПЛИС на последние N коммитов.
- DUT покрупнее: SCR1 (Syntacore, открытый, отечественный), Ibex (есть RVFI), VexRiscv, CV32E40P.

**I4. Вариант для IP-блоков** (то, что вы назвали «различные IP-блоки»).
- Универсальный транзактор AXI-Stream / AXI-Lite в ПЛИС, C++ golden model и scoreboard на ARM.
- Примеры DUT: AES, CRC, FIR/FFT, UART/SPI.
- Похоже на Hercules, но для ручного RTL и с UVM.

**I5. Аппаратное функциональное покрытие.**
- Бины-счётчики в ПЛИС, ARM агрегирует и выдаёт в формате для UVM/UCIS.
- Замкнутый цикл: ARM меняет веса генератора по непокрытым бинам (лёгкий coverage-guided fuzz).

**I6. Отладка: расхождение → снапшот → повтор в симуляторе.**
- Периодические чекпойнты плюс журнал входов; воспроизведение последних N тактов в Verilator или Questa,
  на выходе волны.
- Метрика: «время от бага до волны».

**I7. Объективная оценка через внесение ошибок (mutation / bug injection).**
- Метрика: время до обнаружения внесённого бага в каждой конфигурации.

**I8. Масштабирование:** несколько плат как регрессионная ферма (если плат несколько). Опционально.

**I9. (Рискованно) UVM целиком на ARM.**
- Verilator с октября 2025 года собирает upstream UVM 2017 без патчей. C++-модель можно собрать под aarch64
  и запустить UVM прямо на A53, с DUT в ПЛИС через DPI → AXI.
- Интересно и ново, но ARM медленный, а поддержка UVM в Verilator ещё молодая.

**I10. Использование R5 (US+) с OpenAMP** для детерминированной латентной части. Опционально.

Возможная комбинация на диплом: I1 (модель) + I2 (UVM-интеграция) + 2 кейса (I3 RISC-V и I4 IP-блок) + I5/I6
как расширения + I7 для оценки. Окончательно НЕ выбрано.

## 7. Что измерять (метрики)
- Пропускная способность: инструкций/с (MIPS), транзакций/с, тактов DUT/с.
- Ускорение относительно Verilator (1 и N потоков), XSim, Questa/VCS (если есть). Обязательно сравнение с FERIVer
  на одинаковой паре плата + DUT.
- Разбивка накладных расходов (как на рис. 2 DiffTest-H): DUT, старт обмена, передача, софт.
- Зависимость от размера пакета, частоты синхронизации и доли NDE.
- Покрытие во времени (coverage/час), время до бага (bug injection), время до волны.
- Ресурсы ПЛИС (LUT, FF, BRAM), загрузка ядер ARM, память.
- Стоимость: плата против эмулятора или облака.

## 8. Инструменты и железо (варианты)
- Платы: Zynq-7020 (PYNQ-Z2, Zybo Z7-20, ZedBoard) или US+ (Ultra96v2, KV260, ZCU104).
- ПО: Vivado; PetaLinux или PYNQ; Verilator; cocotb/pyuvm; Spike; riscv-dv / FORCE-RISCV; ZeroMQ или gRPC;
  udmabuf; GTKWave/Surfer.
- Готовые основы: ZynqParrot (P-Shell, BSD-3), FERIVer (как схема), OpenXiangShan/difftest (как идеи протокола).

## 9. Риски
- Доступ к плате и её тип определяют всё.
- Лицензии коммерческого симулятора для UVM (если их нет, остаются Verilator+UVM или pyuvm).
- Время синтеза в Vivado замедляет итерации.
- Сложность драйверов DMA в Linux.
- Новизна: нужно явно отстроиться от FERIVer, ENCORE и Hercules.
- Честность сравнения: ARM медленнее x86; это надо показывать, а не прятать.

## 10. Вопросы к пользователю
(Вопросы 1–4 закрыты ответами в разделе 00. Открытые вопросы на будущее: режим PCIe на VD100, когда будет Zynq
и какая именно, состав наработок пользователя.)
1. Какая плата есть или будет (Zynq-7000 или UltraScale+)? Сколько штук?
2. Есть ли доступ к Questa/VCS/Xcelium? Обязателен ли именно UVM на SystemVerilog?
3. Что приоритетнее как DUT: RISC-V ядро, произвольные IP-блоки или оба?
4. Требования кафедры: что понимается под «гибридной вычислительной системой» (CPU+ПЛИС? CPU+GPU?),
   нужна ли научная новизна или достаточно инженерной реализации, объём, сроки.
5. Есть ли у вас свой RTL (IP-блок или ядро), который хотелось бы использовать?

## 11. Источники
- FERIVer: https://arxiv.org/pdf/2504.05284
- DiffTest-H: https://talks-pubs.xiangshan.cc/publications/micro2025-DiffTestH.pdf , https://github.com/OpenXiangShan/difftest
- ZynqParrot: https://arxiv.org/pdf/2509.20543 , https://github.com/black-parrot-hdk/zynq-parrot
- ENCORE (FPGA'23): https://dl.acm.org/doi/10.1145/3543622.3573187
- Hercules (FPGA'25): https://dl.acm.org/doi/10.1145/3706628.3708866
- Hassert (ASPLOS'24): https://dl.acm.org/doi/10.1145/3622781.3698899
- TurboFuzz: https://arxiv.org/pdf/2509.10400
- Lyra: https://arxiv.org/pdf/2512.13686
- Cocotb-Pynq (FPL'25): https://nachiket.github.io/publications/cocotb-pynq_fpl-2025.pdf
- Fromajo/FireSim: https://github.com/firesim/firesim/pull/541 , https://fires.im/
- DifuzzRTL: https://compsec.snu.ac.kr/papers/hur-difuzzrtl.pdf ; ProcessorFuzz: https://arxiv.org/pdf/2209.01789
- MinJie/LightSSS (XiangShan): https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf
- RISCV-DV на eUVM, «Crafting a Million Instructions/Sec RISCV-DV»: https://dvcon-proceedings.org/wp-content/uploads/1008.pdf
- Distributed Simulation of UVM Testbench (AMD): https://dvcon-proceedings.org/wp-content/uploads/distributed-simulation-of-uvm-testbench.pdf
- UVM Testbench Considerations for Acceleration: https://dvcon-proceedings.org/wp-content/uploads/uvm-testbench-considerations-for-acceleration.pdf
- Off To The Races With Your Accelerated SV Testbench: https://dvcon-proceedings.org/wp-content/uploads/off-to-the-races-with-your-accelerated-systemverilog-testbench-a-methodology-for-hardware-assisted-acceleration-of-systemverilog-testbenches.pdf
- Aldec UVM acceleration: https://www.aldec.com/en/solutions/hardware_emulation_solutions/acceleration
- RTLflow: https://tsung-wei-huang.github.io/papers/icpp22-rtlflow.pdf ; GEM: https://github.com/NVlabs/GEM
- Verilator + UVM 2017 (Antmicro, 10.2025): https://antmicro.com/blog/2025/10/support-for-upstream-uvm-2017-in-verilator
- ML-отбор тестов: https://arxiv.org/pdf/2207.00445 , https://arxiv.org/pdf/2503.11666
- Zynq DMA benchmark: https://blog.reds.ch/?p=2054 ; UG585: https://class.ece.iastate.edu/cpre488/resources/ug585-Zynq-7000-TRM.pdf
- KV260: https://www.amd.com/content/dam/amd/en/documents/products/som/kria/k26/kv260-product-brief.pdf
- Low-latency на US+ MPSoC: https://drops.dagstuhl.de/storage/01oasics/oasics-vol128-ng-res2025/OASIcs.NG-RES.2025.2/OASIcs.NG-RES.2025.2.pdf

---

## 12. Второй проход СЛИВА (октябрь 2026) — прирост сверх раздела 11

### Ключевые новые находки

1. **Verilator 5.052 (2026-09-05): поддержка UVM 2020-3.2.**
   Источники: https://github.com/verilator/verilator-announce/issues/85 , https://verilator.org/guide/latest/changes.html
   Обновление к идее I9: Verilator уже догнал UVM 2020 (ограничения отслеживаются в verilator/verilator#1538).
   Также: Thread PGO (балансировка макротасков по потокам), автоматическая NUMA-стратегия (VERILATOR_NUMA_STRATEGY),
   --dpi-thread-safe, покрытие .info с описанием веток. «UVM целиком на ARM через Verilator» в 2026 значительно реалистичнее.

2. **Veripool «Papers on Verilator» (актуален на 2026)**: https://veripool.org/verilator/documentation/
   - Antmicro: UVM 2017 (окт.2025), Enhancing RTL Coverage Reporting (авг.2025), Hierarchical Mode perf (май.2025);
   - «Open-Source UVM Verification of AXI Systems in Verilator» (сент.2024): https://antmicro.com/blog/2024/09/open-source-uvm-verification-axi-in-verilator
   - «Porting a Complete UVC to Verilator + UVM» (AsFigo, ноя.2023): https://asfigo.blogspot.com/2023/11/porting-complete-uvc-to-verilator-uvm.html
   - PRO-V — агент RTL-верификации на Verilator (дек.2025): https://arxiv.org/abs/2506.12200
   - Renode Bazel Rules для ко-симуляций (ноя.2025): https://renode.io/news/bazel-rules-for-renode/
   - Renode+Verilator для Coral NPU SoC (июль 2026): https://antmicro.com/blog/2026/07/renode-and-verilator-for-coral-npu

3. **DVCon U.S. 2026** ( https://dvcon-proceedings.org/event_year/y2026/ ):
   - «Broadening the Adoption of HW-Assisted Verification with Next Generation Emulation Appliance» (Ganpati, Tamura, Young): https://dvcon-proceedings.org/document/broadening-the-adoption-of-hardware-assisted-verification-with-next-generation-emulation-appliance/
   - «Practical Tips for Adopting PSS» (Tom Fitzpatrick): https://dvcon-proceedings.org/document/practical-tips-for-adopting-pss/
   - «IP-XACT Based PSS Modeling for Shift-Left SoC Verification»: https://dvcon-proceedings.org/document/ip-xact-based-pss-modeling-for-shift-left-soc-verification-3/
   - «AI-Driven Adaptive Emulation for Accelerated Pre-Silicon Debug: High-Fidelity Silicon Replay»: https://dvcon-proceedings.org/document/ai-driven-adaptive-emulation-for-accelerated-pre-silicon-debug-high-fidelity-silicon-replay-2/
   - «Properly Introducing Python to your UVM Testbench» (M. Ballance): https://dvcon-proceedings.org/document/properly-introducing-python-to-your-uvm-testbench-2/
   - «Accelerating Bare Metal Driver Development with Linux Drivers and SV DPI-C»: https://dvcon-proceedings.org/document/accelerating-bare-metal-driver-development-with-linux-drivers-and-system-verilog-dpi-c-2/
   Вывод: в 2026 DVCon почти не публикует чистые TBA/SCE-MI-бенчмарки — методология зрелая; публикации сместились
   к AI/ML-агентам, multi-die, PSS+IP-XACT, Python, cloud.

4. **DVCon India 2025:**
   - «Novel Approach for Verification of Multi Die Booting Using Disruptive Distributed Simulation Methodology» (AMD): https://dvcon-proceedings.org/document/novel-approach-for-verification-of-multi-die-booting-using-disruptive-distributed-simulation-methodology/
   - «Accelerated Coverage Closure with Emulation»: https://dvcon-proceedings.org/document/accelerated-coverage-closure-with-emulation-covering-real-time-use-case-corners/
   - «Bridging RISC-V Core Verification and PSS» (постер): https://dvcon-proceedings.org/document/bridging-risc-v-core-verification-and-pss-a-portable-stimulus-stress-testing-approach/

5. **PSS 3.0** утверждён Accellera 29.08.2024:
   пресс-релиз: https://accellera.org/news/press-releases/402-accellera-unveils-portable-test-and-stimulus-standard-3-0-ushering-in-a-new-era-of-verification-efficiency
   стандарт: https://accellera.org/images/downloads/standards/pss/Portable_Test_Stimulus_Standard_v3.0.pdf
   «Что нового»: https://community.cadence.com/cadence_blogs_8/b/fv/posts/what-s-new-in-pss-3-0-key-additions-to-the-portable-stimulus-standard
   Siemens-обзор: https://blogs.sw.siemens.com/verificationhorizons/2024/10/09/celebrating-the-approval-of-portable-test-and-stimulus-standard-pss-3-0/
   Тренд 2025-26: PSS+IP-XACT (DVCon'26) и «практические советы» (Fitzpatrick) — adoption растёт медленно, open-source PSS-инструментов нет.

6. **SCE-MI: текущая версия 2.4** («minor release», только формулировки): https://accellera.org/downloads/standards/sce-mi
   Major-движения нет с ~2014; инфраструктура живёт в вендорских TBA-стеках:
   Aldec HES-DVM: https://www.aldec.com/en/solutions/hardware_emulation_solutions/acceleration ,
   co-emulation: https://www.aldec.com/en/solutions/hardware_emulation_solutions/co-emulation (SCE-MI API в TLM-прокси/SystemC VP).
   Aldec UVM co-emulation (Grove, DVCon): https://dvcon-proceedings.org/wp-content/uploads/uvm-hardware-assisted-acceleration-with-fpga-co-emulation.pdf

7. **riscv-dv eUVM детали**: порт — «line-by-line translation», реализовано всё кроме functional coverage:
   https://github.com/chipsalliance/riscv-dv/blob/master/euvm/README.md
   Tessolve/Goel «HPC-Powered UVM Testbenching — 500,000 instr/sec»: https://www.tessolve.com/wp-content/uploads/2023/07/Puneet-Goel-euvm-trans-1.pdf ,
   страница: https://www.tessolve.com/hpc-powered-uvm-testbenching/

8. **pyuvm/cocotb 2024–2025:**
   - «Evaluating the Usability of pyuvm with cocotb for UART Verification» (DVCon Europe 2025, paper 116): https://dvcon-proceedings.org/wp-content/uploads/DVConEU_2025_paper_116.pdf
   - «Enable Reuse of SV Verification IPs in cocotb/pyuvm»: https://dvcon-proceedings.org/wp-content/uploads/156-Enable-Reuse-of-SystemVerilog-Verification-IPs-in-cocotbpyuvm.pdf
   - Syosil whitepaper: https://www.syosil.com/images/resources/osv_whitepaper-1.0.3.0.pdf
   - arXiv 2407.10317 (CRV c PyUVM/PyVSC): https://arxiv.org/pdf/2407.10317
   - Tessolve VF2025 (Python vs SV-UVM): https://www.tessolve.com/verification-futures/vf2025-uk/python-based-verification-vs-systemverilog-uvm/

9. **LLM+UVM (академия, 2025):**
   - «From Concept to Practice: LLM-aided UVM Machine» (arXiv 2504.19959): https://arxiv.org/abs/2504.19959 — сетап TB в 38.82× быстрее, покрытие 87.4%/89.6%.
   - VerifLLMBench (DVCon'25, UMN): https://people.ece.umn.edu/users/jsartori/papers/dvcon25.pdf

10. **Coverage-guided RISC-V генерация (2025–2026):**
    - Lyra: https://arxiv.org/pdf/2512.13686
    - HWFuzz (RISC-V Summit Europe 2025, синтезируемый HW-fuzzer IP): https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-P2.2.04-ZHONG-abstract.pdf
    - DiffTest+XFUZZ: https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-P2.2.01-XU-poster.pdf
    - CovR (arXiv 2609.19189, сент.2026, reasoning-guided стимулы): https://arxiv.org/pdf/2609.19189
    - RL-выбор тестов: DVCon Europe 2025 paper 130: https://dvcon-proceedings.org/wp-content/uploads/DVConEU_2025_paper_130.pdf

11. **core-v-verif**: активен как openhwfoundation/core-v-verif; mature CV32E40P + core testbench, работает с OSS-инструментами:
    https://github.com/openhwfoundation/core-v-verif , https://docs.openhwgroup.org/projects/cv32e40p-user-manual/en/latest/verification.html

12. **Additional finds (final round):**
    - ZeBu-200 (Synopsys): «fastest emulation platform, 2X performance, 6X capacity»: https://www.synopsys.com/verification/emulation-prototyping/emulation/zebu-200.html
    - Palladium Z3 + Protium X3 «Dynamic Duo III» (Cadence, 2025): >2X capacity, 1.5X perf: https://community.cadence.com/cadence_blogs_8/b/fv/posts/advancing-digital-verification-with-dynamic-duo-iii-s-accelerated-computing
    - Palladium Z2 4-State Emulation apps (Jan 2024): https://newsroom.cadence.com/press-releases/press-release-details/2024/Cadence-Unveils-New-Palladium-Z2-Apps-with-Industrys-First-4-State-Emulation-and-Mixed-Signal-Modeling-to-Accelerate-SoC-Verification-01-18-2024/default.aspx
    - IEEE 10205723: Xcelium+Palladium Z1 acceleration of ARM Cortex-M-33 testcase: 107.84× (3h10m → 1m46s): https://ieeexplore.ieee.org/document/10205723
    - eUVM / «Embedded UVM» (D language, multicore, uvm.io): https://uvm.io/ — актуальный сайт Tessolve/Puneet Goel eUVM.
    - GravityXR case: MHz-level emulation on Palladium: https://community.cadence.com/cadence_blogs_8/b/fv/posts/smarter-chips-faster-checks-gravityxr-leading-the-xr-verification-shift

### Черновик синтеза для финального отчёта
- Бейслайны, которых потребует ревьюер: (a) коммерческий TBA (Palladium/ZeBu/Veloce, ~0.5–5 МГц, 100×+ только при «быстром» тестбенче);
  (b) открытый софт: Verilator+UVM (Antmicro 2025 → UVM 2020 в 5.052) + riscv-dv SV ~10k instr/s vs eUVM ~0.5–1M instr/s;
  (c) HW-ко-симуляции без UVM: DiffTest-H, FERIVer, Lyra, TurboFuzz.
- Подтверждённый пробел: полный UVM на ARM SoC рядом с DUT в FPGA никто не гоняет; ближайшие — ZynqParrot (C++), FERIVer (QEMU), Hercules (C++ HLS) — все без UVM.
- Тренды 2025–2026: AI/ML-агенты в регрессиях, PSS 3.0 + IP-XACT, multi-die distributed simulation, Python (pyuvm), LLM-генерация UVM.
