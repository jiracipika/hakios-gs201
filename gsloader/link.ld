/* gsloader link script: position-independent ("anywhere" Image), .text.boot first. */
ENTRY(_start)
SECTIONS
{
  . = 0;
  .text : { KEEP(*(.text.boot)) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) *(.got .got.*) }
  .bss : { __bss_start = .; *(.bss .bss.*) *(COMMON); . = ALIGN(8); __bss_end = .; }
  /* payloads append after the image: this is where they must start (16-aligned,
     like mtkloader's CHAIN_OFFSET slack — never at the raw file end) */
  __loader_end = ALIGN(16);
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
