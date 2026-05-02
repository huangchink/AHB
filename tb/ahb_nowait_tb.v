// =============================================================================
// Testbench : ahb_wave_tb
// DUT       : ahb_slave (8 x 32-bit registers, addr[4:2] index)
// Strategy  : Every cycle pipeline — address phase of transfer N+1 overlaps
//             data phase of transfer N with zero idle between bursts.
//
// Pipeline timing diagram (write burst):
//   CLK  : __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
//   Phase :   A0  D0  D1  D2  ...
//             A0  A1  A2  ...
//   HADDR:   @0  @4  @8  ...
//   HWDATA:      D0  D1  D2  ...
// =============================================================================
`timescale 1ns/1ps

module ahb_wave_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam CLK_PERIOD = 10;
    localparam IDLE   = 2'b00;
    localparam NONSEQ = 2'b10;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         HCLK;
    reg         HRESETn;
    reg         HSEL;
    reg  [31:0] HADDR;
    reg  [1:0]  HTRANS;
    reg         HWRITE;
    reg         HREADY;
    reg  [31:0] HWDATA;

    wire        HREADYOUT;
    wire [31:0] HRDATA;
    wire        HRESP;

    // -------------------------------------------------------------------------
    // DUT instance
    // -------------------------------------------------------------------------
    ahb_slave u_dut (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .HSEL      (HSEL),
        .HADDR     (HADDR),
        .HTRANS    (HTRANS),
        .HWRITE    (HWRITE),
        .HREADY    (HREADY),
        .HWDATA    (HWDATA),
        .HREADYOUT (HREADYOUT),
        .HRDATA    (HRDATA),
        .HRESP     (HRESP)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial HCLK = 0;
    always #(CLK_PERIOD/2) HCLK = ~HCLK;

    // -------------------------------------------------------------------------
    // Counters & shared arrays
    // -------------------------------------------------------------------------
    integer    pass_cnt = 0;
    integer    fail_cnt = 0;
    integer    i;
    reg [31:0] wr_data [0:7];   // write payload for pipeline tasks
    reg [31:0] rd_data [0:7];   // captured read results

    // -------------------------------------------------------------------------
    // Task: bus idle default state
    // -------------------------------------------------------------------------
    task bus_idle;
    begin
        HSEL   = 1'b0;
        HTRANS = IDLE;
        HWRITE = 1'b0;
        HREADY = 1'b1;
        HWDATA = 32'h0;
    end
    endtask

    // -------------------------------------------------------------------------
    // Task: apply_reset
    // -------------------------------------------------------------------------
    task apply_reset;
    begin
        HRESETn = 1'b0;
        bus_idle;
        HADDR   = 32'h0;
        repeat(3) @(posedge HCLK);
        #1; HRESETn = 1'b1;
        @(posedge HCLK); #1;
    end
    endtask

    // -------------------------------------------------------------------------
    // Task: idle_cycles — drive N idle bus cycles
    // -------------------------------------------------------------------------
    task idle_cycles;
        input integer n;
        integer j;
    begin
        for (j = 0; j < n; j = j+1) begin
            @(posedge HCLK); #1;
            bus_idle;
        end
    end
    endtask

    // -------------------------------------------------------------------------
    // Task: check_equal
    // -------------------------------------------------------------------------
    task check_equal;
        input [191:0] name;
        input [31:0]  expected;
        input [31:0]  actual;
    begin
        if (expected === actual) begin
            $display("[PASS] %s | exp=0x%08h  got=0x%08h", name, expected, actual);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] %s | exp=0x%08h  got=0x%08h", name, expected, actual);
            fail_cnt = fail_cnt + 1;
        end
    end
    endtask

    // =========================================================================
    // Task: pipeline_burst_write
    //   Sends 'count' AHB NONSEQ writes back-to-back (every cycle pipeline).
    //   Data sourced from wr_data[0..count-1].
    //   Address range: base_addr, base_addr+4, ..., base_addr+4*(count-1)
    //
    //   Cycle sequence (count=3 example):
    //     CYC 1: [ADDR PHASE 0] HADDR=base, HTRANS=NONSEQ, HWRITE=1
    //     CYC 2: [DATA PHASE 0 + ADDR PHASE 1] HWDATA=wr[0], HADDR=base+4
    //     CYC 3: [DATA PHASE 1 + ADDR PHASE 2] HWDATA=wr[1], HADDR=base+8
    //     CYC 4: [DATA PHASE 2]                HWDATA=wr[2], HTRANS=IDLE
    //     CYC 5: idle (last write settles)
    // =========================================================================
    task pipeline_burst_write;
        input [31:0] base_addr;
        input integer count;
        integer j;
    begin
        // --- Cycle 1: first address phase ---
        @(posedge HCLK); #1;
        HSEL   = 1'b1;
        HADDR  = base_addr;
        HTRANS = NONSEQ;
        HWRITE = 1'b1;
        HREADY = 1'b1;

        // --- Middle cycles: data phase[j-1] overlaps address phase[j] ---
        for (j = 1; j < count; j = j+1) begin
            @(posedge HCLK); #1;
            HWDATA = wr_data[j-1];          // data for transfer j-1
            HADDR  = base_addr + (j << 2);  // address for transfer j
            HTRANS = NONSEQ;
            HSEL   = 1'b1;
            HWRITE = 1'b1;
        end

        // --- Last data phase ---
        @(posedge HCLK); #1;
        HWDATA = wr_data[count-1];
        HTRANS = IDLE;
        HSEL   = 1'b0;
        HWRITE = 1'b0;

        // --- One idle so last write settles ---
        @(posedge HCLK); #1;
        bus_idle;
    end
    endtask

    // =========================================================================
    // Task: pipeline_burst_read
    //   Sends 'count' AHB NONSEQ reads back-to-back (every cycle pipeline).
    //   Captured data stored in rd_data[0..count-1].
    //
    //   Timing note: HRDATA is combinatorial from addr_reg latched at prev posedge.
    //   So rd_data[j] is sampled #1 after the posedge where addr[j] was latched.
    //
    //   Cycle sequence (count=3 example):
    //     CYC 1: [ADDR PHASE 0] HADDR=base, HTRANS=NONSEQ, HWRITE=0
    //     CYC 2: [DATA PHASE 0 + ADDR PHASE 1] sample HRDATA→rd[0], HADDR=base+4
    //     CYC 3: [DATA PHASE 1 + ADDR PHASE 2] sample HRDATA→rd[1], HADDR=base+8
    //     CYC 4: [DATA PHASE 2]                sample HRDATA→rd[2], HTRANS=IDLE
    //     CYC 5: idle
    // =========================================================================
    task pipeline_burst_read;
        input [31:0] base_addr;
        input integer count;
        integer j;
    begin
        // --- Cycle 1: first address phase ---
        @(posedge HCLK); #1;
        HSEL   = 1'b1;
        HADDR  = base_addr;
        HTRANS = NONSEQ;
        HWRITE = 1'b0;
        HREADY = 1'b1;

        // --- Middle cycles: sample HRDATA for [j-1], drive address for [j] ---
        for (j = 1; j < count; j = j+1) begin
            @(posedge HCLK); #1;
            rd_data[j-1] = HRDATA;          // sample read data for transfer j-1
            HADDR  = base_addr + (j << 2);  // address phase for transfer j
            HTRANS = NONSEQ;
            HSEL   = 1'b1;
            HWRITE = 1'b0;
        end

        // --- Last data phase: sample final read ---
        @(posedge HCLK); #1;
        rd_data[count-1] = HRDATA;
        HTRANS = IDLE;
        HSEL   = 1'b0;

        @(posedge HCLK); #1;
        bus_idle;
    end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $fsdbDumpfile("ahb_test.fsdb");
        $fsdbDumpvars(0, ahb_wave_tb);
        $fsdbDumpMDA;

        $display("=============================================================");
        $display("  AHB Slave TB  [8-reg, Every-Cycle Pipeline]");
        $display("=============================================================");

        // =====================================================================
        // TC1: Pipeline write all 8 regs, then pipeline read back
        // =====================================================================
        $display("\n--- TC1: Pipeline Write x8 -> Pipeline Read x8 ---");
        apply_reset;
        wr_data[0] = 32'hDEAD_BEEF;
        wr_data[1] = 32'hCAFE_1234;
        wr_data[2] = 32'hAAAA_5555;
        wr_data[3] = 32'h1234_5678;
        wr_data[4] = 32'h9ABC_DEF0;
        wr_data[5] = 32'h0F0F_0F0F;
        wr_data[6] = 32'hF0F0_F0F0;
        wr_data[7] = 32'h1111_2222;
        pipeline_burst_write(32'h0000_0000, 8);
        idle_cycles(1);
        pipeline_burst_read(32'h0000_0000, 8);
        for (i = 0; i < 8; i = i+1) begin
            if (rd_data[i] === wr_data[i]) begin
                $display("[PASS] TC1: reg%0d | exp=0x%08h  got=0x%08h", i, wr_data[i], rd_data[i]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] TC1: reg%0d | exp=0x%08h  got=0x%08h", i, wr_data[i], rd_data[i]);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =====================================================================
        // TC2: Reset clears all registers → pipeline read must return all 0
        // =====================================================================
        $display("\n--- TC2: Reset clears all 8 registers ---");
        apply_reset;
        pipeline_burst_read(32'h0000_0000, 8);
        for (i = 0; i < 8; i = i+1) begin
            if (rd_data[i] === 32'h0) begin
                $display("[PASS] TC2: reg%0d after reset = 0x00000000", i);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] TC2: reg%0d after reset | exp=0x00000000  got=0x%08h", i, rd_data[i]);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =====================================================================
        // TC3: Write all 8, then overwrite reg2~reg5 only; verify reg0,1,6,7 unchanged
        // =====================================================================
        $display("\n--- TC3: Partial pipeline overwrite (reg2~reg5 only) ---");
        apply_reset;
        wr_data[0] = 32'hABCD_EF01; wr_data[1] = 32'h1234_5678;
        wr_data[2] = 32'hDEAD_0000; wr_data[3] = 32'h0000_BEEF;
        wr_data[4] = 32'hCAFE_BABE; wr_data[5] = 32'h8765_4321;
        wr_data[6] = 32'hFEED_FACE; wr_data[7] = 32'hBA5E_BA11;
        pipeline_burst_write(32'h0000_0000, 8);
        idle_cycles(1);
        // Overwrite reg2(0x08)..reg5(0x14) only
        wr_data[0] = 32'h1111_1111; wr_data[1] = 32'h2222_2222;
        wr_data[2] = 32'h3333_3333; wr_data[3] = 32'h4444_4444;
        pipeline_burst_write(32'h0000_0008, 4);
        idle_cycles(1);
        pipeline_burst_read(32'h0000_0000, 8);
        check_equal("TC3: reg0 unchanged", 32'hABCD_EF01, rd_data[0]);
        check_equal("TC3: reg1 unchanged", 32'h1234_5678, rd_data[1]);
        check_equal("TC3: reg2 updated  ", 32'h1111_1111, rd_data[2]);
        check_equal("TC3: reg3 updated  ", 32'h2222_2222, rd_data[3]);
        check_equal("TC3: reg4 updated  ", 32'h3333_3333, rd_data[4]);
        check_equal("TC3: reg5 updated  ", 32'h4444_4444, rd_data[5]);
        check_equal("TC3: reg6 unchanged", 32'hFEED_FACE, rd_data[6]);
        check_equal("TC3: reg7 unchanged", 32'hBA5E_BA11, rd_data[7]);

        // =====================================================================
        // TC4: HTRANS=IDLE with HSEL=1 must NOT modify register
        // =====================================================================
        $display("\n--- TC4: HTRANS=IDLE no-op ---");
        apply_reset;
        wr_data[0] = 32'h1234_5678;
        pipeline_burst_write(32'h0, 1);
        idle_cycles(1);
        @(posedge HCLK); #1;                          // IDLE "write" — should be no-op
        HSEL = 1'b1; HADDR = 32'h0; HTRANS = IDLE;
        HWRITE = 1'b1; HWDATA = 32'hDEAD_DEAD; HREADY = 1'b1;
        @(posedge HCLK); #1; bus_idle;
        idle_cycles(1);
        pipeline_burst_read(32'h0, 1);
        check_equal("TC4: IDLE no-op reg0", 32'h1234_5678, rd_data[0]);

        // =====================================================================
        // TC5: HSEL=0 with HTRANS=NONSEQ must NOT modify register
        // =====================================================================
        $display("\n--- TC5: HSEL=0 no-op ---");
        apply_reset;
        wr_data[0] = 32'hABCD_EF01;
        pipeline_burst_write(32'h0, 1);
        idle_cycles(1);
        @(posedge HCLK); #1;                          // NONSEQ but HSEL=0 — no-op
        HSEL = 1'b0; HADDR = 32'h0; HTRANS = NONSEQ;
        HWRITE = 1'b1; HWDATA = 32'hDEAD_DEAD; HREADY = 1'b1;
        @(posedge HCLK); #1; bus_idle;
        idle_cycles(1);
        pipeline_burst_read(32'h0, 1);
        check_equal("TC5: HSEL=0 no-op reg0", 32'hABCD_EF01, rd_data[0]);

        // =====================================================================
        // TC6: HRESP must always be OKAY (0)
        // =====================================================================
        $display("\n--- TC6: HRESP=OKAY ---");
        apply_reset;
        idle_cycles(2);
        check_equal("TC6: HRESP=OKAY", 32'h0, {31'h0, HRESP});

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=============================================================");
        $display("  Test Summary: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  >>> ALL TESTS PASSED <<<");
        else
            $display("  >>> %0d TEST(S) FAILED <<<", fail_cnt);
        $display("=============================================================");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #200000;
        $display("[ERROR] Simulation TIMEOUT");
        $finish;
    end

endmodule
