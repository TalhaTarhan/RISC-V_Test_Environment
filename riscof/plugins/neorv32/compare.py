import sys
import re

# Spike log'unu parse et (sadece 0x80000000+ adresleri)
def parse_spike(filename):
    entries = []
    with open(filename) as f:
        for line in f:
            # commit satırı: "core   0: 3 0x... (0x...) xN  0x..."
            m = re.match(r'core\s+0:\s+\d+\s+(0x[0-9a-f]+)\s+\(0x([0-9a-f]+)\)\s*(x\d+\s+0x[0-9a-f]+)?', line)
            if m:
                pc = m.group(1)
                instr = m.group(2)
                if int(pc, 16) >= 0x80000000:
                    entries.append((pc, instr))
    return entries

# GHDL trace'i parse et
def parse_ghdl(filename):
    entries = []
    with open(filename) as f:
        for line in f:
            m = re.match(r'core\s+0:\s+(0x[0-9a-f]+)\s+\(0x([0-9a-f]+)\)', line)
            if m:
                entries.append((m.group(1), m.group(2)))
    return entries

spike = parse_spike('spike_raw.log')
ghdl  = parse_ghdl('trace.log')

print(f"Spike: {len(spike)} instruction, GHDL: {len(ghdl)} instruction\n")

passed = 0
failed = 0
for i, (s, g) in enumerate(zip(spike, ghdl)):
    if s == g:
        passed += 1
    else:
        failed += 1
        print(f"[MISMATCH] #{i+1}")
        print(f"  Spike: PC={s[0]} INSTR={s[1]}")
        print(f"  GHDL:  PC={g[0]} INSTR={g[1]}")

print(f"\n{'='*40}")
print(f"PASSED: {passed}/{len(spike)}")
if failed == 0:
    print("✓ TÜM INSTRUCTIONLAR EŞLEŞİYOR!")
else:
    print(f"✗ {failed} UYUMSUZLUK VAR")
