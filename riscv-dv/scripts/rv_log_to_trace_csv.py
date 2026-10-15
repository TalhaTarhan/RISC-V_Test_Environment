#!/usr/bin/env python3
"""
RISC-V ISS trace (.log) -> .csv converter -- "kompakt" format için.

Bu script, önceki formattan (decode+commit iki ayrı satır, mnemonic dahil)
FARKLI, daha kompakt bir log formatı için yazılmıştır:

    core   0: 0x80000000 (0xf14022f3) x5=0x00000000
    core   0: 0x80000004 (0x00000313) x6=0x00000000
    core   0: 0x80000008 (0x00628263)
    ...

Yani her komut TEK satırda: "core X: 0xPC (0xBINARY) [xN=0xVAL]"
Bu formatta mnemonic (assembly metni) YOKTUR, sadece ham binary kod vardır.
Bu yüzden instr_str sütununu doldurmak için script kendi RV32I / RV32M /
Zicsr disassembler'ını kullanarak binary koddan mnemonic üretir.

Filtreleme mantığı ilk scriptle aynıdır:
  - 0x80000000 altındaki adresler (bootrom/init) yok sayılır
  - Sadece genel amaçlı registera (GPR, xN) yazan komutlar CSV'ye alınır
  - Testin "gövdesi" bittiğinde (ecall ile tuzağa düşüldüğünde) bu formatta
    tuzaklanan komut log'a hiç yazılmadığından (silent trap), bunun yerine
    PC akışında ANİ ve açıklanamayan bir sıçrama (bir sonraki adres,
    beklenen pc+4 değilse VE mevcut komut dallanma/atlama/sistem komutu
    değilse) tespit edilip orada durulur. Böylece testin gerçek gövdesi
    alınır, trap-handler / sonsuz döngü kuyruğu (dosyanın sonundaki
    milyonlarca tekrar satırı) csv'ye dahil edilmez.

Kullanım:
    python3 log_to_csv_v2.py girdi.log cikti.csv
    python3 log_to_csv_v2.py girdi.log cikti.csv --base-address 0x80000000
    python3 log_to_csv_v2.py girdi.log cikti.csv --no-stop-at-trap
"""

import re
import csv
import argparse

LINE_RE = re.compile(
    r'^core\s+(\d+):\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)(.*)$'
)
GPR_TOKEN_RE = re.compile(r'\bx(\d+)=0x([0-9a-fA-F]+)')

ABI_NAMES = {
    0: 'zero', 1: 'ra', 2: 'sp', 3: 'gp', 4: 'tp', 5: 't0', 6: 't1', 7: 't2',
    8: 's0', 9: 's1', 10: 'a0', 11: 'a1', 12: 'a2', 13: 'a3', 14: 'a4', 15: 'a5',
    16: 'a6', 17: 'a7', 18: 's2', 19: 's3', 20: 's4', 21: 's5', 22: 's6', 23: 's7',
    24: 's8', 25: 's9', 26: 's10', 27: 's11', 28: 't3', 29: 't4', 30: 't5', 31: 't6',
}

CSR_NAMES = {
    0x300: 'mstatus', 0x301: 'misa', 0x304: 'mie', 0x305: 'mtvec',
    0x306: 'mcounteren', 0x310: 'mstatush', 0x320: 'mcountinhibit',
    0x340: 'mscratch', 0x341: 'mepc', 0x342: 'mcause', 0x343: 'mtval',
    0x344: 'mip', 0x34a: 'mtinst', 0x34b: 'mtval2',
    0xf11: 'mvendorid', 0xf12: 'marchid', 0xf13: 'mimpid', 0xf14: 'mhartid',
    0xf15: 'mconfigptr',
    0xb00: 'mcycle', 0xb02: 'minstret', 0xb80: 'mcycleh', 0xb82: 'minstreth',
    0xc00: 'cycle', 0xc01: 'time', 0xc02: 'instret',
    0xc80: 'cycleh', 0xc81: 'timeh', 0xc82: 'instreth',
    0x180: 'satp', 0x302: 'medeleg', 0x303: 'mideleg',
    0x7a0: 'tselect', 0x7a1: 'tdata1', 0x7a2: 'tdata2', 0x7a3: 'tdata3',
    0x7b0: 'dcsr', 0x7b1: 'dpc',
}
for _i in range(16):
    CSR_NAMES[0x3a0 + _i] = f'pmpcfg{_i}' if _i < 4 else CSR_NAMES.get(0x3a0 + _i, f'0x{0x3a0+_i:03x}')
for _i in range(16):
    CSR_NAMES[0x3b0 + _i] = f'pmpaddr{_i}'

FIELDNAMES = ['pc', 'instr', 'gpr', 'csr', 'binary', 'mode', 'instr_str', 'operand', 'pad']


def reg(n):
    return ABI_NAMES.get(n, f'x{n}')


def csr_name(addr):
    return CSR_NAMES.get(addr, f'0x{addr:03x}')


def sign_extend(value, bits):
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def fmt(mnem, operand=''):
    if operand:
        return f'{mnem:<8}{operand}'
    return mnem


def decode_instr(binary):
    """binary -> (instr_str, is_controlflow)"""
    opcode = binary & 0x7f
    rd = (binary >> 7) & 0x1f
    funct3 = (binary >> 12) & 0x7
    rs1 = (binary >> 15) & 0x1f
    rs2 = (binary >> 20) & 0x1f
    funct7 = (binary >> 25) & 0x7f

    imm_i = sign_extend((binary >> 20) & 0xfff, 12)
    imm_s = sign_extend((((binary >> 25) & 0x7f) << 5) | ((binary >> 7) & 0x1f), 12)
    imm_b = sign_extend(
        (((binary >> 31) & 1) << 12) | (((binary >> 7) & 1) << 11) |
        (((binary >> 25) & 0x3f) << 5) | (((binary >> 8) & 0xf) << 1), 13)
    imm_u20 = (binary >> 12) & 0xfffff
    imm_j = sign_extend(
        (((binary >> 31) & 1) << 20) | (((binary >> 12) & 0xff) << 12) |
        (((binary >> 20) & 1) << 11) | (((binary >> 21) & 0x3ff) << 1), 21)
    csr = (binary >> 20) & 0xfff

    def pc_off(imm, as_hex=False):
        sign = '+' if imm >= 0 else '-'
        val = abs(imm)
        return f'pc {sign} {"0x%x" % val if as_hex else val}'

    # LUI
    if opcode == 0b0110111:
        return fmt('lui', f'{reg(rd)}, 0x{imm_u20:x}'), False
    # AUIPC
    if opcode == 0b0010111:
        return fmt('auipc', f'{reg(rd)}, 0x{imm_u20:x}'), False
    # JAL
    if opcode == 0b1101111:
        if rd == 0:
            return fmt('j', pc_off(imm_j, as_hex=True)), True
        if rd == 1:
            return fmt('jal', pc_off(imm_j, as_hex=True)), True
        return fmt('jal', f'{reg(rd)}, {pc_off(imm_j, as_hex=True)}'), True
    # JALR
    if opcode == 0b1100111 and funct3 == 0:
        if rd == 0 and rs1 == 1 and imm_i == 0:
            return fmt('ret'), True
        if rd == 0 and imm_i == 0:
            return fmt('jr', reg(rs1)), True
        if rd == 1 and imm_i == 0:
            return fmt('jalr', reg(rs1)), True
        return fmt('jalr', f'{reg(rd)}, {imm_i}({reg(rs1)})'), True
    # BRANCH
    if opcode == 0b1100011:
        bmap = {0: 'beq', 1: 'bne', 4: 'blt', 5: 'bge', 6: 'bltu', 7: 'bgeu'}
        mnem = bmap.get(funct3)
        if mnem:
            return fmt(mnem, f'{reg(rs1)}, {reg(rs2)}, {pc_off(imm_b)}'), True
        return fmt('b?', f'0x{binary:08x}'), True
    # LOAD
    if opcode == 0b0000011:
        lmap = {0: 'lb', 1: 'lh', 2: 'lw', 4: 'lbu', 5: 'lhu'}
        mnem = lmap.get(funct3)
        if mnem:
            return fmt(mnem, f'{reg(rd)}, {imm_i}({reg(rs1)})'), False
        return fmt('l?', f'0x{binary:08x}'), False
    # STORE
    if opcode == 0b0100011:
        smap = {0: 'sb', 1: 'sh', 2: 'sw'}
        mnem = smap.get(funct3)
        if mnem:
            return fmt(mnem, f'{reg(rs2)}, {imm_s}({reg(rs1)})'), False
        return fmt('s?', f'0x{binary:08x}'), False
    # OP-IMM
    if opcode == 0b0010011:
        shamt = rs2  # imm[4:0] for shift variants
        if funct3 == 0:  # ADDI
            if rd == 0 and rs1 == 0 and imm_i == 0:
                return fmt('nop'), False
            if rs1 == 0:
                return fmt('li', f'{reg(rd)}, {imm_i}'), False
            return fmt('addi', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 2:
            return fmt('slti', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 3:
            if rs1 == 0:
                return fmt('seqz', f'{reg(rd)}, {reg(rs1)}'), False
            return fmt('sltiu', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 4:
            return fmt('xori', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 6:
            return fmt('ori', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 7:
            return fmt('andi', f'{reg(rd)}, {reg(rs1)}, {imm_i}'), False
        if funct3 == 1 and funct7 == 0x00:
            return fmt('slli', f'{reg(rd)}, {reg(rs1)}, {shamt}'), False
        if funct3 == 5 and funct7 == 0x00:
            return fmt('srli', f'{reg(rd)}, {reg(rs1)}, {shamt}'), False
        if funct3 == 5 and funct7 == 0x20:
            return fmt('srai', f'{reg(rd)}, {reg(rs1)}, {shamt}'), False
        return fmt('op-imm?', f'0x{binary:08x}'), False
    # OP (register-register)
    if opcode == 0b0110011:
        if funct7 == 0x00:
            rmap = {0: 'add', 1: 'sll', 2: 'slt', 3: 'sltu', 4: 'xor', 5: 'srl', 6: 'or', 7: 'and'}
            mnem = rmap.get(funct3)
        elif funct7 == 0x20:
            rmap = {0: 'sub', 5: 'sra'}
            mnem = rmap.get(funct3)
        elif funct7 == 0x01:
            rmap = {0: 'mul', 1: 'mulh', 2: 'mulhsu', 3: 'mulhu', 4: 'div', 5: 'divu', 6: 'rem', 7: 'remu'}
            mnem = rmap.get(funct3)
        else:
            mnem = None
        if mnem:
            return fmt(mnem, f'{reg(rd)}, {reg(rs1)}, {reg(rs2)}'), False
        return fmt('op?', f'0x{binary:08x}'), False
    # FENCE
    if opcode == 0b0001111:
        if funct3 == 1:
            return fmt('fence.i'), False
        return fmt('fence'), False
    # SYSTEM
    if opcode == 0b1110011:
        if funct3 == 0:
            imm12 = (binary >> 20) & 0xfff
            if imm12 == 0:
                return fmt('ecall'), True
            if imm12 == 1:
                return fmt('ebreak'), True
            if imm12 == 0x302:
                return fmt('mret'), True
            if imm12 == 0x102:
                return fmt('sret'), True
            if imm12 == 0x105:
                return fmt('wfi'), True
            if (imm12 >> 5) == 0x09:
                return fmt('sfence.vma', f'{reg(rs1)}, {reg(rs2)}'), False
            return fmt('system?', f'0x{binary:08x}'), True
        name = csr_name(csr)
        if funct3 in (1, 2, 3):  # csrrw/csrrs/csrrc (register)
            mnem = {1: 'csrrw', 2: 'csrrs', 3: 'csrrc'}[funct3]
            if mnem == 'csrrw' and rd == 0:
                return fmt('csrw', f'{name}, {reg(rs1)}'), False
            if mnem == 'csrrs' and rs1 == 0:
                return fmt('csrr', f'{reg(rd)}, {name}'), False
            if mnem == 'csrrs' and rd == 0:
                return fmt('csrs', f'{name}, {reg(rs1)}'), False
            if mnem == 'csrrc' and rd == 0:
                return fmt('csrc', f'{name}, {reg(rs1)}'), False
            return fmt(mnem, f'{reg(rd)}, {name}, {reg(rs1)}'), False
        else:  # csrrwi/csrrsi/csrrci (immediate, rs1 field = zimm)
            mnem = {5: 'csrrwi', 6: 'csrrsi', 7: 'csrrci'}[funct3]
            zimm = rs1
            if rd == 0:
                short = {'csrrwi': 'csrwi', 'csrrsi': 'csrsi', 'csrrci': 'csrci'}[mnem]
                return fmt(short, f'{name}, {zimm}'), False
            return fmt(mnem, f'{reg(rd)}, {name}, {zimm}'), False

    return fmt('unknown', f'0x{binary:08x}'), False


def parse_log(path, base_address=0x80000000, stop_at_trap=True, boot_skip=1):
    """
    boot_skip: Test programinin en basinda (mtvec/mepc/mstatus kurulumunun
    ardindan) HER ZAMAN bir adet "sessiz" PC sicramasi olusur -- bu, o ana
    kadar loglanmayan bir 'mret' komutunun devreye girmesiyle olur ve testin
    gercek govdesine donen normal bir gecistir; DURMUYORUZ, sadece sayiyoruz.

    Govde calisirken bir DAHA sessiz sicrama gorursek (hedef adres ne
    olursa olsun), bu artik testin bitis sinyali olan 'ecall' komutunun
    (loglanmadan) tetikledigi trap'tir -- TAM burada duruyoruz ve spike
    referans CSV'siyle satir hizasi tutsun diye bir 'ecall' placeholder
    satiri ekliyoruz.

    NOT: Onceki surumde "mtvec CSR'a yazilan degeri izleyip, PC tam o
    adrese siçradiginda dur" seklinde bir yontem kullaniliyordu. Bu yontem,
    vectored-mode mtvec biti / farkli trap-dispatch semalari yuzunden
    gercek sicrama hedefini yanlis tahmin edebildigi icin bazi testlerde
    HIC tetiklenmiyordu (sonsuz dongu CSV'ye dahil oluyordu). Bu sayac
    tabanli yontem hedef adresi hic tahmin etmeye calismadigi icin
    çok daha saglam.
    """
    rows = []
    prev = {}  # core -> (pc, is_controlflow)
    disc_count = {}  # core -> kac sessiz sicrama gorduk

    with open(path, 'r', errors='ignore') as f:
        for raw_line in f:
            line = raw_line.rstrip('\n')
            m = LINE_RE.match(line)
            if not m:
                continue
            core, pc_hex, bin_hex, rest = m.groups()
            pc_val = int(pc_hex, 16)
            binary = int(bin_hex, 16)

            instr_str, is_cf = decode_instr(binary)

            stopped = False
            if stop_at_trap and core in prev:
                prev_pc, prev_cf = prev[core]
                if not prev_cf and pc_val != prev_pc + 4:
                    disc_count[core] = disc_count.get(core, 0) + 1
                    if disc_count[core] > boot_skip:
                        # Gercek test-sonu trap'i: loglanmayan komutun
                        # adresi = prev_pc + 4 (standart 4 bayt komut varsayimi)
                        rows.append({
                            'pc': f'{prev_pc + 4:08x}',
                            'instr': '',
                            'gpr': '',
                            'csr': '',
                            'binary': '00000073',
                            'mode': '',
                            'instr_str': 'ecall',
                            'operand': '',
                            'pad': '',
                        })
                        stopped = True

            if stopped:
                break

            prev[core] = (pc_val, is_cf)

            gpr_field = ''
            m_gpr = GPR_TOKEN_RE.search(rest)
            if m_gpr:
                regnum = int(m_gpr.group(1))
                val = m_gpr.group(2)
                gpr_field = f'{reg(regnum)}:{val.lower().zfill(8)}'

            if pc_val >= base_address and gpr_field:
                rows.append({
                    'pc': pc_hex.lower().zfill(8),
                    'instr': '',
                    'gpr': gpr_field,
                    'csr': '',
                    'binary': bin_hex.lower().zfill(8),
                    'mode': '3',
                    'instr_str': instr_str,
                    'operand': '',
                    'pad': '',
                })

    return rows


def write_csv(rows, out_path):
    with open(out_path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES, quoting=csv.QUOTE_MINIMAL)
        writer.writeheader()
        for r in rows:
            writer.writerow(r)


def main():
    ap = argparse.ArgumentParser(description='Kompakt RISC-V log (.log) -> .csv çevirici')
    ap.add_argument('log_file', help='Girdi .log dosyası')
    ap.add_argument('csv_file', help='Çıktı .csv dosyası')
    ap.add_argument('--base-address', type=lambda x: int(x, 0), default=0x80000000,
                     help='Bu adresin altındaki komutlar yok sayılır (varsayılan: 0x80000000)')
    ap.add_argument('--no-stop-at-trap', action='store_true',
                     help='Sessiz trap tespitinde durmayı devre dışı bırak (tüm dosyayı işle)')
    ap.add_argument('--boot-skip', type=int, default=1,
                     help='Test başındaki kaç "sessiz" PC sıçraması (örn. boot mret) normal '
                          'sayılıp atlanacak; bundan sonraki ilk sıçrama test sonu (ecall) '
                          'kabul edilir (varsayılan: 1)')
    args = ap.parse_args()

    rows = parse_log(
        args.log_file,
        base_address=args.base_address,
        stop_at_trap=not args.no_stop_at_trap,
        boot_skip=args.boot_skip,
    )
    write_csv(rows, args.csv_file)
    print(f'{len(rows)} satır yazıldı -> {args.csv_file}')


def process_rv_sim_log(log, csv):
    rows = parse_log(log)
    write_csv(rows, csv)
  
if __name__ == '__main__':
    main()
