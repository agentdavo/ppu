#!/usr/bin/env bash
# Paint double-buffer demo frames, write BMPs, optional freestanding tcc + netload.
set -euo pipefail
PPU="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$PPU/../.." && pwd)"
OUT="${OUT:-$PPU/reports}"
mkdir -p "$OUT"

echo "=== 1) Host: paint + BMP + pixel checks (800×600 RGB565) ==="
gcc -O2 -Wall -Wextra -I"$PPU/sw" \
  -o "$OUT/host_fb_bmp" \
  "$PPU/sw/host_fb_bmp.c" "$PPU/sw/fb_draw.c"
(cd "$PPU" && "$OUT/host_fb_bmp" "$OUT")
ls -la "$OUT/fb_frame0.bmp" "$OUT/fb_frame1.bmp"

TCC="${TCC:-$REPO/transputer-tcc}"
NETLOAD="${NETLOAD:-$REPO/transputer-netload}"
if [[ "${SKIP_TCC:-0}" != "1" && -x "$TCC" ]]; then
  echo "=== 2) Freestanding tcc object (no link if crt missing) ==="
  # Compile only: freestanding SoC image may need board crt0; still validate C.
  set +e
  "$TCC" -nostdlib -nostdinc -I"$PPU/sw" -DPPU_FREESTANDING \
    -c -o "$OUT/fb_draw.o" "$PPU/sw/fb_draw.c" 2>"$OUT/tcc_fb_draw.log"
  r1=$?
  "$TCC" -nostdlib -nostdinc -I"$PPU/sw" -DPPU_FREESTANDING \
    -c -o "$OUT/ppu_fb_demo.o" "$PPU/sw/ppu_fb_demo.c" 2>"$OUT/tcc_demo.log"
  r2=$?
  set -e
  if [[ $r1 -eq 0 && $r2 -eq 0 ]]; then
    echo "tcc freestanding objects ok: $OUT/fb_draw.o $OUT/ppu_fb_demo.o"
    echo "NOTE: full -nostdlib link needs board crt0 + link script; objects are enough for netload pipeline later"
  else
    echo "NOTE: tcc freestanding compile issues (see $OUT/tcc_*.log) — host BMP path is authoritative"
    tail -20 "$OUT/tcc_demo.log" 2>/dev/null || true
  fi
else
  echo "SKIP tcc (set TCC= or SKIP_TCC=0)"
fi

echo "=== fb demo: host path green ==="
echo "  BMPs: $OUT/fb_frame0.bmp  $OUT/fb_frame1.bmp"
echo "  Map:  FB0=0x81000000 FB1=0x81100000 PPU=0x10001000 (see ppu_memmap.h)"
