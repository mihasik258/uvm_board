# Файлы загрузки VD100 (не входят в репозиторий)

Сборка образа (`platforms/vd100/build.sh`) берёт отсюда заводские файлы платы ALINX VD100 — они чужие и
в репозиторий не кладутся. Скопируйте их с раздела FAT заводской SD-карты платы:

| файл здесь | на заводской карте | зачем |
|---|---|---|
| `BOOT_ref.BIN` | `BOOT.BIN` | прошивка A72 (bl31, u-boot) для сборки своего `BOOT.BIN` |
| `image.ub` | `image.ub` | Linux (PetaLinux 2023.2), без изменений |
| `boot.scr` | `boot.scr` | сценарий загрузки u-boot |

Другое место: `REF_BOOTBIN=<BOOT.BIN>` и `LINUX_DIR=<каталог с image.ub и boot.scr>` (см. `build.sh`).
