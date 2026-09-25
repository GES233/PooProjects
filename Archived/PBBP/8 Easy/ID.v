/********************************
 *             ID.v             *
 *
 ********************************
*/

module ID(
		input  wire               clk,/*时钟*/
		input  wire               rst,/*重启*/
		input  wire[7:0]      id_inst,/*指令输入*/
		input  wire[3:0]      counter,/**/
		
		input  wire          A=B_flag,
		
	    output wire            pc_clk,/*程序计数器时钟*/
		output wire            ir_clk,/*指令寄存器时钟*/
		output wire         immed_clk,/*立即数寄存器时钟*/
		output wire           GPR_clk,/*通用寄存器时钟*/
		output wire            dr_clk,/*数据寄存器时钟*/
		output wire           RAM_clk,/*存储器时钟*/
		
		output wire             pc_ce,/*转移有效*/
		output wire            GPR_we,/*通用寄存器写使能*/
		output wire            RAM_ce,/*存储器写使能*/
		
		output wire[3:0]       ALU_op,
	    output wire[1:0]         ssel,
		output wire[1:0]         dsel,
		
		output wire               mem,
	    output wire           mem_GPR,
);


wire op [3:0] = id_inst[4:7];

/*Reset*/
always @ (posedge clk or posedge rst) begin
	if(rst == 1'b0)begin
		pc_clk <= 1'b0;
		ir_clk <= 1'b0;
		immed_clk <= 1'b0;
		GPR_clk<= 1'b0;
		dr_clk<= 1'b0;
		RAM_clk <= 1'b0;
		
		pc_ce <= 1'b0;
		GPR_we <= 1'b0;
		RAM_we <= 1'b0;
		
		ALU_op <= 4'h0;
		ssel <= 2'b00;
		dsel <= 2'b00;
		
		mem <= 1'b0;
		mem_GPR <= 1'b0;
		
		counter <= 4'b0000;
/*Counter*/
	end else begin
		counter <= counter+1'b1;
	end
end
	
always @ (*) begin
	case(op) begin
		4'b0000    begin:
			pc_ce <= 1'b0;
			GPR_we <= 1'b0;
			RAM_ce <= 1'b0;
			
			ALU_op <= 3'b000;
			ssel <= 2'b00;
			dsel <= 2'b00;
			
			mem <= 1'b0;
			mem_GPR <= 1'b0