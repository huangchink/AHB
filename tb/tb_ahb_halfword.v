`timescale 1ns/1ps

module tb_ahb_halfword;

    // Signals
    reg         HCLK;
    reg         HRESETn;
    reg         HSEL;
    reg  [31:0] HADDR;
    reg  [1:0]  HTRANS;
    reg         HWRITE;
    reg  [2:0]  HSIZE;
    reg         HREADY;
    reg  [31:0] HWDATA;

    wire        HREADYOUT;
    wire [31:0] HRDATA;
    wire        HRESP;

    // Instantiate slave
    ahb_slave_halfword u_slave (
        .HCLK(HCLK),
        .HRESETn(HRESETn),
        .HSEL(HSEL),
        .HADDR(HADDR),
        .HTRANS(HTRANS),
        .HWRITE(HWRITE),
        .HSIZE(HSIZE),
        .HREADY(HREADY),
        .HWDATA(HWDATA),
        .HREADYOUT(HREADYOUT),
        .HRDATA(HRDATA),
        .HRESP(HRESP)
    );

    // Clock gen
    initial begin
        HCLK = 0;
        forever #5 HCLK = ~HCLK;
    end

    // AHB Master Task for single write
    task ahb_write(input [31:0] addr, input [2:0] size, input [31:0] data);
        begin
            // Address phase
            @(posedge HCLK);
            #1;
            HSEL   = 1'b1;
            HTRANS = 2'b10; // NONSEQ
            HWRITE = 1'b1;
            HADDR  = addr;
            HSIZE  = size;
            HREADY = 1'b1;
            
            // Wait for HREADYOUT
            @(posedge HCLK);
            while (!HREADYOUT) @(posedge HCLK);
            
            // Data phase
            #1;
            HTRANS = 2'b00; // IDLE
            HSEL   = 1'b0;
            HWDATA = data;
        end
    endtask

    // AHB Master Task for single read
    task ahb_read(input [31:0] addr, input [2:0] size);
        begin
            // Address phase
            @(posedge HCLK);
            #1;
            HSEL   = 1'b1;
            HTRANS = 2'b10; // NONSEQ
            HWRITE = 1'b0;
            HADDR  = addr;
            HSIZE  = size;
            HREADY = 1'b1;
            
            // Wait for HREADYOUT
            @(posedge HCLK);
            while (!HREADYOUT) @(posedge HCLK);
            
            // Data phase
            #1;
            HTRANS = 2'b00; // IDLE
            HSEL   = 1'b0;
            
            // Sample read data on the next posedge
            @(posedge HCLK);
        end
    endtask

    integer i;
    reg [31:0] test_addr;
    reg [15:0] test_data_hw;
    reg [15:0] read_data_hw;

    initial begin
        // Init
        HRESETn = 0;
        HSEL    = 0;
        HADDR   = 0;
        HTRANS  = 0;
        HWRITE  = 0;
        HSIZE   = 0;
        HREADY  = 1;
        HWDATA  = 0;

        #15 HRESETn = 1;
        
        $display("\n--- Start AHB Halfword Test (Addr 4 to 12) ---");
        
        // 1. Pipelined Write Halfwords 從位址 4 到 12
        @(posedge HCLK);
        #1;
        // 第一個 Address Phase (i = 4)
        HSEL   = 1'b1;
        HTRANS = 2'b10; // NONSEQ
        HWRITE = 1'b1;
        HSIZE  = 3'b001;
        HADDR  = 32'h04;
        
        for (i = 6; i <= 14; i = i + 2) begin
            @(posedge HCLK);
            #1;
            // 給上一個 Address (i-2) 餵 Data Phase
            test_addr = i - 2;
            test_data_hw = test_addr * 16'h1111;
            HWDATA = test_data_hw;

                
            // 同時給出這一個 Address Phase (如果是最後一圈就給 IDLE)
            if (i <= 12) begin
                HADDR = i;
                HTRANS = 2'b11; // SEQ (後續傳輸皆為 SEQ)
            end else begin
                HTRANS = 2'b00; // IDLE
                HSEL   = 1'b0;
            end
        end
        
        @(posedge HCLK); // Wait one cycle before read
        
        // 2. Pipelined Read Halfwords 從位址 4 到 12
        #1;
        // 第一個 Address Phase (i = 4)
        HSEL   = 1'b1;
        HTRANS = 2'b10; // NONSEQ
        HWRITE = 1'b0;
        HSIZE  = 3'b001;
        HADDR  = 32'h04;
        
        // CYC 2: 給第二個 Address Phase (i = 6)
        @(posedge HCLK);
        #1;
        HADDR  = 32'h06;
        HTRANS = 2'b11; // SEQ (從這筆開始皆為 SEQ)
        
        // CYC 3 開始: 擷取上一個 Data Phase 並給出下一個 Address Phase
        for (i = 8; i <= 16; i = i + 2) begin
            @(posedge HCLK); // 在 posedge 擷取 Data Phase 資料
            
            // 擷取前兩次 Address Phase 要求的資料 (i-4)
            test_addr = i - 4;
            test_data_hw = test_addr * 16'h1111;
            
            if (test_addr[1])
                read_data_hw = HRDATA[31:16];
            else
                read_data_hw = HRDATA[15:0];
                
            if (read_data_hw == test_data_hw) begin
                $display("PASS: Addr %0d (0x%0h) read %h", test_addr, test_addr, read_data_hw);
            end else begin
                $display("FAIL: Addr %0d (0x%0h) expected %h, got %h", test_addr, test_addr, test_data_hw, read_data_hw);
            end
            
            #1;
            // 同時給出下一個 Address Phase (如果是最後一圈就給 IDLE)
            if (i <= 12) begin
                HADDR = i;
                HTRANS = 2'b11; // SEQ
            end else begin
                HTRANS = 2'b00; // IDLE
                HSEL   = 1'b0;
            end
        end

        $display("----------------------------------------------\n");
        $finish;
    end

    // Dump waveform
    initial begin
        $fsdbDumpfile("ahb_halfword.fsdb");
        $fsdbDumpvars(0, tb_ahb_halfword);
        $fsdbDumpMDA;
    end

endmodule
