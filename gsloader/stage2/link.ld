/* stage2: position-independent, one section. */
ENTRY(_start)
SECTIONS
{
  . = 0;
  .text : { KEEP(*(.text.boot)) *(.text .text.*) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
