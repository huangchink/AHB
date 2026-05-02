`timescale 1ns/1ps

module ahb_slave (
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire [1:0]  HTRANS,
    input  wire        HWRITE,
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

    // 8 x 32-bit registers (addr[4:2] = index)
    reg [31:0] mem [0:7];
    integer    k;

    // Address phase latch
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_reg  <= 32'h0;
            wr_en_reg <= 1'b0;
            sel_reg   <= 1'b0;
        end else if (HREADY && HSEL && (HTRANS == NONSEQ)) begin
            addr_reg  <= HADDR;
            wr_en_reg <= HWRITE;
            sel_reg   <= 1'b1;
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
            mem[addr_reg[4:2]] <= HWDATA;
        end
    end

    // Combinatorial read
    always @(*) begin
        if (sel_reg && !wr_en_reg)
            HRDATA = mem[addr_reg[4:2]];
        else
            HRDATA = 32'h0;
    end

    assign HRESP = 1'b0;

    assign HREADYOUT = 1'b1;

endmodule