/// OCV (On-Chip Verification) - shared constants: identities and CSR maps.
///
/// The CSR maps are the hardware half of the PS contract; the software half is
/// sw/include/ocv_regs.h (checked by hw/scripts/check_regs.py). Keep the two in sync.
// Each client module uses only part of this package.
/* verilator lint_off UNUSEDPARAM */
package ocv_pkg;

    //------------------------------------------------------------------
    // Hub: slot 0 of the OCV address space - directory and DUT control.
    //------------------------------------------------------------------
    localparam logic [31:0] HUB_ID        = 32'h4F43_4801;  // "OC" "H" + format 0x01
    localparam logic [31:0] HUB_VERSION   = 32'h0001_0000;

    localparam logic [7:0] HUB_REG_ID        = 8'h00;  // RO  HUB_ID
    localparam logic [7:0] HUB_REG_VERSION   = 8'h04;  // RO  HUB_VERSION
    localparam logic [7:0] HUB_REG_LAYOUT    = 8'h08;  // RO  [7:0] endpoints  [15:8] log2 slot bytes
    localparam logic [7:0] HUB_REG_DUT_ID    = 8'h0C;  // RO  descriptor hash, matched by software
    localparam logic [7:0] HUB_REG_DUT_CTRL  = 8'h10;  // RW  [0] hold DUT in reset
    localparam logic [7:0] HUB_REG_CYCLES_LO = 8'h14;  // RO  cycles out of reset; reading LO snapshots HI
    localparam logic [7:0] HUB_REG_CYCLES_HI = 8'h18;  // RO

    localparam int unsigned DUT_CTRL_RESET = 0;

    //------------------------------------------------------------------
    // Endpoints (sink / source): one slot each. Lower half of a slot = CSRs,
    // upper half = record buffer window.
    //------------------------------------------------------------------
    localparam logic [31:0] EP_ID      = 32'h4F43_5601;   // "OC" "V" + format 0x01
    localparam logic [31:0] EP_VERSION = 32'h0002_0000;   // 2.0: endpoint kinds

    localparam logic [7:0] EP_REG_ID       = 8'h00;  // RO  EP_ID
    localparam logic [7:0] EP_REG_VERSION  = 8'h04;  // RO  EP_VERSION
    localparam logic [7:0] EP_REG_GEOMETRY = 8'h08;  // RO  [7:0] rec_words  [15:8] log2_depth
                                                     //     [23:16] log2_stride (words per slot)
                                                     //     [31:24] log2 of the buffer window offset
    localparam logic [7:0] EP_REG_KIND     = 8'h0C;  // RO  [7:0] kind, flags KIND_* above bit 7
    localparam logic [7:0] EP_REG_CTRL     = 8'h10;  // RW  [0] enable  [1] clear (write 1)  [2] stall_en
    localparam logic [7:0] EP_REG_STATUS   = 8'h14;  // RO  sink:   [0] full [1] overflow [2] enable [3] stall
                                                     //     source: [0] done [2] enable [4] active
    localparam logic [7:0] EP_REG_COUNT    = 8'h18;  // RO  sink: records captured; source: records sent
    localparam logic [7:0] EP_REG_DROPPED  = 8'h1C;  // RO  sink: records lost while full (saturating)
    localparam logic [7:0] EP_REG_LENGTH   = 8'h20;  // RW  source: records to send
    localparam logic [7:0] EP_REG_THROTTLE = 8'h24;  // RW  [7:0] pause probability, n/256 per cycle:
                                                     //     source withholds a new record, sink with
                                                     //     backpressure withholds ready. 0 = off.
    localparam logic [7:0] EP_REG_SQUASH   = 8'h28;  // RW  sink with KIND_SQUASH: records per fused
                                                     //     record (window); 0 or 1 = every record
    localparam logic [7:0] EP_REG_TAKEN    = 8'h2C;  // RO  sink with KIND_SQUASH: DUT records taken since
                                                     //     the DUT's reset (wraps): progress while the
                                                     //     fused output grows only once per window
    localparam logic [7:0] EP_REG_SQMASK_SEL = 8'h30; // RW sink with KIND_SQMASK: word index of SQMASK
    localparam logic [7:0] EP_REG_SQMASK   = 8'h34;  // RW  sink with KIND_SQMASK: word SQMASK_SEL of the
                                                     //     compared-bits mask the signatures cover (reset:
                                                     //     the build's MASK); set before the DUT runs
    localparam logic [7:0] EP_REG_BRK_SEL  = 8'h38;  // RW  sink with KIND_SQBRK: [7:0] word, [10:8] pattern,
                                                     //     [11] 0 mask / 1 value, [23:16] patterns enabled
    localparam logic [7:0] EP_REG_BRK_DATA = 8'h3C;  // RW  sink with KIND_SQBRK: that word. A record with
                                                     //     (rec & mask) == value for an enabled pattern closes
                                                     //     its window (it becomes the window's last record)
    // Sink with KIND_DMA: the records leave the endpoint's buffer (then a FIFO) through the wrapper's
    // AXI4 master into a ring in the PS memory - no bus reads per record. RING_LOG2 = 0: off (the
    // buffer is read over the bus, as without DMA). Ring: 2**RING_LOG2 record slots of SLOT bytes
    // (OCV_DMA_SLOT_BYTES in software: words per record slot * 4, at least the master's data width),
    // base aligned to the ring's size; record k (counted from the DUT's reset) at
    // base + (k mod 2**RING_LOG2) * SLOT. Counters are free-running (32 bits, wrap).
    localparam logic [7:0] EP_REG_RING_LO   = 8'h40;  // RW  ring base, bits [31:0]
    localparam logic [7:0] EP_REG_RING_HI   = 8'h44;  // RW  ring base, bits [63:32]
    localparam logic [7:0] EP_REG_RING_LOG2 = 8'h48;  // RW  [4:0] log2 ring records (0 = DMA off);
                                                      //     RO [15:8] log2 slot bytes, [23:16] log2
                                                      //     data bytes of the master
    localparam logic [7:0] EP_REG_RING_HEAD = 8'h4C;  // RO  records in the ring (write responses seen)
    localparam logic [7:0] EP_REG_RING_TAIL = 8'h50;  // RW  records the PS has consumed
    localparam logic [7:0] EP_REG_DMA_STAT  = 8'h54;  // RO  [0] write error (sticky until clear),
                                                      //     [1] busy (a burst in flight)

    localparam logic [7:0] EP_KIND_SINK   = 8'd1;
    localparam logic [7:0] EP_KIND_SOURCE = 8'd2;

    // EP_REG_KIND flags (bit positions)
    localparam int unsigned KIND_BACKPRESSURE   = 8;   // sink consumes a valid/ready stream
    localparam int unsigned KIND_LOSSLESS       = 9;   // sink freezes the DUT while full
    localparam int unsigned KIND_STREAM         = 10;  // source buffer is a ring fed during the run
    localparam int unsigned KIND_FREEZE_STARVED = 11;  // source freezes the DUT while it waits for data
    localparam int unsigned KIND_SQUASH         = 12;  // sink fuses windows of records: last record,
                                                       // count, two CRC32 signatures (ocv_sink)
    localparam int unsigned KIND_SQMASK         = 13;  // squash sink: compared-bits mask set at run time
    localparam int unsigned KIND_SQBRK          = 14;  // squash sink: break patterns (EP_REG_BRK_*)
    localparam int unsigned KIND_DMA            = 15;  // sink: records go to a ring in PS memory
                                                       // over the AXI4 master (EP_REG_RING_*)
    localparam int unsigned DMA_ST_ERROR        = 0;
    localparam int unsigned DMA_ST_BUSY         = 1;

    localparam int unsigned CTRL_ENABLE   = 0;
    localparam int unsigned CTRL_CLEAR    = 1;
    localparam int unsigned CTRL_STALL_EN = 2;
    localparam int unsigned CTRL_FLUSH    = 3;   // sink with KIND_SQUASH: write 1 to emit the open window

endpackage : ocv_pkg
/* verilator lint_on UNUSEDPARAM */
