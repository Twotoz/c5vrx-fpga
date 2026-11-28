// Drive broad-pulse candidates through the real qualification gates, without
// spending several hundred thousand clocks between every decision.
`timescale 1ns/1ps
module tb_field_grid;
    reg clk = 0, rst = 1;
    reg pulse = 0;
    reg half_line = 0;
    wire pal, field_tog;
    wire [11:0] edge_phase = half_line ? 12'd1275 : 12'd0;
    localparam NTSC = 667333, PAL = 800000, TRACK = 384;
    always #12.5 clk = ~clk;
    vid_sync rx (.clk(clk), .rst(rst), .code(6'd25), .keep_lock(1'b1), .adapt(1'b0),
                 .ans(1'b0), .pal(pal), .field_tog(field_tog));

    integer n_acc = 0, n_pred = 0;   // field events this test made, for fps_real / fps_pred
    task candidate;
        input integer trusted_elapsed, raw_elapsed;
        input want_event, want_pal;
        reg old;
        begin
            @(negedge clk);
            rx.field_age = trusted_elapsed;
            rx.raw_age = raw_elapsed;
            rx.broad_gap = 12'd1275;
            half_line = !half_line;
            pulse = 1;
            old = field_tog;
            @(negedge clk);
            pulse = 0;
            if (want_event) n_acc = n_acc + 1;
            if ((old ^ field_tog) !== want_event || pal !== want_pal)
                $fatal(1, "field event/standard mismatch at trusted=%0d raw=%0d", trusted_elapsed, raw_elapsed);
        end
    endtask

    task missed;
        reg old;
        begin
            @(negedge clk);
            rx.field_age = rx.tracked_period + TRACK;
            old = field_tog;
            @(negedge clk);
            n_pred = n_pred + 1;
            if (old === field_tog || rx.field_age != TRACK + 1)
                $fatal(1, "holdover failed to emit exactly one field on the old grid");
        end
    endtask

    initial begin
        force rx.low = pulse;
        force rx.low_len = 12'd700;
        force rx.hc_cross = edge_phase;
        force rx.lock = 4'd15;
        repeat (4) @(negedge clk);
        rst = 0;
        candidate(16000, 1048575, 1, 0);
        candidate(NTSC - 111600, NTSC - 111600, 0, 0);  // 2.79 ms early
        missed();
        candidate(NTSC + 130, 1048575, 1, 0);          // real edge after missed field
        candidate(NTSC - 141, NTSC - 141, 1, 0);
        // Interference can erase the expected broad pulse while leaving
        // adjacent serrations. Neither an early nor a late neighbour may
        // reset the displayed row origin.
        candidate(NTSC - 1271, NTSC - 1271, 0, 0);
        missed();
        candidate(1271, NTSC + 1271, 0, 0);
        candidate(2542, NTSC + 2542, 0, 0);
        candidate(PAL - NTSC, PAL, 0, 0);
        missed();
        candidate(2 * (PAL - NTSC), PAL, 0, 0);
        missed();
        candidate(3 * (PAL - NTSC), PAL, 1, 1);
        candidate(PAL - 92000, PAL - 92000, 0, 1);      // 2.30 ms early
        candidate(PAL - 1280, PAL - 1280, 0, 1);
        missed();
        candidate(1280, PAL + 1280, 0, 1);
        candidate(PAL - 160, 1048575, 1, 1);
        // One ambiguous interval and then a missing interval reset the
        // alternate-format evidence; only consecutive real intervals count.
        candidate(NTSC, NTSC, 0, 1);
        missed();
        candidate(NTSC, 1048575, 0, 1);
        candidate(NTSC, NTSC, 0, 1);
        candidate(2 * NTSC - PAL, NTSC, 0, 1);
        candidate(3 * NTSC - 2 * PAL, NTSC, 1, 0);
        candidate(NTSC - 134, NTSC - 134, 1, 0);
        repeat (32) candidate(NTSC + 133, NTSC + 133, 1, 0);
        if (rx.tracked_period < NTSC + 118 || rx.tracked_period > NTSC + 140)
            $fatal(1, "expected the field grid to track a 200 ppm clock");
        repeat (4) missed();
        candidate(NTSC + 133, NTSC + 133, 1, 0);
        // the one-second window closes: real and predicted fields of the window
        @(negedge clk); rx.fps_tim = 26'd39999999; @(negedge clk);
        if (rx.fps_real !== n_acc || rx.fps_pred !== n_pred)
            $fatal(1, "fields a second: real %0d predicted %0d, want %0d %0d", rx.fps_real, rx.fps_pred, n_acc, n_pred);
        $display("fields a second: %0d real, %0d predicted", rx.fps_real, rx.fps_pred);
        $display("field grid PASS: adjacent serrations, missed fields, 200 ppm, and both standard changes");
        $finish;
    end
endmodule
