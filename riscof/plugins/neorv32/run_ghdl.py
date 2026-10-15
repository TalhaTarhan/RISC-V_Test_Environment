#!/usr/bin/env python3
import sys, os, subprocess, hashlib, shutil

elf  = sys.argv[1]
base = '/home/ahonat/Desktop/Deneme/ghdl_work'

# Her ELF için izole hex dizini
tag  = hashlib.md5(elf.encode()).hexdigest()[:8]
work = os.path.join(base, tag)
os.makedirs(work, exist_ok=True)

# tb_rv32i symlink
exe  = os.path.join(base, 'tb_rv32i')
link = os.path.join(work, 'tb_rv32i')
if not os.path.exists(link) and not os.path.islink(link):
    os.symlink(exe, link)

# ELF → verilog hex
raw = os.path.join(work, 'raw.hex')
subprocess.run([
    '/home/ahonat/.local/riscv/bin/riscv32-unknown-elf-objcopy',
    '-O', 'verilog', elf, raw], check=True)

# Verilog hex → word hex
BASE = 0x80000000
MEM_WORDS = 65536
mem = ['00'] * (MEM_WORDS * 4)
with open(raw) as f:
    cur_addr = 0
    for line in f:
        line = line.strip()
        if line.startswith('@'):
            cur_addr = int(line[1:], 16)
        else:
            for b in line.split():
                offset = cur_addr - BASE
                if 0 <= offset < MEM_WORDS * 4:
                    mem[offset] = b
                cur_addr += 1

last = 0
for i in range(0, MEM_WORDS * 4, 4):
    if any(mem[i+j] != '00' for j in range(4)):
        last = i

hex_file = os.path.join(work, 'test.hex')
with open(hex_file, 'w') as f:
    for i in range(0, last + 4, 4):
        f.write(f'{mem[i+3]}{mem[i+2]}{mem[i+1]}{mem[i+0]}\n')

# test.hex'i ana dizine kopyala — GHDL oradan okur
shutil.copy(hex_file, os.path.join(base, 'test.hex'))

# GHDL simülasyonu — ana dizinde çalıştır
os.chdir(base)
subprocess.run([
    'ghdl', '-r', '--std=08', '-frelaxed', 'tb_rv32i',
    '--stop-time=500ms'
], stderr=subprocess.DEVNULL)

# trace.log → stdout (run.py bunu &> ile log'a yönlendirir)
trace = os.path.join(base, 'trace.log')
if os.path.exists(trace):
    with open(trace) as f:
        print(f.read(), end='')
