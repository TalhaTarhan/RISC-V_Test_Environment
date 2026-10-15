#!/bin/bash
# riscv-dv + GHDL entegrasyon scripti

OUTPUT_DIR=$1
TB=/home/ahonat/Desktop/Deneme/tb_rv32i
RTL=/home/ahonat/Desktop/Deneme/rv32_top.vhd
TB_VHD=/home/ahonat/Desktop/Deneme/tb_rv32i.vhd
WORKDIR=/tmp/ghdl_work

mkdir -p $WORKDIR $OUTPUT_DIR/rtl_sim

# Derleme (bir kere yap)
cd $WORKDIR
ghdl -a --std=08 -frelaxed $RTL
ghdl -a --std=08 -frelaxed $TB_VHD
ghdl -e --std=08 -frelaxed tb_rv32i

# Her test için çalıştır
for ELF in $OUTPUT_DIR/asm_test/*.o; do
    TESTNAME=$(basename $ELF .o)
    echo "Running GHDL: $TESTNAME"

    # ELF → hex
    riscv32-unknown-elf-objcopy -O verilog $ELF /tmp/raw.hex
    python3 - << 'PYEOF'
with open('/tmp/raw.hex') as f:
    content = f.read()
bytes_list = []
for line in content.splitlines():
    if line.startswith('@'): continue
    bytes_list.extend(line.split())
with open('/tmp/test.hex', 'w') as f:
    for i in range(0, len(bytes_list), 4):
        chunk = bytes_list[i:i+4]
        while len(chunk) < 4:
            chunk.append('00')
        f.write(chunk[3]+chunk[2]+chunk[1]+chunk[0]+'\n')
PYEOF

    cp /tmp/test.hex $WORKDIR/test.hex

    # GHDL simülasyonu
    cd $WORKDIR
    ghdl -r --std=08 -frelaxed tb_rv32i --stop-time=50ms 2>/dev/null

    cp $WORKDIR/trace.log $OUTPUT_DIR/rtl_sim/${TESTNAME}.log
    echo "  → $OUTPUT_DIR/rtl_sim/${TESTNAME}.log ($(wc -l < $WORKDIR/trace.log) instructions)"
done

echo "GHDL simülasyonu tamamlandı."
