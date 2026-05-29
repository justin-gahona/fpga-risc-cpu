## ================================================================
## Basys 3 — RTL Pong Console  (W25Q32 SPI cartridge)
## ================================================================

## 100 MHz system clock
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk -waveform {0 5} [get_ports CLK100MHZ]

## VGA Connector
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[0]}]
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[1]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[2]}]
set_property -dict { PACKAGE_PIN N19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[3]}]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[0]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[1]}]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[2]}]
set_property -dict { PACKAGE_PIN D17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[3]}]
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[0]}]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[1]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[2]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[3]}]
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports Hsync]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports Vsync]

## Push Buttons (on-board)
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btnC]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports btnU]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports btnD]

## W25Q32 SPI Flash Cartridge — PMOD JA
## JA1=J1(CS#)  JA2=L2(CLK)  JA3=J2(DI/MOSI)  JA4=G2(DO/MISO)
set_property -dict { PACKAGE_PIN J1 IOSTANDARD LVCMOS33 } [get_ports spi_cs_n]
set_property -dict { PACKAGE_PIN L2 IOSTANDARD LVCMOS33 } [get_ports spi_clk]
set_property -dict { PACKAGE_PIN J2 IOSTANDARD LVCMOS33 } [get_ports spi_mosi]
set_property -dict { PACKAGE_PIN G2 IOSTANDARD LVCMOS33 } [get_ports spi_miso]
set_property PULLUP true [get_ports spi_miso]


## Cartridge present detect — PMOD JA pin 7 (bottom row, same connector as SPI)
## Cartridge PCB ties JA7 to 3.3V; FPGA pull-down reads 0 when no cartridge
set_property -dict { PACKAGE_PIN H1 IOSTANDARD LVCMOS33 } [get_ports cart_present]
set_property PULLDOWN true [get_ports cart_present]

## NES Controller — PMOD JC (active-low, pull-ups on controller PCB)
## JC1=K17(up)  JC2=M18(down)  JC3=N17(reset)  JC4=P18(start/pause)
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports ctrl_up]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports ctrl_down]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports ctrl_start]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports ctrl_a]
## FPGA-side pull-ups: prevents floating inputs when controller is unplugged
set_property PULLUP true [get_ports ctrl_up]
set_property PULLUP true [get_ports ctrl_down]
set_property PULLUP true [get_ports ctrl_start]
set_property PULLUP true [get_ports ctrl_a]

## ================================================================
## Timing Exceptions
## ================================================================

## CPU runs at 10 kHz (cpu_step fires every 10,000 × 10 ns = 100 µs).
## Intra-CPU paths only need to settle in 2 clock cycles to be safe.
set_multicycle_path -setup 2 \
    -from [get_cells -hierarchical -filter {NAME =~ *u_cpu*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_cpu*}]
set_multicycle_path -hold  1 \
    -from [get_cells -hierarchical -filter {NAME =~ *u_cpu*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_cpu*}]

## SPI MISO: asynchronous input from W25Q32, sampled after fixed SPI cycles.
set_input_delay -clock sys_clk -max 8.0 [get_ports spi_miso]
set_input_delay -clock sys_clk -min 0.0 [get_ports spi_miso]

## SPI outputs: W25Q32 setup/hold requirements are generous vs 12.5 MHz SPI clock.
set_output_delay -clock sys_clk -max 3.0 [get_ports spi_cs_n]
set_output_delay -clock sys_clk -max 3.0 [get_ports spi_clk]
set_output_delay -clock sys_clk -max 3.0 [get_ports spi_mosi]

## VGA outputs are registered; monitor input timing is very forgiving.
set_output_delay -clock sys_clk -max 3.0 [get_ports {vgaRed[*]}]
set_output_delay -clock sys_clk -max 3.0 [get_ports {vgaGreen[*]}]
set_output_delay -clock sys_clk -max 3.0 [get_ports {vgaBlue[*]}]
set_output_delay -clock sys_clk -max 3.0 [get_ports Hsync]
set_output_delay -clock sys_clk -max 3.0 [get_ports Vsync]

## Button / controller inputs are all debounced in logic — no tight input req.
set_input_delay -clock sys_clk -max 8.0 [get_ports {btnU btnD btnC}]
set_input_delay -clock sys_clk -min 0.0 [get_ports {btnU btnD btnC}]
set_input_delay -clock sys_clk -max 8.0 [get_ports {ctrl_up ctrl_down ctrl_start ctrl_a}]
set_input_delay -clock sys_clk -min 0.0 [get_ports {ctrl_up ctrl_down ctrl_start ctrl_a}]
