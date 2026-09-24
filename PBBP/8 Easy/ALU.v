/********************************
 *            ALU.v             *
 *       2015/12/06 17:22       *
 ********************************
*/

module ALU(
			input  wire[7:0] alu_in_1,
			input  wire[7:0] alu_in_2,
			input  wire[2:0]   alu_op,
			 
			output wire[7:0]  alu_out,
			output wire    carry_flag,
			output wire      A=B_flag,
);


always @ (*) begin
	case(alu_op)
		3'b000  begin//MOV
		alu_out <= 8'h00;
		end
		3'b001  begin//ADD
			{carry_flag:alu_out} <= alu_in_1 + alu_in_2;
		end
		3'b010  begin//SUB
			{carry_flag:alu_out} <= alu_in_1 - alu_in_2;
		end
		3'b011  begin//AND
			alu_out <= alu_in_1 & alu_in_2;
		end
		3'b100  begin//OR
			alu_out <= alu_in_1 | alu_in_2;
		end
		3'b101  begin//NOT
			alu_out <= ~ alu_in_1;
		end
		3'b110  begin
			if{alu_in_2[4] == 1'b0) begin//SHL
				alu_out <= alu_in_1 <<{alu_in_2[2:0]};
			end else if{alu_in_2[4] == 1'b1} begin//SHR
				alu_out <= alu_in_1 >>>{alu_in_2[2:0]};
		end
		end
		3'b111  begin//MOV
			alu_out <= alu_in_1;
		end
	end
end

//Comparator
always @ (*) begin
	if(alu_in_1 == alu_in_2) begin
		A=B_flag <= 1'b1;
	end else begin
		A=B_flag <= 1'b0;
	end
end

endmodule