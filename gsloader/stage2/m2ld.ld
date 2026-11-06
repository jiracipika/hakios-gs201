/* m2ld.ld — raw blob at link base 0, spliced at the stock PE entry (AEP).
 * Everything in-image is addressed PC-relative (adr/adrp) at runtime; MMIO by
 * absolute constant. .bss occupies vehicle zeros past the blob (already zero). */
ENTRY(_start)
SECTIONS {
  . = 0;
  .text : {
    *(.text.boot)
    *(.text .text.*)
  }
  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.*) }
  .bss : {
    . = ALIGN(16);
    __bss_start = .;
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  }
  /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.eh_frame*) }
}
