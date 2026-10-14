/* ocv_regs.h - OCV (On-Chip Verification) register maps, software side.
 *
 * Mirror of hw/rtl/ocv_pkg.sv: every constant there has an OCV_-prefixed counterpart here
 * (bit indices become masks, ID/VERSION values get a _VALUE suffix); hw/scripts/check_regs.py
 * enforces it. All registers are 32-bit.
 *
 * One DUT environment = one hub. Its address space is N+1 slots of 2^slot_log2 bytes:
 *   slot 0      hub: directory + DUT control           (OCV_HUB_REG_*)
 *   slot k>=1   endpoint k-1 (sink or source)          (OCV_EP_REG_*)
 * Inside an endpoint slot, the lower half of its window holds CSRs and the upper half the
 * record buffer. Record i, word j (j = 0 holds bits [31:0]):
 *     slot_base + OCV_GEOM_BUF_OFFSET(g) + (((i) << OCV_GEOM_LOG2_STRIDE(g)) + (j)) * 4
 */
#ifndef OCV_REGS_H
#define OCV_REGS_H

/* ---------------- hub (slot 0) ---------------- */
#define OCV_HUB_ID_VALUE        0x4F434801u   /* "OC" "H" + format 0x01 */
#define OCV_HUB_VERSION_VALUE   0x00010000u

#define OCV_HUB_REG_ID          0x00u  /* RO */
#define OCV_HUB_REG_VERSION     0x04u  /* RO */
#define OCV_HUB_REG_LAYOUT      0x08u  /* RO  OCV_LAYOUT_* */
#define OCV_HUB_REG_DUT_ID      0x0Cu  /* RO  descriptor hash */
#define OCV_HUB_REG_DUT_CTRL    0x10u  /* RW  OCV_DUT_CTRL_* */
#define OCV_HUB_REG_CYCLES_LO   0x14u  /* RO  reading LO snapshots the 64-bit counter */
#define OCV_HUB_REG_CYCLES_HI   0x18u  /* RO */

#define OCV_DUT_CTRL_RESET      (1u << 0)     /* hold the DUT in reset */

#define OCV_LAYOUT_ENDPOINTS(l) (((l) >> 0) & 0xFFu)
#define OCV_LAYOUT_SLOT_LOG2(l) (((l) >> 8) & 0xFFu)

/* ---------------- endpoints (slots 1..N) ---------------- */
#define OCV_EP_ID_VALUE         0x4F435601u   /* "OC" "V" + format 0x01 */
#define OCV_EP_VERSION_VALUE    0x00020000u

#define OCV_EP_REG_ID           0x00u  /* RO */
#define OCV_EP_REG_VERSION      0x04u  /* RO */
#define OCV_EP_REG_GEOMETRY     0x08u  /* RO  OCV_GEOM_* */
#define OCV_EP_REG_KIND         0x0Cu  /* RO  OCV_KIND_* */
#define OCV_EP_REG_CTRL         0x10u  /* RW  OCV_CTRL_* */
#define OCV_EP_REG_STATUS       0x14u  /* RO  OCV_SINK_ST_* / OCV_SRC_ST_* */
#define OCV_EP_REG_COUNT        0x18u  /* RO  sink: captured, source: sent */
#define OCV_EP_REG_DROPPED      0x1Cu  /* RO  sink: lost while full (saturating) */
#define OCV_EP_REG_LENGTH       0x20u  /* RW  source: records to send */
#define OCV_EP_REG_THROTTLE     0x24u  /* RW  [7:0] pause probability n/256 per cycle (0 = off) */
#define OCV_EP_REG_SQUASH       0x28u  /* RW  sink with OCV_KIND_SQUASH: records per fused record */
#define OCV_EP_REG_TAKEN        0x2Cu  /* RO  sink with OCV_KIND_SQUASH: DUT records taken since its reset */
#define OCV_EP_REG_SQMASK_SEL   0x30u  /* RW  sink with OCV_KIND_SQMASK: word index of SQMASK */
#define OCV_EP_REG_SQMASK       0x34u  /* RW  sink with OCV_KIND_SQMASK: that word of the compared-bits mask */
#define OCV_EP_REG_BRK_SEL      0x38u  /* RW  sink with OCV_KIND_SQBRK: [7:0] word [10:8] pattern [11] value [23:16] enables */
#define OCV_EP_REG_BRK_DATA     0x3Cu  /* RW  sink with OCV_KIND_SQBRK: that word; a match closes the window */
/* sink with OCV_KIND_DMA: records go over the wrapper's AXI4 master to a ring in PS memory */
#define OCV_EP_REG_RING_LO      0x40u  /* RW  ring base [31:0] (aligned to the ring's size) */
#define OCV_EP_REG_RING_HI      0x44u  /* RW  ring base [63:32] */
#define OCV_EP_REG_RING_LOG2    0x48u  /* RW  [4:0] log2 ring records (0 = off); RO [15:8] log2 slot
                                          bytes, [23:16] log2 data bytes of the master */
#define OCV_EP_REG_RING_HEAD    0x4Cu  /* RO  records written into the ring (free-running) */
#define OCV_EP_REG_RING_TAIL    0x50u  /* RW  records consumed by the PS (free-running) */
#define OCV_EP_REG_DMA_STAT     0x54u  /* RO  OCV_DMA_ST_* */

#define OCV_EP_KIND_SINK        1u
#define OCV_EP_KIND_SOURCE      2u
#define OCV_KIND_OF(k)          ((k) & 0xFFu)
#define OCV_KIND_BACKPRESSURE   (1u << 8)     /* sink consumes a valid/ready stream */
#define OCV_KIND_LOSSLESS       (1u << 9)     /* sink freezes the DUT while full: drain, never lost */
#define OCV_KIND_STREAM         (1u << 10)    /* source: ring buffer, LENGTH is a running total */
#define OCV_KIND_FREEZE_STARVED (1u << 11)    /* source: DUT clock stops while it waits for a record */
#define OCV_KIND_SQUASH         (1u << 12)    /* sink: fuses windows of records (last record, count,
                                                 CRC32C and CRC32 of the compared words) */

#define OCV_KIND_SQMASK         (1u << 13)    /* squash sink: compared-bits mask set at run time */
#define OCV_KIND_SQBRK          (1u << 14)    /* squash sink: break patterns close a window on a match */
#define OCV_KIND_DMA            (1u << 15)    /* sink: records to a ring in PS memory (OCV_EP_REG_RING_*) */
#define OCV_DMA_ST_ERROR        (1u << 0)     /* a write got an error response (sticky until clear) */
#define OCV_DMA_ST_BUSY         (1u << 1)     /* a burst in flight */
#define OCV_RING_SLOT_LOG2(v)   (((v) >> 8) & 0xFFu)
#define OCV_RING_DATA_LOG2(v)   (((v) >> 16) & 0xFFu)
#define OCV_CTRL_ENABLE         (1u << 0)
#define OCV_CTRL_CLEAR          (1u << 1)     /* write 1: restart capture / rewind; reads 0 */
#define OCV_CTRL_STALL_EN       (1u << 2)     /* sink only */
#define OCV_CTRL_FLUSH          (1u << 3)     /* sink with OCV_KIND_SQUASH: write 1 to emit the open window */

#define OCV_SINK_ST_FULL        (1u << 0)
#define OCV_SINK_ST_OVERFLOW    (1u << 1)     /* sticky until clear */
#define OCV_SINK_ST_ENABLE      (1u << 2)
#define OCV_SINK_ST_STALL       (1u << 3)
#define OCV_SRC_ST_DONE         (1u << 0)     /* sent == length */
#define OCV_SRC_ST_ENABLE       (1u << 2)
#define OCV_SRC_ST_ACTIVE       (1u << 4)

#define OCV_GEOM_REC_WORDS(g)    (((g) >>  0) & 0xFFu)          /* 32-bit words per record */
#define OCV_GEOM_LOG2_DEPTH(g)   (((g) >>  8) & 0xFFu)          /* buffer = 2^n records */
#define OCV_GEOM_LOG2_STRIDE(g)  (((g) >> 16) & 0xFFu)          /* words per record slot = 2^n */
#define OCV_GEOM_BUF_OFFSET(g)   (1ul << (((g) >> 24) & 0xFFu)) /* byte offset of the buffer */

#endif /* OCV_REGS_H */
