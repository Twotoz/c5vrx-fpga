// Bench capture of simultaneous A, B and C samples at the combiner inputs.
// Each frame starts with A5 5A 49 53, four little-endian field status bytes,
// four little-endian combiner status bytes and three bytes per IQ sample.
`default_nettype none
module iq_trace #(
    parameter CLK_HZ = 40000000, BAUD = 1000000, ADDR_BITS = 12, PERIOD_BITS = 25
) (
    input wire clk, rst,
    input wire [23:0] samples,
    input wire [31:0] field_status,
    input wire [31:0] fusion_status,
    input wire trigger,
    output wire tx
);
    localparam DIV = CLK_HZ / BAUD;
    localparam DIV_BITS = DIV > 1 ? $clog2(DIV) : 1;
    reg [23:0] capture [0:(1 << ADDR_BITS)-1];
    reg [ADDR_BITS-1:0] wr_addr, rd_addr;
    reg [23:0] read_word;
    reg [PERIOD_BITS-1:0] period;
    reg capturing, sending;
    reg [3:0] header;
    reg [31:0] captured_status, captured_fusion;
    reg [1:0] lane;
    reg [9:0] shift;
    reg [3:0] bits_left;
    reg [DIV_BITS-1:0] baud_count;
    reg [7:0] next_byte;
    assign tx = shift[0];

    always @* begin
        case (header)
            0: next_byte = 8'ha5;
            1: next_byte = 8'h5a;
            2: next_byte = 8'h49;
            3: next_byte = 8'h53;
            4: next_byte = captured_status[7:0];
            5: next_byte = captured_status[15:8];
            6: next_byte = captured_status[23:16];
            7: next_byte = captured_status[31:24];
            8: next_byte = captured_fusion[7:0];
            9: next_byte = captured_fusion[15:8];
            10: next_byte = captured_fusion[23:16];
            11: next_byte = captured_fusion[31:24];
            default: case (lane)
                0: next_byte = read_word[7:0];
                1: next_byte = read_word[15:8];
                default: next_byte = read_word[23:16];
            endcase
        endcase
    end

    always @(posedge clk) begin
        if (capturing) capture[wr_addr] <= samples;
        read_word <= capture[rd_addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            period <= 0;
            wr_addr <= 0;
            rd_addr <= 0;
            capturing <= 0;
            sending <= 0;
            header <= 0;
            captured_status <= 0;
            captured_fusion <= 0;
            lane <= 0;
            shift <= 10'h3ff;
            bits_left <= 0;
            baud_count <= 0;
        end else begin
            period <= period + 1'b1;
            if ((period == 0 || trigger) && !capturing && !sending && bits_left == 0) begin
                capturing <= 1;
                wr_addr <= 0;
                captured_status <= field_status;
                captured_fusion <= fusion_status;
            end
            if (capturing) begin
                wr_addr <= wr_addr + 1'b1;
                if (&wr_addr) begin
                    capturing <= 0;
                    sending <= 1;
                    rd_addr <= 0;
                    header <= 0;
                    lane <= 0;
                end
            end
            if (bits_left != 0) begin
                if (baud_count == DIV - 1) begin
                    baud_count <= 0;
                    shift <= {1'b1, shift[9:1]};
                    bits_left <= bits_left - 1'b1;
                end else baud_count <= baud_count + 1'b1;
            end else if (sending) begin
                shift <= {1'b1, next_byte, 1'b0};
                bits_left <= 4'd10;
                if (header < 12) header <= header + 1'b1;
                else if (lane < 2) lane <= lane + 1'b1;
                else begin
                    lane <= 0;
                    rd_addr <= rd_addr + 1'b1;
                    if (&rd_addr) sending <= 0;
                end
            end
        end
    end
endmodule
`default_nettype wire
