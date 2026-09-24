/*******************************
 *            PC.v             *
 *      2015/11/12 21:04       *
 *******************************
*/

module PC(
		input  wire             pc_clk,
		input  wire                rst,
		input  wire[2:0]         Timer,
		output wire             ram_ce,
		
		input  wire[7:0]          pc_i,
		output  reg[7:0]           Out,
);

always @ (*) begin
	if (rst == 1'b1) begin
		Out <= 8'h00;
	end
end

always @ (posedge clk) begin
	if (Timer == 3'b000 || Timer == 3'b010) begin
		Out <= Out + 1'b1;
	end
	if (Timer == 3'b101) begin
		Out <= pc_i;
	end
end

endmodule