# Provenance

Views in this repository were produced by:

    librelane --condensed ip/ppu/librelane/config.yaml \
              --pdk gf180mcuD --pdk-root gf180mcu --manual-pdk \
              --scl gf180mcu_fd_sc_mcu7t5v0 --skip Magic.DRC \
              --save-views-to ip/ppu/macro

LibreLane run: RUN_2026-08-18_23-14-37
Source commit: 77722c07-dirty

WARNING: the source tree had uncommitted changes when these views
were published, so the commit above does NOT fully describe the
RTL they were built from. Modified or untracked under ip/ppu:

     M ip/ppu/librelane/config.yaml
     M ip/ppu/model/ppu_model.py
     M ip/ppu/rtl/ppu_blend.v
     M ip/ppu/rtl/ppu_cmd.v
     M ip/ppu/rtl/ppu_defs.vh
     M ip/ppu/rtl/ppu_top.v
     M ip/ppu/tb/ppu_tb.py
     M ip/ppu/tb/ppu_throughput_probe.py
    ?? ip/ppu/ppu_model.py
    ?? ip/ppu/ppu_throughput_probe.py
Published:     2026-08-19T00:01:31Z
