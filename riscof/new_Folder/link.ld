/* link.ld  -  Linker script for RISCOF arch-tests on rv32_dut
 *
 * Binary layout required by tb_rv32_dut_riscof.vhd:
 *   offset 0x00 : JAL x0, _start_real
 *   offset 0x04 : NOP
 *   offset 0x08 : begin_signature address (LE32)
 *   offset 0x0C : end_signature   address (LE32)
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 1M }

SECTIONS
{
    .text.init 0x00000000 : { KEEP(*(.text.init)) } > RAM
    .text      :           { *(.text .text.*) *(.rodata .rodata.*) } > RAM

    .signature :
    {
        . = ALIGN(4);
        begin_signature = .;
        *(.signature)
        . = ALIGN(4);
        end_signature = .;
    } > RAM

    .data 0x00080000 : { *(.data .data.*) } > RAM

    .bss :
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
