`timescale 1ns/1ps

module ahb_slave_halfword (
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire [1:0]  HTRANS,
    input  wire        HWRITE,
    input  wire [2:0]  HSIZE,
    input  wire        HREADY,
    input  wire [31:0] HWDATA,

    output wire        HREADYOUT,
    output reg  [31:0] HRDATA,
    output wire        HRESP
);

    localparam IDLE   = 2'b00;
    localparam NONSEQ = 2'b10;

    reg [31:0] addr_reg;
    reg        wr_en_reg;
    reg        sel_reg;
    reg [2:0]  size_reg;

    // 8 x 32-bit registers (addr[4:2] = index)
    reg [31:0] mem [0:7];
    integer    k;

    // Address phase latch
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_reg  <= 32'h0;
            wr_en_reg <= 1'b0;
            sel_reg   <= 1'b0;
            size_reg  <= 3'b000;
        end else if (HREADY && HSEL ) begin
            addr_reg  <= HADDR;
            wr_en_reg <= HWRITE;
            sel_reg   <= 1'b1;
            size_reg  <= HSIZE;
        end else if (HREADY) begin
            sel_reg   <= 1'b0;
        end
    end

    // Data phase write
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            for (k = 0; k < 8; k = k+1)
                mem[k] <= 32'h0;
        end else if (sel_reg && wr_en_reg) begin
            case (size_reg)
                3'b010: begin // Word (32-bit)
                    mem[addr_reg[4:2]] <= HWDATA;
                end
                3'b001: begin // Halfword (16-bit)
                    if (addr_reg[1]) 
                        mem[addr_reg[4:2]][31:16] <= HWDATA;
                    else             
                        mem[addr_reg[4:2]][15:0]  <= HWDATA;
                end
                3'b000: begin // Byte (8-bit)
                    case (addr_reg[1:0])
                        2'b00: mem[addr_reg[4:2]][7:0]   <= HWDATA[7:0];
                        2'b01: mem[addr_reg[4:2]][15:8]  <= HWDATA[15:8];
                        2'b10: mem[addr_reg[4:2]][23:16] <= HWDATA[23:16];
                        2'b11: mem[addr_reg[4:2]][31:24] <= HWDATA[31:24];
                    endcase
                end
                default: mem[addr_reg[4:2]] <= HWDATA;
            endcase
        end
    end

    // Combinational read
    // 在 AHB 中，Slave 只需要送出整筆 32-bit 資料，Master 會根據 HADDR 與 HSIZE 自己擷取需要的 Byte/Halfword
    always @(*) begin
        if (sel_reg && !wr_en_reg)
            HRDATA = mem[addr_reg[4:2]];
        else
            HRDATA = 32'h0;
    end

    assign HRESP = 1'b0;
    assign HREADYOUT = 1'b1;

endmodule
