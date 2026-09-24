module RAM(
		input	wire[15:0]			Address,
		input	wire[15:0]			StoreData,
		input	wire					Store,
		
		output	wire[15:0]			Data,
);

//定义两个
reg [7:0] RAM1 [0:32767];
reg [7:0] RAM2 [0:32767];

wire 15 RealAddress1 Address[15:11]
wire 15 RealAddress2
//RealAddress2
always @ (*) begin
	if (Address[0] == 1'b1) begin
		RealAddress2 <= Address[15:1];
	end else begin
		RealAddress2 <= Address[15:1]+1;
	end
end

//写操作
always @ (*) begin
	if (Store == 1'b1) begin
		RAM2[RealAddress2] <= StoreData[15:8];
		RAM1[RealAddress1] <= StoreData[7:0];
	end
end

//读操作
always @ (*) begin
	Data <={
		RAM2[RealAddress2],
		RAM1[RealAddress1]};
end

endmodule