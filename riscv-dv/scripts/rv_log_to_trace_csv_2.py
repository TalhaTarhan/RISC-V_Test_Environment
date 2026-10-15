import argparse
import os
import re
import sys
import logging

def reg_decode(reg):
    match reg:
        case 0:
            return "Zero"
        case 1:
            return "ra"
        case 2:
            return "sp"
        case 3:
            return "gp"
        case 4:
            return "tp"
        case 5 | 6 | 7:
            return "t" + str(reg - 5)
        case 8 | 9:
            return "s" + str(reg - 8)
        case 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17:
            return "a" + str(reg - 10)
        case 18 |19 | 20 | 21 | 22 | 23 | 24 | 25 | 26 | 27:
            return "s" + str(reg - 16)
        case 28 | 29 | 30 | 31:
            return "t" + str(reg - 25)

def opcode_decode(hexa):
    num1 = int(hexa, 16)
    mask = int("0x7F", 16)
    masked = num1 & mask
    match masked:
        case 55:
            return "lui"
        case 23:
            return "auipc"
        case 111:
            return "jal"
        case 103:
            return "jalr"
        case 99:
            return "branch"
        case 3:
            return "load"
        case 35:
            return "store"
        case 19:
            return "op-imm"
        case 51:
            return "op"
        case 15:
            return "fence"
        case 115:
            return "system"

def decode_lui(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_imm = int("0xFFFFF000", 16)
    rd = inst & mask_rd
    imm = inst & mask_imm
    rd = int(rd / 128)
    imm  = int(imm / 4096)
    rd = reg_decode(rd)
    return "lui " + rd + ", " + str(hex(imm))

def decode_auipc(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_imm = int("0xFFFFF000", 16)
    rd = inst & mask_rd
    imm = inst & mask_imm
    rd = int(rd / 128)
    imm  = int(imm / 4096)
    rd = reg_decode(rd)
    return "auipc " + rd + ", " + str(hex(imm))
    
def decode_jal(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_imm = int("0xFFFFF000", 16)
    rd = inst & mask_rd
    imm = inst & mask_imm
    rd = int(rd / 128)
    imm  = int(imm / 4096)
    if rd == 0:
        return "j " + str(hex(imm))
    rd = reg_decode(rd)
    return "jal " + rd + ", " + str(hex(imm))
            
def decode_jalr(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_rs1 = int("0xF8000", 16)
    mask_imm = int("0xFFF00000", 16)
    rd = inst & mask_rd
    rs1 = inst & mask_rs1
    imm = inst & mask_imm
    rd = int(rd / 128)
    rs1 = int(rs1 / 32768)
    imm = int(imm / 1048576)
    if rd == 0:
        if imm == 0:
            return "jr " + reg_decode(rs1)
        else:
            return "jalr " + reg_decode(rd) + ", " + reg_decode(rs1) + ", " + str(hex(imm))
    else:
        return "jalr " + reg_decode(rd) + ", " + reg_decode(rs1) + ", " + str(hex(imm))

def decode_branch(hexa):
    inst = int(hexa, 16)
    mask_imm1 = int("0x80000000" ,16)
    mask_imm2 = int("0x80" ,16)
    mask_imm3 = int("0x7E000000" ,16)
    mask_imm4 = int("0x780" ,16)
    mask_rs1 = int("0x7C000", 16)
    mask_rs2 = int("0x1F00000", 16)
    mask_funct3 = int("0x7000", 16)
    imm1 = int((inst & mask_imm1) / 1048576)
    imm2 = int((inst & mask_imm2) * 8)
    imm3 = int((inst & mask_imm3) / 2097152)
    imm4 = int((inst & mask_imm4) / 256)
    imm = imm1 + imm2 + imm3 + imm4
    rs1 = reg_decode(int((inst & mask_rs1) / 32768))
    rs2 = reg_decode(int((inst & mask_rs2) / 1048576))
    funct3 = int((inst & mask_funct3) / 4096)
    match funct3:
        case 0:
            return "beq " + rs1 + rs2 + str(hex(imm))
        case 1:
            return "bne " + rs1 + rs2 + str(hex(imm))
        case 4:
            return "blt " + rs1 + rs2 + str(hex(imm))
        case 5:
            return "bge " + rs1 + rs2 + str(hex(imm))
        case 6:
            return "bltu " + rs1 + rs2 + str(hex(imm))
        case 7:
            return "bgeu " + rs1 + rs2 + str(hex(imm))

def decode_branch(hexa):
    inst = int(hexa, 16)
    mask_imm1 = int("0x80000000", 16)
    mask_imm2 = int("0x80",16)
    mask_imm3 = int("0x7E000000", 16)
    mask_imm4 = int("0xF00", 16)
    mask_rs1 = int("0xF8000", 16)
    mask_rs2 = int("0x1F00000", 16)
    mask_funct3 = int("0x7000", 16)
    imm1 = int(int(inst & mask_imm1) / 1048576)
    imm2 = int(int(inst & mask_imm2) * 16)
    imm3 = int(int(inst & mask_imm3) / 2097152)
    imm4 = int(int(inst & mask_imm4) / 256)
    imm = (imm1 + imm2 + imm3 + imm4) * 2
    rs1 = reg_decode(int((inst & mask_rs1) / 32768))
    rs2 = int((inst & mask_rs2) / 1048576)
    funct3 = int((inst & mask_funct3) / 4096)
    match funct3:
        case 0:
            if rs2 == 0:
                return "beqz " + rs1 + ", pc + " + str(imm)
            else:
                return "beq " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)
        case 1:
            if rs2 == 0:
                return "bnez " + rs1 + ", pc + " + str(imm)
            else:
                return "bne " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)
        case 4:
            if rs2 == 0:
                return "bltz " + rs1 + ", pc + " + str(imm)
            else:
                return "blt " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)
        case 5:
            if rs2 == 0:
                return "bgez " + rs1 + ", pc + " + str(imm)
            else:
                return "bge " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)
        case 6:
            return "bltu " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)
        case 7:
            return "bgeu " + rs1 + ", " + reg_decode(rs2) + ", pc + " + str(imm)

def decode_load(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_funct3 = int("0x7000", 16)
    mask_rs1 = int("0xF8000", 16)
    mask_imm = int("0xFFF00000", 16)
    rd = reg_decode(int((inst & mask_rd) / 128))
    funct3 = int((inst & mask_funct3) / 4096)
    rs1 = reg_decode(int((inst & mask_rs1) / 32768))
    imm = int((inst & mask_imm) / 33554432)
    match funct3:
        case 0:
            return "lb " + rd + ", " + str(imm) + "(" + rs1 + ")"
        case 1:
            return "lh " + rd + ", " + str(imm) + "(" + rs1 + ")"
        case 2:
            return "lw " + rd + ", " + str(imm) + "(" + rs1 + ")"
        case 4:
            return "lbu " + rd + ", " + str(imm) + "(" + rs1 + ")"
        case 5:
            return "lhu " + rd + ", " + str(imm) + "(" + rs1 + ")"
            
def decode_store(hexa):
    inst = int(hexa, 16)
    mask_imm1 = int("0xF80", 16)
    mask_imm2 = int("0xFE000000", 16)
    mask_funct3 = int("0x7000", 16)
    mask_rs1 = int("0xF8000", 16)
    mask_rs2 = int("0x1F00000", 16)
    imm1 = int((inst & mask_imm1) / 128)
    imm2 = int((inst & mask_imm2) / 33554432)
    funct3 = int((inst & mask_funct3) / 4096)
    rs1 = int((inst & mask_rs1) / 32768)
    rs2 = int((inst & mask_rs2) / 1048576)
    match funct3:
        case 0:
            return "sb " + rs2 + ", " + str(imm) + "(" + rs1 + ")"
        case 1:
            return "sh " + rs2 + ", " + str(imm) + "(" + rs1 + ")"
        case 2:
            return "sw " + rs2 + ", " + str(imm) + "(" + rs1 + ")"
            
def decode_opimm(hexa):
    inst = int(hexa, 16)
    mask_rd = int("0xF80", 16)
    mask_funct3 = int("0x7000", 16)
    mask_rs1 = int("0xF8000", 16)
    mask_imm = int("0xFFF00000", 16)
    mask_shamt = int("0x1F00000", 16)
    rd = reg_decode(int((inst & mask_rd) >> 7))
    funct3 = int((inst & mask_funct3) >> 12)
    rs1 = reg_decode(int((inst & mask_rs1) >> 15))
    imm = int((inst & mask_imm) >> 20)
    shamt = int(inst & mask_shamt) >> 20)
    
    match funct3:
        case 0:
            return "addi " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 1:
            return "slti " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 2:
            return "sltiu " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 3:
            return "xori " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 4:
            return "ori " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 5:
            return "andi " rd + ", " + rs1 + ", " + str(hex(imm)) 
        case 6:
            return "slli " + rd + ", " + rs1 + ", " + shamt
        case 7:
            if (inst >> 30) == 1:
                return "srli " + rd + ", " + rs1 + ", " + shamt
            else:
                return "srai " + rd + ", " + rs1 + ", " + shamt
