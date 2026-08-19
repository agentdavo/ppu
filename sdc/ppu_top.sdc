###############################################################################
# Created by write_sdc
###############################################################################
current_design ppu_top
###############################################################################
# Timing Constraints
###############################################################################
create_clock -name clk -period 33.0000 [get_ports {clk}]
set_clock_uncertainty 1.0000 clk
set_propagated_clock [get_clocks {clk}]
set_false_path\
    -from [list [get_ports {clk}]\
           [get_ports {fb_burst_data[0]}]\
           [get_ports {fb_burst_data[10]}]\
           [get_ports {fb_burst_data[11]}]\
           [get_ports {fb_burst_data[12]}]\
           [get_ports {fb_burst_data[13]}]\
           [get_ports {fb_burst_data[14]}]\
           [get_ports {fb_burst_data[15]}]\
           [get_ports {fb_burst_data[16]}]\
           [get_ports {fb_burst_data[17]}]\
           [get_ports {fb_burst_data[18]}]\
           [get_ports {fb_burst_data[19]}]\
           [get_ports {fb_burst_data[1]}]\
           [get_ports {fb_burst_data[20]}]\
           [get_ports {fb_burst_data[21]}]\
           [get_ports {fb_burst_data[22]}]\
           [get_ports {fb_burst_data[23]}]\
           [get_ports {fb_burst_data[24]}]\
           [get_ports {fb_burst_data[25]}]\
           [get_ports {fb_burst_data[26]}]\
           [get_ports {fb_burst_data[27]}]\
           [get_ports {fb_burst_data[28]}]\
           [get_ports {fb_burst_data[29]}]\
           [get_ports {fb_burst_data[2]}]\
           [get_ports {fb_burst_data[30]}]\
           [get_ports {fb_burst_data[31]}]\
           [get_ports {fb_burst_data[3]}]\
           [get_ports {fb_burst_data[4]}]\
           [get_ports {fb_burst_data[5]}]\
           [get_ports {fb_burst_data[6]}]\
           [get_ports {fb_burst_data[7]}]\
           [get_ports {fb_burst_data[8]}]\
           [get_ports {fb_burst_data[9]}]\
           [get_ports {fb_burst_gnt}]\
           [get_ports {fb_burst_valid}]\
           [get_ports {mem_ack}]\
           [get_ports {mem_hreq}]\
           [get_ports {mem_rdata[0]}]\
           [get_ports {mem_rdata[10]}]\
           [get_ports {mem_rdata[11]}]\
           [get_ports {mem_rdata[12]}]\
           [get_ports {mem_rdata[13]}]\
           [get_ports {mem_rdata[14]}]\
           [get_ports {mem_rdata[15]}]\
           [get_ports {mem_rdata[1]}]\
           [get_ports {mem_rdata[2]}]\
           [get_ports {mem_rdata[3]}]\
           [get_ports {mem_rdata[4]}]\
           [get_ports {mem_rdata[5]}]\
           [get_ports {mem_rdata[6]}]\
           [get_ports {mem_rdata[7]}]\
           [get_ports {mem_rdata[8]}]\
           [get_ports {mem_rdata[9]}]\
           [get_ports {paddr[0]}]\
           [get_ports {paddr[1]}]\
           [get_ports {paddr[2]}]\
           [get_ports {paddr[3]}]\
           [get_ports {paddr[4]}]\
           [get_ports {paddr[5]}]\
           [get_ports {paddr[6]}]\
           [get_ports {paddr[7]}]\
           [get_ports {penable}]\
           [get_ports {psel}]\
           [get_ports {pwdata[0]}]\
           [get_ports {pwdata[10]}]\
           [get_ports {pwdata[11]}]\
           [get_ports {pwdata[12]}]\
           [get_ports {pwdata[13]}]\
           [get_ports {pwdata[14]}]\
           [get_ports {pwdata[15]}]\
           [get_ports {pwdata[16]}]\
           [get_ports {pwdata[17]}]\
           [get_ports {pwdata[18]}]\
           [get_ports {pwdata[19]}]\
           [get_ports {pwdata[1]}]\
           [get_ports {pwdata[20]}]\
           [get_ports {pwdata[21]}]\
           [get_ports {pwdata[22]}]\
           [get_ports {pwdata[23]}]\
           [get_ports {pwdata[24]}]\
           [get_ports {pwdata[25]}]\
           [get_ports {pwdata[26]}]\
           [get_ports {pwdata[27]}]\
           [get_ports {pwdata[28]}]\
           [get_ports {pwdata[29]}]\
           [get_ports {pwdata[2]}]\
           [get_ports {pwdata[30]}]\
           [get_ports {pwdata[31]}]\
           [get_ports {pwdata[3]}]\
           [get_ports {pwdata[4]}]\
           [get_ports {pwdata[5]}]\
           [get_ports {pwdata[6]}]\
           [get_ports {pwdata[7]}]\
           [get_ports {pwdata[8]}]\
           [get_ports {pwdata[9]}]\
           [get_ports {pwrite}]\
           [get_ports {rst_n}]]
set_false_path\
    -to [list [get_ports {de}]\
           [get_ports {fb_burst_addr[0]}]\
           [get_ports {fb_burst_addr[10]}]\
           [get_ports {fb_burst_addr[11]}]\
           [get_ports {fb_burst_addr[12]}]\
           [get_ports {fb_burst_addr[13]}]\
           [get_ports {fb_burst_addr[14]}]\
           [get_ports {fb_burst_addr[15]}]\
           [get_ports {fb_burst_addr[16]}]\
           [get_ports {fb_burst_addr[17]}]\
           [get_ports {fb_burst_addr[18]}]\
           [get_ports {fb_burst_addr[19]}]\
           [get_ports {fb_burst_addr[1]}]\
           [get_ports {fb_burst_addr[20]}]\
           [get_ports {fb_burst_addr[21]}]\
           [get_ports {fb_burst_addr[22]}]\
           [get_ports {fb_burst_addr[23]}]\
           [get_ports {fb_burst_addr[24]}]\
           [get_ports {fb_burst_addr[25]}]\
           [get_ports {fb_burst_addr[26]}]\
           [get_ports {fb_burst_addr[27]}]\
           [get_ports {fb_burst_addr[28]}]\
           [get_ports {fb_burst_addr[29]}]\
           [get_ports {fb_burst_addr[2]}]\
           [get_ports {fb_burst_addr[30]}]\
           [get_ports {fb_burst_addr[31]}]\
           [get_ports {fb_burst_addr[3]}]\
           [get_ports {fb_burst_addr[4]}]\
           [get_ports {fb_burst_addr[5]}]\
           [get_ports {fb_burst_addr[6]}]\
           [get_ports {fb_burst_addr[7]}]\
           [get_ports {fb_burst_addr[8]}]\
           [get_ports {fb_burst_addr[9]}]\
           [get_ports {fb_burst_len[0]}]\
           [get_ports {fb_burst_len[10]}]\
           [get_ports {fb_burst_len[1]}]\
           [get_ports {fb_burst_len[2]}]\
           [get_ports {fb_burst_len[3]}]\
           [get_ports {fb_burst_len[4]}]\
           [get_ports {fb_burst_len[5]}]\
           [get_ports {fb_burst_len[6]}]\
           [get_ports {fb_burst_len[7]}]\
           [get_ports {fb_burst_len[8]}]\
           [get_ports {fb_burst_len[9]}]\
           [get_ports {fb_burst_req}]\
           [get_ports {halted}]\
           [get_ports {hsync}]\
           [get_ports {irq}]\
           [get_ports {mem_addr[0]}]\
           [get_ports {mem_addr[10]}]\
           [get_ports {mem_addr[11]}]\
           [get_ports {mem_addr[12]}]\
           [get_ports {mem_addr[13]}]\
           [get_ports {mem_addr[14]}]\
           [get_ports {mem_addr[15]}]\
           [get_ports {mem_addr[16]}]\
           [get_ports {mem_addr[17]}]\
           [get_ports {mem_addr[18]}]\
           [get_ports {mem_addr[1]}]\
           [get_ports {mem_addr[2]}]\
           [get_ports {mem_addr[3]}]\
           [get_ports {mem_addr[4]}]\
           [get_ports {mem_addr[5]}]\
           [get_ports {mem_addr[6]}]\
           [get_ports {mem_addr[7]}]\
           [get_ports {mem_addr[8]}]\
           [get_ports {mem_addr[9]}]\
           [get_ports {mem_hgnt}]\
           [get_ports {mem_oe}]\
           [get_ports {mem_req}]\
           [get_ports {mem_wdata[0]}]\
           [get_ports {mem_wdata[10]}]\
           [get_ports {mem_wdata[11]}]\
           [get_ports {mem_wdata[12]}]\
           [get_ports {mem_wdata[13]}]\
           [get_ports {mem_wdata[14]}]\
           [get_ports {mem_wdata[15]}]\
           [get_ports {mem_wdata[1]}]\
           [get_ports {mem_wdata[2]}]\
           [get_ports {mem_wdata[3]}]\
           [get_ports {mem_wdata[4]}]\
           [get_ports {mem_wdata[5]}]\
           [get_ports {mem_wdata[6]}]\
           [get_ports {mem_wdata[7]}]\
           [get_ports {mem_wdata[8]}]\
           [get_ports {mem_wdata[9]}]\
           [get_ports {mem_we}]\
           [get_ports {prdata[0]}]\
           [get_ports {prdata[10]}]\
           [get_ports {prdata[11]}]\
           [get_ports {prdata[12]}]\
           [get_ports {prdata[13]}]\
           [get_ports {prdata[14]}]\
           [get_ports {prdata[15]}]\
           [get_ports {prdata[16]}]\
           [get_ports {prdata[17]}]\
           [get_ports {prdata[18]}]\
           [get_ports {prdata[19]}]\
           [get_ports {prdata[1]}]\
           [get_ports {prdata[20]}]\
           [get_ports {prdata[21]}]\
           [get_ports {prdata[22]}]\
           [get_ports {prdata[23]}]\
           [get_ports {prdata[24]}]\
           [get_ports {prdata[25]}]\
           [get_ports {prdata[26]}]\
           [get_ports {prdata[27]}]\
           [get_ports {prdata[28]}]\
           [get_ports {prdata[29]}]\
           [get_ports {prdata[2]}]\
           [get_ports {prdata[30]}]\
           [get_ports {prdata[31]}]\
           [get_ports {prdata[3]}]\
           [get_ports {prdata[4]}]\
           [get_ports {prdata[5]}]\
           [get_ports {prdata[6]}]\
           [get_ports {prdata[7]}]\
           [get_ports {prdata[8]}]\
           [get_ports {prdata[9]}]\
           [get_ports {pready}]\
           [get_ports {underrun}]\
           [get_ports {vid_b[0]}]\
           [get_ports {vid_b[1]}]\
           [get_ports {vid_b[2]}]\
           [get_ports {vid_b[3]}]\
           [get_ports {vid_b[4]}]\
           [get_ports {vid_g[0]}]\
           [get_ports {vid_g[1]}]\
           [get_ports {vid_g[2]}]\
           [get_ports {vid_g[3]}]\
           [get_ports {vid_g[4]}]\
           [get_ports {vid_r[0]}]\
           [get_ports {vid_r[1]}]\
           [get_ports {vid_r[2]}]\
           [get_ports {vid_r[3]}]\
           [get_ports {vid_r[4]}]\
           [get_ports {vsync}]]
###############################################################################
# Environment
###############################################################################
set_load -pin_load 0.0500 [get_ports {de}]
set_load -pin_load 0.0500 [get_ports {fb_burst_req}]
set_load -pin_load 0.0500 [get_ports {halted}]
set_load -pin_load 0.0500 [get_ports {hsync}]
set_load -pin_load 0.0500 [get_ports {irq}]
set_load -pin_load 0.0500 [get_ports {mem_hgnt}]
set_load -pin_load 0.0500 [get_ports {mem_oe}]
set_load -pin_load 0.0500 [get_ports {mem_req}]
set_load -pin_load 0.0500 [get_ports {mem_we}]
set_load -pin_load 0.0500 [get_ports {pready}]
set_load -pin_load 0.0500 [get_ports {underrun}]
set_load -pin_load 0.0500 [get_ports {vsync}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[31]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[30]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[29]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[28]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[27]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[26]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[25]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[24]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[23]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[22]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[21]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[20]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[19]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[18]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[17]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[16]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[15]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[14]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[13]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[12]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[11]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[10]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[9]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[8]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[7]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[6]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[5]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[4]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[3]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[2]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[1]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_addr[0]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[10]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[9]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[8]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[7]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[6]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[5]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[4]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[3]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[2]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[1]}]
set_load -pin_load 0.0500 [get_ports {fb_burst_len[0]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[18]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[17]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[16]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[15]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[14]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[13]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[12]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[11]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[10]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[9]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[8]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[7]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[6]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[5]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[4]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[3]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[2]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[1]}]
set_load -pin_load 0.0500 [get_ports {mem_addr[0]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[15]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[14]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[13]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[12]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[11]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[10]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[9]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[8]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[7]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[6]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[5]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[4]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[3]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[2]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[1]}]
set_load -pin_load 0.0500 [get_ports {mem_wdata[0]}]
set_load -pin_load 0.0500 [get_ports {prdata[31]}]
set_load -pin_load 0.0500 [get_ports {prdata[30]}]
set_load -pin_load 0.0500 [get_ports {prdata[29]}]
set_load -pin_load 0.0500 [get_ports {prdata[28]}]
set_load -pin_load 0.0500 [get_ports {prdata[27]}]
set_load -pin_load 0.0500 [get_ports {prdata[26]}]
set_load -pin_load 0.0500 [get_ports {prdata[25]}]
set_load -pin_load 0.0500 [get_ports {prdata[24]}]
set_load -pin_load 0.0500 [get_ports {prdata[23]}]
set_load -pin_load 0.0500 [get_ports {prdata[22]}]
set_load -pin_load 0.0500 [get_ports {prdata[21]}]
set_load -pin_load 0.0500 [get_ports {prdata[20]}]
set_load -pin_load 0.0500 [get_ports {prdata[19]}]
set_load -pin_load 0.0500 [get_ports {prdata[18]}]
set_load -pin_load 0.0500 [get_ports {prdata[17]}]
set_load -pin_load 0.0500 [get_ports {prdata[16]}]
set_load -pin_load 0.0500 [get_ports {prdata[15]}]
set_load -pin_load 0.0500 [get_ports {prdata[14]}]
set_load -pin_load 0.0500 [get_ports {prdata[13]}]
set_load -pin_load 0.0500 [get_ports {prdata[12]}]
set_load -pin_load 0.0500 [get_ports {prdata[11]}]
set_load -pin_load 0.0500 [get_ports {prdata[10]}]
set_load -pin_load 0.0500 [get_ports {prdata[9]}]
set_load -pin_load 0.0500 [get_ports {prdata[8]}]
set_load -pin_load 0.0500 [get_ports {prdata[7]}]
set_load -pin_load 0.0500 [get_ports {prdata[6]}]
set_load -pin_load 0.0500 [get_ports {prdata[5]}]
set_load -pin_load 0.0500 [get_ports {prdata[4]}]
set_load -pin_load 0.0500 [get_ports {prdata[3]}]
set_load -pin_load 0.0500 [get_ports {prdata[2]}]
set_load -pin_load 0.0500 [get_ports {prdata[1]}]
set_load -pin_load 0.0500 [get_ports {prdata[0]}]
set_load -pin_load 0.0500 [get_ports {vid_b[4]}]
set_load -pin_load 0.0500 [get_ports {vid_b[3]}]
set_load -pin_load 0.0500 [get_ports {vid_b[2]}]
set_load -pin_load 0.0500 [get_ports {vid_b[1]}]
set_load -pin_load 0.0500 [get_ports {vid_b[0]}]
set_load -pin_load 0.0500 [get_ports {vid_g[4]}]
set_load -pin_load 0.0500 [get_ports {vid_g[3]}]
set_load -pin_load 0.0500 [get_ports {vid_g[2]}]
set_load -pin_load 0.0500 [get_ports {vid_g[1]}]
set_load -pin_load 0.0500 [get_ports {vid_g[0]}]
set_load -pin_load 0.0500 [get_ports {vid_r[4]}]
set_load -pin_load 0.0500 [get_ports {vid_r[3]}]
set_load -pin_load 0.0500 [get_ports {vid_r[2]}]
set_load -pin_load 0.0500 [get_ports {vid_r[1]}]
set_load -pin_load 0.0500 [get_ports {vid_r[0]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {clk}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_gnt}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_valid}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_ack}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_hreq}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {penable}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {psel}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwrite}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {rst_n}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[31]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[30]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[29]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[28]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[27]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[26]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[25]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[24]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[23]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[22]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[21]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[20]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[19]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[18]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[17]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[16]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[15]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[14]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[13]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[12]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[11]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[10]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[9]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[8]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[7]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[6]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[5]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[4]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[3]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[2]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[1]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {fb_burst_data[0]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[15]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[14]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[13]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[12]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[11]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[10]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[9]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[8]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[7]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[6]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[5]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[4]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[3]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[2]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[1]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {mem_rdata[0]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[7]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[6]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[5]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[4]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[3]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[2]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[1]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {paddr[0]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[31]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[30]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[29]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[28]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[27]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[26]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[25]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[24]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[23]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[22]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[21]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[20]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[19]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[18]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[17]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[16]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[15]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[14]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[13]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[12]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[11]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[10]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[9]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[8]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[7]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[6]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[5]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[4]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[3]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[2]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[1]}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4 -pin {Z} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {pwdata[0]}]
###############################################################################
# Design Rules
###############################################################################
set_max_transition 3.0000 [current_design]
set_max_fanout 24.0000 [current_design]
