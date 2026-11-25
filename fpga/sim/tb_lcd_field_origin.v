// Completed source rows arrive at 1/2 the LCD line rate. Verify field origin
// when NTSC alternates 262 and 263 source lines per field.
`timescale 1ns/1ps
module tb_lcd_field_origin;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg line_tog = 0;
    reg [8:0] line_info = 0;
    wire [10:0] lb_addr;
    wire de, vs;
    lcd_out dut (.clk(clk), .rst(rst), .line_tog_a(line_tog), .line_info_a(line_info),
                 .field_tog_a(1'b0), .locked_a(1'b1), .pal_a(1'b0), .hmode(2'd0),
                 .boot(1'b0), .lb_addr(lb_addr), .lb_data(16'd0), .osd_cell(12'd0),
                 .lcd_de(de), .lcd_vs(vs));

    integer bank_rows [0:1], bank_fields [0:1];
    integer field_no = 0, row = 8, countdown = 1455, src_row;
    always @(negedge clk) if (!rst) begin
        if (countdown == 0) begin
            countdown = 2144;
            src_row = row - 18;
            line_tog <= ~line_tog;
            line_info <= {src_row >= 0 && src_row < 240, src_row[7:0]};
            if (src_row >= 0 && src_row < 240) begin
                bank_rows[src_row[0]] <= src_row;
                bank_fields[src_row[0]] <= field_no;
            end
            row = row + 1;
            if (row == 262 + (field_no & 1)) begin
                row = 0;
                field_no = field_no + 1;
            end
        end else countdown = countdown - 1;
    end

    integer frame = 0, visible_line = 0, clocks = 0, last_start = 0, last_field = -1;
    reg de_prev = 0, vs_prev = 1;
    always @(posedge clk) if (!rst) begin
        clocks = clocks + 1;
        if (vs_prev && !vs) begin
            frame = frame + 1;
            visible_line = 0;
        end
        if (de && !de_prev && frame > 0) begin
            if (visible_line < 2 && bank_rows[lb_addr[10]] != 0)
                $fatal(1, "frame %0d starts LCD row %0d with source row %0d",
                       frame, visible_line, bank_rows[lb_addr[10]]);
            if (visible_line == 0) begin
                if (last_start != 0) begin
                    if (bank_fields[lb_addr[10]] != last_field + 1)
                        $fatal(1, "skipped or repeated source field %0d after %0d",
                               bank_fields[lb_addr[10]], last_field);
                    $display("Field interval: %0d LCD clocks (%0.2f Hz)",
                             clocks - last_start, 33_750_000.0 / (clocks - last_start));
                end
                last_start = clocks;
                last_field = bank_fields[lb_addr[10]];
            end
            visible_line = visible_line + 1;
            if (frame == 4 && visible_line == 480) begin
                $display("PASS: source row zero starts four alternating NTSC fields");
                $finish;
            end
        end
        de_prev = de;
        vs_prev = vs;
    end
    initial begin
        bank_rows[0] = -1;
        bank_rows[1] = -1;
        bank_fields[0] = -1;
        bank_fields[1] = -1;
        repeat (4) @(negedge clk);
        #1 rst = 0;
        repeat (3000000) @(negedge clk);
        $fatal(1, "timed out waiting for four frames");
    end
endmodule
