/* config.h for building Spike's disassembler alone (OCV: the CVA6 testbench's dpi_dasm) */
#define DEFAULT_ISA "RV64IMAFDC_zicntr_zihpm"
#define DEFAULT_PRIV "MSU"
#define DEFAULT_VARCH "vlen:128,elen:64"
#define DISASM_ENABLED 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1
#define TARGET_ARCH "riscv64-unknown-elf"
