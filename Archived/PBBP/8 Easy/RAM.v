/*******************************
 *            RAM.v            *
 **
 *******************************
*/


module RAM(
		input  wire[7:0]         addr,
		input  wire                ce,
		input  wire                we,
		input  wire[7:0]          din,
		
		output wire[7:0]         dout,
);

