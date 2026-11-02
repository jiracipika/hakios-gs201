/* gsloader link script: position-independent ("anywhere" Image), .text.boot first. */
ENTRY(_start)
SECTIONS
{
  . = 0;
  .text : { KEEP(*(.text.boot)) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) *(.got .got.*) }
  .bss : { __bss_start = .; *(.bss .bss.*) *(COMMON); __bss_end = .; }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
