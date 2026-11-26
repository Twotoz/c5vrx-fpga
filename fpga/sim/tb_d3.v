`timescale 1ns/1ps
module tb_d3;
    reg clk = 0, rst = 1, even_sample = 1;
    reg [18:0] words [0:32767], sample = 0;
    wire [5:0] code;
    wire [1:0] level;
    integer k, n;
    d3_fm dut (.clk(clk), .rst(rst), .run(1'b1), .even_sample(even_sample),
               .valid(sample[16]), .click(sample[17]), .steady(sample[18]),
               .phi(sample[15:0]), .code(code), .degrade(level));
    always #12.5 clk = ~clk;
    initial begin
        if (!$value$plusargs("n=%d", n)) $fatal(1, "missing sample count");
        $readmemh("d3.hex", words, 0, n - 1);
        repeat (4) @(negedge clk);
        rst = 0;
        for (k = 0; k < n; k = k + 1) begin
            sample = words[k];
            even_sample = !k[0];
            @(negedge clk);
            $display("%02x", {level, code});
        end
        $finish;
    end
endmodule
