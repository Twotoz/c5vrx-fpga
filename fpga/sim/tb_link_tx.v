`timescale 1ns/1ps
module tb_lt; reg clk=0, rst=1; always #14.815 clk=~clk; wire tx;
link_tx #(.CLK_HZ(33750000)) u(.clk(clk),.rst(rst),.on(1'b1),.channel(6'd21),.g_set(1'b1),.gain_model(3'd2),.a_set(1'b0),.afc(1'b1),.f_seq(8'd7),.s_set(1'b1),.menu_s(8'hB7),.menu_t(3'd5),.tx(tx));
integer f,k; initial begin f=$fopen("lt.txt","w"); #200 rst=0; for(k=0;k<1200000;k=k+1) begin @(posedge clk); $fwrite(f,"%0d\n",tx); end $fclose(f); $finish; end
endmodule
