/*******************************
 *         Immed_Reg.v         *
 *      2015/11/21 10:55       *
 *******************************
*/

module Immed(
		input  wire               clk,
		input  wire               rst,
		input  wire[2:0]        Timer,
		
		input  wire[7:0]      immed_i,
		output  reg[7:0]          Out,
);


always @ (posedge clk or posedge rst) begin
	if (rst == 1'b1) begin
		Out <= 8'h00;
	end else begin
		if (Timer == 3'b011) begin
			immed <= immed_i;
		end
	end
end

endmodule