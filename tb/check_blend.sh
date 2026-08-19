#!/usr/bin/env bash
# Exhaustive proof that ppu_blend matches the golden model, bit for bit.
# All 131072 (mode, src, dst, alpha) combinations. Signoff gate G12, in part.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
iverilog -g2005 -I rtl -o "$T/tb" tb/tb_blend_exhaustive.v rtl/ppu_blend.v
"$T/tb" | grep -E '^[0-9]' > "$T/rtl.txt"
python3 - > "$T/model.txt" <<'PY'
import sys; sys.path.insert(0, 'model')
from ppu_model import blend_alpha, blend_add, blend_sub, blend_mul
fn = {1: blend_alpha, 2: blend_add, 3: blend_sub, 4: blend_mul}
for m in range(1, 5):
    for s in range(32):
        for d in range(32):
            for a in range(32):
                print(m, s, d, a, fn[m](s, d, a))
PY
if diff -q "$T/rtl.txt" "$T/model.txt" >/dev/null; then
    echo "PASS: RTL matches golden model across $(wc -l < "$T/rtl.txt") combinations"
else
    echo "FAIL: RTL and golden model diverge"; diff "$T/rtl.txt" "$T/model.txt" | head; exit 1
fi
