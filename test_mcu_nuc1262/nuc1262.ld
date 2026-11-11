/* Linker script for NUC1262 (128KB Flash, 20KB SRAM) */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 0x20000   /* 128k */
  RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 0x5000    /*  20k */
}

GROUP(libgcc.a libc.a libm.a libnosys.a)

ENTRY(Reset_Handler)

SECTIONS
{
	.vectors :
	{
		KEEP(*(.vectors))
		__Vectors_End = .;
		__Vectors_Size = __Vectors_End - __Vectors;
		KEEP(*(.vector_load_anchor))
	} > FLASH
	.compat_edid : { KEEP(*(.compat_edid)) } > FLASH
	ASSERT(. <= 0x204, "vectors/EDID overlap legacy reset compatibility slot")
	.legacy_reset_compat 0x204 : { KEEP(*(.legacy_reset_compat)) } > FLASH
	ASSERT(SIZEOF(.legacy_reset_compat) == 0x1c, "legacy reset shim must remain 28 bytes")
	.text 0x220 :
	{
		__end__ = .;
		*(.text*)

		KEEP(*(.init))
		KEEP(*(.fini))

		*(.rodata*)
		KEEP(*(.fw_identity))
		KEEP(*(.eh_frame*))
	} > FLASH

	.ARM.extab :
	{
		*(.ARM.extab* .gnu.linkonce.armextab.*)
	} > FLASH

	__exidx_start = .;
	.ARM.exidx :
	{
		*(.ARM.exidx* .gnu.linkonce.armexidx.*)
	} > FLASH
	__exidx_end = .;

	__etext = .;

	.data : AT (__etext)
	{
		__data_start__ = .;
		*(vtable)
		*(.data*)
		__ramfunc_start__ = .;
		*(.ramfunc*)
		__ramfunc_end__ = .;

		. = ALIGN(4);
		PROVIDE_HIDDEN (__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN (__preinit_array_end = .);

		. = ALIGN(4);
		PROVIDE_HIDDEN (__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN (__init_array_end = .);

		. = ALIGN(4);
		PROVIDE_HIDDEN (__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN (__fini_array_end = .);

		. = ALIGN(4);
		__data_end__ = .;
	} > RAM

	.bss :
	{
		. = ALIGN(4);
		__bss_start__ = .;
		*(.bss*)
		*(COMMON)
		. = ALIGN(4);
		__bss_end__ = .;
	} > RAM

	.heap (COPY):
	{
		__HeapBase = .;
		__end__ = .;
		end = __end__;
		_end = __end__;
		KEEP(*(.heap*))
		__HeapLimit = .;
	} > RAM

	.upgrade_stage 0x20001000 (NOLOAD) :
	{
		__upgrade_stage_start__ = .;
		. += 0x2000;
		__upgrade_stage_end__ = .;
	} > RAM

	.stack_dummy (COPY):
	{
		KEEP(*(.stack*))
	} > RAM

	__StackTop = ORIGIN(RAM) + LENGTH(RAM);
	__StackLimit = __StackTop - SIZEOF(.stack_dummy);
	PROVIDE(__stack = __StackTop);

	ASSERT(__HeapLimit <= 0x20001000, "data/heap overlaps MCU upgrade staging")
	ASSERT(__StackLimit >= 0x20003000, "stack overlaps MCU upgrade staging")
	ASSERT(__StackLimit >= __HeapLimit, "region RAM overflowed with stack")
}
