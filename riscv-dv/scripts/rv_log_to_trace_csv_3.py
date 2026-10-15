#!/usr/bin/env python3
"""
rv_log_to_csv.py — GHDL "rv" ISS trace log -> riscv-dv style trace CSV

Girdi format (run_ghdl.py çıktısı, Spike benzeri):
    core   0: 3 0x80000000 (0xf14022f3) x5  0x00000000
    core   0: 3 0x80000008 (0x00628263)

Çıktı: pc,instr,gpr,csr,binary,mode,instr_str,operand,pad
"""
import sys
import re
import csv

# ---------------------------------------------------------------------------
# ABI register isimleri
# ---------------------------------------------------------------------------
ABI = ["zero","ra","sp","gp","tp","t0","t1","t2","s0","s1",
       "a0","a1","a2","a3","a4","a5","a6","a7","s2","s3",
       "s4","s5","s6","s7","s8","s9","s10","s11","t3","t4","t5","t6"]

CSR_NAMES = {
    0x300: "mstatus", 0x301: "misa", 0x304: "mie", 0x305: "mtvec",
    0x340: "mscratch", 0x341: "mepc", 0x342: "mcause", 0x343: "mtval",
    0x344: "mip", 0xF11: "mvendorid", 0xF12: "marchid",
    0xF13: "mimpid", 0xF14: "mhartid",
}

def sext(val, bits):
    if val & (1 << (bits - 1)):
        val -= (1 << bits)
    return val

def rname(idx):
    return ABI[idx]

# ---------------------------------------------------------------------------
# RV32I + Zicsr disassembler
# rd_val: eğer instruction rd'ye yazdıysa (trace'ten gelen) değeri; None ise yok
# Dönüş: (mnemonic_string, gpr_field, csr_field)
# ---------------------------------------------------------------------------
def disasm(pc, instr, rd_written, rd_val):
    opcode = instr & 0x7f
    rd     = (instr >> 7)  & 0x1f
    funct3 = (instr >> 12) & 0x7
    rs1    = (instr >> 15) & 0x1f
    rs2    = (instr >> 20) & 0x1f
    funct7 = (instr >> 25) & 0x7f

    imm_i = sext((instr >> 20) & 0xfff, 12)
    imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1f), 12)
    imm_b = sext(
        (((instr >> 31) & 1) << 12) |
        (((instr >> 7)  & 1) << 11) |
        (((instr >> 25) & 0x3f) << 5) |
        (((instr >> 8)  & 0xf) << 1), 13)
    imm_u = instr & 0xfffff000
    imm_j = sext(
        (((instr >> 31) & 1) << 20) |
        (((instr >> 12) & 0xff) << 12) |
        (((instr >> 20) & 1) << 11) |
        (((instr >> 21) & 0x3ff) << 1), 21)
    shamt = rs2  # I-type shift, rv32: shamt = imm[4:0] = rs2 field
    csr_addr = (instr >> 20) & 0xfff

    gpr_field = ""
    csr_field = ""
    mnem = "unknown"

    def gwrite():
        nonlocal gpr_field
        if rd != 0 and rd_written:
            gpr_field = f"{rname(rd)}:{rd_val & 0xffffffff:08x}"

    # -----------------------------------------------------------------
    if opcode == 0x37:  # LUI
        mnem = f"lui     {rname(rd)}, 0x{(imm_u >> 12) & 0xfffff:x}"
        gwrite()

    elif opcode == 0x17:  # AUIPC
        mnem = f"auipc   {rname(rd)}, 0x{(imm_u >> 12) & 0xfffff:x}"
        gwrite()

    elif opcode == 0x6f:  # JAL
        target = (pc + imm_j) & 0xffffffff
        if rd == 0:
            mnem = f"j       pc {'+' if imm_j>=0 else '-'} 0x{abs(imm_j):x}"
        else:
            mnem = f"jal     {rname(rd)}, pc {'+' if imm_j>=0 else '-'} 0x{abs(imm_j):x}"
        gwrite()

    elif opcode == 0x67:  # JALR
        if rd == 0 and imm_i == 0:
            mnem = f"jr      {rname(rs1)}"
        elif rd == 1:
            mnem = f"jalr    {rname(rs1)}, {imm_i}" if imm_i else f"jalr    {rname(rs1)}"
        else:
            mnem = f"jalr    {rname(rd)}, {rname(rs1)}, {imm_i}"
        gwrite()

    elif opcode == 0x63:  # Branch
        names = {0:"beq",1:"bne",4:"blt",5:"bge",6:"bltu",7:"bgeu"}
        m = names.get(funct3, "b??")
        mnem = f"{m:<7} {rname(rs1)}, {rname(rs2)}, pc {'+' if imm_b>=0 else '-'} 0x{abs(imm_b):x}"

    elif opcode == 0x03:  # Load
        names = {0:"lb",1:"lh",2:"lw",4:"lbu",5:"lhu"}
        m = names.get(funct3, "l??")
        mnem = f"{m:<7} {rname(rd)}, {imm_i}({rname(rs1)})"
        gwrite()

    elif opcode == 0x23:  # Store
        names = {0:"sb",1:"sh",2:"sw"}
        m = names.get(funct3, "s??")
        mnem = f"{m:<7} {rname(rs2)}, {imm_s}({rname(rs1)})"

    elif opcode == 0x13:  # ALU imm
        if funct3 == 0:  # ADDI
            if rd == 0 and rs1 == 0 and imm_i == 0:
                mnem = "nop"
            elif rs1 == 0:
                mnem = f"li      {rname(rd)}, {imm_i}"
            elif imm_i == 0:
                mnem = f"mv      {rname(rd)}, {rname(rs1)}"
            else:
                mnem = f"addi    {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 2:
            mnem = f"slti    {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 3:
            mnem = f"sltiu   {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 4:
            mnem = f"xori    {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 6:
            mnem = f"ori     {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 7:
            mnem = f"andi    {rname(rd)}, {rname(rs1)}, {imm_i}"
        elif funct3 == 1:
            mnem = f"slli    {rname(rd)}, {rname(rs1)}, {shamt}"
        elif funct3 == 5:
            if funct7 == 0x20:
                mnem = f"srai    {rname(rd)}, {rname(rs1)}, {shamt}"
            else:
                mnem = f"srli    {rname(rd)}, {rname(rs1)}, {shamt}"
        gwrite()

    elif opcode == 0x33:  # ALU reg
        if funct3 == 0:
            mnem = f"sub     {rname(rd)}, {rname(rs1)}, {rname(rs2)}" if funct7 == 0x20 \
                   else f"add     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 1:
            mnem = f"sll     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 2:
            mnem = f"slt     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 3:
            mnem = f"sltu    {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 4:
            mnem = f"xor     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 5:
            mnem = f"sra     {rname(rd)}, {rname(rs1)}, {rname(rs2)}" if funct7 == 0x20 \
                   else f"srl     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 6:
            mnem = f"or      {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 7:
            mnem = f"and     {rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        gwrite()

    elif opcode == 0x73:  # SYSTEM (ECALL/EBREAK/CSR*)
        if instr == 0x00000073:
            mnem = "ecall"
        elif instr == 0x00100073:
            mnem = "ebreak"
        elif instr == 0x30200073:
            mnem = "mret"
        else:
            csr_name = CSR_NAMES.get(csr_addr, f"0x{csr_addr:03x}")
            if funct3 == 1:    # CSRRW
                if rd == 0:
                    mnem = f"csrw    {csr_name}, {rname(rs1)}"
                else:
                    mnem = f"csrrw   {rname(rd)}, {csr_name}, {rname(rs1)}"
            elif funct3 == 2:  # CSRRS
                if rs1 == 0:
                    mnem = f"csrr    {rname(rd)}, {csr_name}"
                else:
                    mnem = f"csrrs   {rname(rd)}, {csr_name}, {rname(rs1)}"
            elif funct3 == 3:  # CSRRC
                mnem = f"csrrc   {rname(rd)}, {csr_name}, {rname(rs1)}"
            elif funct3 == 5:  # CSRRWI
                mnem = f"csrwi   {csr_name}, {rs1}" if rd == 0 else f"csrrwi  {rname(rd)}, {csr_name}, {rs1}"
            elif funct3 == 6:  # CSRRSI
                mnem = f"csrrsi  {rname(rd)}, {csr_name}, {rs1}"
            elif funct3 == 7:  # CSRRCI
                mnem = f"csrrci  {rname(rd)}, {csr_name}, {rs1}"
            gwrite()
    else:
        mnem = f"unknown 0x{instr:08x}"

    return mnem, gpr_field, csr_field


# ---------------------------------------------------------------------------
# Trace parse
# ---------------------------------------------------------------------------
LINE_RE = re.compile(
    r'core\s+0:\s+3\s+(0x[0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)'
    r'(?:\s+x(\d+)\s+(0x[0-9a-fA-F]+))?'
)

def convert(in_path, out_path):
    rows = []
    with open(in_path) as f:
        for line in f:
            m = LINE_RE.match(line.strip())
            if not m:
                continue
            pc      = int(m.group(1), 16)
            instr   = int(m.group(2), 16)
            rd_str  = m.group(3)
            val_str = m.group(4)

            rd_written = rd_str is not None
            rd_val = int(val_str, 16) if val_str else 0

            mnem, gpr_field, csr_field = disasm(pc, instr, rd_written, rd_val)

            rows.append({
                "pc": f"{pc:08x}",
                "instr": "",
                "gpr": gpr_field,
                "csr": csr_field,
                "binary": f"{instr:08x}",
                "mode": "3",
                "instr_str": mnem,
                "operand": "",
                "pad": "",
            })

    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "pc","instr","gpr","csr","binary","mode","instr_str","operand","pad"
        ])
        w.writeheader()
        w.writerows(rows)

    print(f"{len(rows)} satır yazıldı -> {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Kullanım: {sys.argv[0]} <giris_trace.log> <cikis.csv>")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
