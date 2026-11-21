// Triversity: jpeg_enc.v on one field. blocks.hex: per block a component
// line then 64 samples (row-major); the bytes out go to out.hex.
`timescale 1ns/1ps
module tb_jpeg;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [7:0] mem [0:400000];
    reg f_start = 0, f_end = 0, in_we = 0, in_commit = 0, pal = 0, parity = 0;
    reg [2:0] qi = 0; reg [15:0] seq = 0;
    reg [5:0] in_addr = 0; reg [7:0] in_data = 0; reg [1:0] in_comp = 0;
    wire busy, f_done, in_rdy, o_valid; wire [7:0] o_data; wire [17:0] f_bytes;
    reg o_ready = 1;
    jpeg_enc u (.clk(clk), .rst(rst), .f_start(f_start), .qi(qi), .pal(pal), .parity(parity), .seq(seq), .f_end(f_end),
                .busy(busy), .f_done(f_done), .f_bytes(f_bytes), .in_rdy(in_rdy), .in_we(in_we), .in_addr(in_addr),
                .in_data(in_data), .in_comp(in_comp), .in_commit(in_commit), .o_valid(o_valid), .o_data(o_data), .o_ready(o_ready));
    integer nb, b, k, f, p, stall_seed, cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (o_valid && o_ready) $fwrite(f, "%02x\n", o_data);
        o_ready <= stall_seed ? ($random % 4 != 0) : 1'b1;      // optional back-pressure
    end
    initial begin
        if (!$value$plusargs("nb=%d", nb)) nb = 1;
        if (!$value$plusargs("qi=%d", qi)) qi = 0;
        if (!$value$plusargs("pal=%d", pal)) pal = 0;
        if (!$value$plusargs("stall=%d", stall_seed)) stall_seed = 0;
        seq = 16'h1234; parity = 1;
        $readmemh("blocks.hex", mem);
        f = $fopen("out.hex", "w");
        repeat (5) @(posedge clk); rst = 0;
        @(posedge clk) f_start <= 1; @(posedge clk) f_start <= 0;
        p = 0;
        for (b = 0; b < nb; b = b + 1) begin
            while (!in_rdy) @(posedge clk);
            for (k = 0; k < 64; k = k + 1) begin
                @(posedge clk) begin in_we <= 1; in_addr <= k; in_data <= mem[p + 1 + k]; end
            end
            @(posedge clk) begin in_we <= 0; in_comp <= mem[p][1:0]; in_commit <= 1; end
            @(posedge clk) in_commit <= 0;
            @(posedge clk);                       // in_rdy follows the commit one clock later
            p = p + 65;
        end
        @(posedge clk) f_end <= 1; @(posedge clk) f_end <= 0;
        wait (f_done); @(posedge clk); while (o_valid) @(posedge clk);   // the last byte may still wait on o_ready
        $display("cycles %0d bytes %0d", cyc, f_bytes);
        $fclose(f); $finish;
    end
    initial begin #400000000; $display("TIMEOUT"); $finish; end
endmodule
