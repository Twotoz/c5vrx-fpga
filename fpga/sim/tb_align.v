// Triversity: align_bc.v (one shared engine for C5 B and C) against two
// align_b.v on the same streams. A complex FM signal (video-rate deviation,
// composite video) is sampled by C5 A on clk_a and by B and C on their own
// clocks (+60 / -45 ppm), 15.3 / 24.6 samples ahead of A, 3 bits per
// component, plus noise. Per clk_a sample after the settle time: does the
// aligned B / C sample equal A's within a sample (both engines), and are en_b / en_c set.
`timescale 1ns/1ps
module tb_align;
    parameter real TA = 25.0, TB = 25.0 * (1.0 + 60e-6), TC = 25.0 * (1.0 - 45e-6);
    parameter real DB = 15.3 * 25.0, DC = 24.6 * 25.0, NOISE = 0.25;
    parameter integer MS = 16, SETTLE_MS = 9;
    reg clk_a = 0, clk_b = 0, clk_c = 0, rst = 1;
    always #(TA / 2) clk_a = ~clk_a;
    always #(TB / 2) clk_b = ~clk_b;
    always #(TC / 2) clk_c = ~clk_c;
    real PI2 = 6.283185307179586;
    // composite video (sync, burst, picture) FM-modulated at 8 MHz/V, a 100 kHz
    // carrier offset; the phase integrated in 1 ns steps, kept 1024 ns back
    real ph [0:1023]; integer pn = 0; real phase_now = 0.0;
    function real video; input real t; real u;
        begin
            u = t - 63555.6 * $floor(t / 63555.6);
            if (u < 4700.0) video = -0.3;
            else if (u > 5300.0 && u < 7800.0) video = 0.15 * $sin(PI2 * 3.579545e-3 * t);
            else if (u > 9400.0 && u < 62000.0)
                video = 0.35 + 0.25 * $sin(PI2 * 0.8e-3 * t) + 0.12 * $sin(PI2 * 3.2e-3 * t + 0.4) + 0.2 * $sin(PI2 * 1.7e-5 * t);
            else video = 0.0;
        end
    endfunction
    initial begin : integ
        integer k;
        for (k = 0; k < 1024; k = k + 1) ph[k] = 0.0;
        forever begin #1; phase_now = phase_now + PI2 * (1e5 + 8e6 * video($realtime)) * 1e-9; pn = (pn + 1) % 1024; ph[pn] = phase_now; end
    end
    function real phase_at; input real back; integer d; begin d = $rtoi(back + 0.5); phase_at = ph[(pn - d + 1024) % 1024]; end endfunction
    integer seed = 7;
    function real gauss; input integer dummy; integer k; real acc;
        begin acc = 0; for (k = 0; k < 4; k = k + 1) acc = acc + ($random(seed) & 16'hffff) / 65536.0; gauss = (acc - 2.0) * 1.732; end
    endfunction
    function [2:0] q3; input real v; integer r;
        begin r = $rtoi(v + 4.5) - 4; if (v + 4.5 < 0) r = -4; if (r < -4) r = -4; if (r > 3) r = 3; q3 = r[2:0]; end
    endfunction
    function [7:0] smp; input real back;
        real p; begin p = phase_at(back); smp = {q3(3.4 * $cos(p) + NOISE * gauss(0)), 1'b0, q3(3.4 * $sin(p) + NOISE * gauss(0)), 1'b0}; end
    endfunction
    reg [7:0] ra = 0, rb = 0, rc = 0;
    always @(posedge clk_a) ra <= smp(900.0);              // A 36 samples late: B and C lead it (the buffers can only delay)
    always @(posedge clk_b) rb <= smp(900.0 - DB);
    always @(posedge clk_c) rc <= smp(900.0 - DC);
    // the old engines
    wire [7:0] o_ad1, o_ad2, o_b, o_c; wire o_enb, o_enc, o_alb, o_alc;
    align_b u_ob (.clk_b(clk_b), .raw_b_in(rb), .clk_a(clk_a), .rst_a(rst), .ref_lost(1'b0), .raw_a(ra), .raw_a_d(o_ad1), .raw_b(o_b), .en_b(o_enb), .b_alive(o_alb), .lag());
    align_b u_oc (.clk_b(clk_c), .raw_b_in(rc), .clk_a(clk_a), .rst_a(rst), .ref_lost(1'b0), .raw_a(ra), .raw_a_d(o_ad2), .raw_b(o_c), .en_b(o_enc), .b_alive(o_alc), .lag());
    // the shared one
    wire [7:0] n_ad, n_b, n_c; wire n_enb, n_enc, n_alb, n_alc; wire [5:0] n_lb, n_lc;
    align_bc u_n (.clk_b(clk_b), .clk_c(clk_c), .raw_b_in(rb), .raw_c_in(rc), .clk_a(clk_a), .rst_a(rst), .ref_lost(1'b0), .raw_a(ra),
                  .raw_a_d(n_ad), .raw_b(n_b), .raw_c(n_c), .en_b(n_enb), .en_c(n_enc), .b_alive(n_alb), .c_alive(n_alc),
                  .lag_b(n_lb), .lag_c(n_lc));
    // per sample after the settle time: the aligned sample equals A's at the
    // same clock, one clock before or one after (within one sample: the
    // combiner's tolerance)
    reg [7:0] ha [0:1], hob [0:1], hoc [0:1], hnb [0:1], hnc [0:1];
    function integer near; input [7:0] a0, a1, b0, b1;     // a0 / b0 now, a1 / b1 a clock earlier
        near = (b0 == a0) || (b1 == a0) || (b0 == a1);
    endfunction
    integer n = 0, ob = 0, oc = 0, nb = 0, nc = 0, oen = 0, nen = 0, t_ob = -1, t_oc = -1, t_nb = -1, t_nc = -1, clk = 0;
    always @(posedge clk_a) if (!rst) begin
        clk = clk + 1;
        ha[1] <= ha[0]; ha[0] <= o_ad1; hob[1] <= hob[0]; hob[0] <= o_b; hoc[1] <= hoc[0]; hoc[0] <= o_c;
        hnb[1] <= hnb[0]; hnb[0] <= n_b; hnc[1] <= hnc[0]; hnc[0] <= n_c;
        if (t_ob < 0 && o_enb) t_ob = clk; if (t_oc < 0 && o_enc) t_oc = clk;
        if (t_nb < 0 && n_enb) t_nb = clk; if (t_nc < 0 && n_enc) t_nc = clk;
        if (clk > SETTLE_MS * 40000) begin
            n = n + 1;
            ob = ob + near(o_ad1, ha[0], o_b, hob[0]); oc = oc + near(o_ad1, ha[0], o_c, hoc[0]);
            nb = nb + near(n_ad, ha[0], n_b, hnb[0]); nc = nc + near(n_ad, ha[0], n_c, hnc[0]);
            oen = oen + (o_enb && o_enc); nen = nen + (n_enb && n_enc);
        end
    end
    initial begin
        #200 rst = 0;
        #(MS * 1e6);
        $display("RESULT n=%0d old_b=%0d old_c=%0d new_b=%0d new_c=%0d old_en=%0d new_en=%0d lock_ob=%0d lock_oc=%0d lock_nb=%0d lock_nc=%0d",
                 n, ob, oc, nb, nc, oen, nen, t_ob, t_oc, t_nb, t_nc);
        $finish;
    end
endmodule
