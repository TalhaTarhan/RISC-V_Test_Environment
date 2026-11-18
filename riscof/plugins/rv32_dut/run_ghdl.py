#!/usr/bin/env python3
import sys, os, subprocess, hashlib, shutil

elf  = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))   # folder containing this script
base = os.path.join(here, 'ghdl_work_dv')               # ghdl_work next to this script
os.makedirs(base, exist_ok=True)

# Her ELF için izole hex dizini
tag  = hashlib.md5(elf.encode()).hexdigest()[:8]
work = os.path.join(base, tag)
os.makedirs(work, exist_ok=True)

# tb_rv32i: derlenmiş çalıştırılabilir dosya ghdl_work içinde veya script ile aynı klasörde olabilir
exe = None
for cand in (os.path.join(base, 'tb_rv32i'), os.path.join(here, 'tb_rv32i')):
    if os.path.isfile(cand) and os.access(cand, os.X_OK):
        exe = cand
        break

# objcopy: RISCV_OBJCOPY, sonra ~/.local/riscv/bin, sonra PATH
objcopy = os.environ.get('RISCV_OBJCOPY')
if not objcopy:
    cand = os.path.expanduser('~/.local/riscv/bin/riscv32-unknown-elf-objcopy')
    if os.path.isfile(cand):
        objcopy = cand
    else:
        for n in ('riscv32-unknown-elf-objcopy', 'riscv-none-elf-objcopy',
                  'riscv64-unknown-elf-objcopy'):
            objcopy = shutil.which(n)
            if objcopy:
                break
if not objcopy:
    sys.exit('run_ghdl.py: no RISC-V objcopy found (set RISCV_OBJCOPY)')

# ELF → verilog hex
raw = os.path.join(work, 'raw.hex')
subprocess.run([objcopy, '-O', 'verilog', elf, raw], check=True)

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

# test.hex'i ghdl_work'e kopyala — simülasyon oradan okur
shutil.copy(hex_file, os.path.join(base, 'test.hex'))

# Eski trace.log kalmasın
trace = os.path.join(base, 'trace.log')
if os.path.exists(trace):
    os.remove(trace)

# Simülasyon — ghdl_work içinde çalıştır
os.chdir(base)
if exe:
    cmd = [exe, '--stop-time=500ms']
else:
    cmd = ['ghdl', '-r', '--std=08', '-frelaxed', 'tb_rv32i', '--stop-time=500ms']
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if res.stdout:
    sys.stderr.write(res.stdout)
if res.stderr:
    sys.stderr.write(res.stderr)
if res.returncode != 0:
    sys.stderr.write(f'run_ghdl.py: simulation exit code {res.returncode} ({" ".join(cmd)})\n')

# trace.log → stdout (run.py bunu &> ile log'a yönlendirir)
if os.path.exists(trace):
    with open(trace) as f:
        print(f.read(), end='')
else:
    sys.stderr.write('run_ghdl.py: trace.log was not produced by the simulation\n')
    sys.exit(1)
