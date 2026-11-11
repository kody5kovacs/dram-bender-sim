// Behavioral stand-in for the Xilinx Block Memory Generator "scratchpad" IP
// (single-port, 1024 x 32, read latency 1, WRITE_FIRST)
module scratchpad(input [9:0] addra, input clka, input [31:0] dina,
                  output reg [31:0] douta, input ena, input [0:0] wea);
  reg [31:0] mem [0:1023];
  always @(posedge clka) if (ena) begin
    if (wea) begin mem[addra] <= dina; douta <= dina; end
    else douta <= mem[addra];
  end
endmodule
