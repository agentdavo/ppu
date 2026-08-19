from pathlib import Path
import sys
import cocotb
from cocotb.triggers import RisingEdge
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from ppu_display_tb import bring_up, gradient_scene
import ppu_model as M

@cocotb.test()
async def probe(dut):
    mem, ppu, prog = gradient_scene()
    dut._log.info("prog words: " + " ".join(hex(mem.u32(prog+i*4)) for i in range(12)))
    await bring_up(dut, mem, list(ppu.pram), prog)
    lines = 0
    prev = 0
    while lines < 4:
        await RisingEdge(dut.clk)
        st = int(dut.u_cmd.state.value)
        if st == 3 and prev != 3:      # S_DEC
            dut._log.info(f"  y={int(dut.u_display.render_y.value):3} "
                          f"pc={int(dut.u_cmd.pc.value):#07x} op={int(dut.u_cmd.opcode.value):#x} "
                          f"insn={int(dut.u_cmd.insn.value):#010x} sp={int(dut.u_cmd.sp.value)}")
        if int(dut.line_done.value):
            lines += 1
            dut._log.info(f"--- line_done #{lines} ---")
        prev = st
