# rvtest_entry.S  -  Reset/halt entry stub for RISCOF arch-tests
#
# Binary layout:
#   0x00  JAL x0, _start_real     jump over pointer block
#   0x04  NOP
#   0x08  .word begin_signature   patched by linker
#   0x0C  .word end_signature     patched by linker
#   0x10  _start_real:

    .section .text.init
    .globl _start
    .globl rvtest_entry_point

_start:
rvtest_entry_point:
    jal  x0, _start_real    # 0x00 (+16)
    nop                      # 0x04
    .word begin_signature    # 0x08
    .word end_signature      # 0x0C

_start_real:                 # 0x10
    la   sp, _stack_top
    la   t0, __bss_start
    la   t1, __bss_end
_bss_loop:
    bge  t0, t1, _bss_done
    sw   x0, 0(t0)
    addi t0, t0, 4
    j    _bss_loop
_bss_done:
    j    rvtest_code_begin

    .globl rvtest_halt
rvtest_halt:
    li   t0, 0xF0000000
    sw   x0, 0(t0)           # halt sentinel store
_halt_loop:
    j    _halt_loop

    .section .signature
    .globl begin_signature
    .globl end_signature
begin_signature:
    .word 0
end_signature:
