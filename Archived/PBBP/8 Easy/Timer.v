/*******************************
 *           Timer.v           *
 *      201 /  /     :         *
 *******************************
*/

module Timer(
		input  wire               clk,
		input  wire               rst,
		
		input  wire[2:0]      TimerOP,
		
		output  reg[2:0]     TimerOut,
);

always @ (*) begin
	if (rst == 1'b1) begin
		TimerOut <= 3'b000;
	end
end

/*
 *NOP
 *TimerOP:000
 *000 001 000
 *IF  ID  IF(Next)
 
 *MOV ADD SUB AND OR NOT
 *TimerOP:001
 *000 001 100 111
 *IF  ID  EX  WB
 
 *MOVI S
 *TimerOP:010
 *000 001 010 011 100 111
 *IF  ID  IF2 ID2 EX  WB
 
 *LOD
 *TimerOP:011
 *000 001 010 011 110 111
 *IF  ID  IF2 ID2 MEM WB
 
 *STR
 *TimerOP:100
 *000 001 010 011 110
 *IF  ID  IF2 ID2 MEM
*/

always @ (nosedge clk) begin
	if (rst != 1'b1 && TimerOut == 3'b000) begin
		TimerOut <= 3'b001;
	end
	if (rst != 1'b1 && TimerOut == 3'b001) begin
		if (TimerOP == 3'b000) begin//NOP
			TimerOut <= 3'b000;
		end
		if (TimerOP == 3'b001) begin//MOV,ADD,SUB,AND,OR,NOT
			TimerOut <= 3'b100;
		end
		if (TimerOP == 3'b010 || TimerOP == 3'b011 || TimerOP == 3'b100 || TimerOP == 3'b101 || TimerOP == 3'b110) begin
		//MOVI,S /LOD /STR /JMP /BE,BNE,BEZ
			TimerOut <= 3'b010;
		end
		if (TimerOP == 3'b111) begin
			TimerOut <= 3'b001;
		end
	end
	if (rst != 1'b1 && TimerOut == 3'b010) begin
		TimerOut <= 3'b011;
	end
	if (rst != 1'b1 && TimerOut == 3'b011) begin
		if (TimerOP == 3'b10 || TimerOut == 3'b110) begin
			TimerOut <= 3'b100;
		end