/********************************
 *          Regfile.v           *
 *       2015/12/13 13:36       *
 ********************************
*/

module Regfile(
		input  wire               clk,
		input  wire               rst,
		
		input  wire[2:0]        Timer,
		input  wire[1:0]         dsel,
		input  wire[7:0]         dreg,
		
		input  wire[1:0]         ssel,
		output wire[7:0]         sreg,
		
		output wire[7:0]         treg,
);

reg[7:0] GPR[0:3]

always @ (posedge rst) begin
	GPR[0] <=	8'h00;
	GPR[1] <=	8'h00;
	GPR[2] <=	8'h00;
	GPR[3] <=	8'h00;
end

always @ (posedge clk) begin
	if(Timer ==3'b111) begin
		sreg <= GPR[dsel];
	end
end

assign sreg <= GPR[ssel];
assign treg <= GPR[dsel];

endmodule