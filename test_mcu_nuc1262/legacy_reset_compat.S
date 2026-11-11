/* Migration shim for the verified deployed v1.1.15 SRAM writer only.
 * Its LTO veneer jumps to Thumb 0x205 after full FMC readback. Keep that
 * destination a direct reset, rather than executing unrelated new APROM code.
 * This does NOT make the old updater power-fail-safe or repair its failures.
 */
.syntax unified
.cpu cortex-m23
.thumb
/* Vendor startup's .vectors omits SHF_ALLOC. This retained data anchor makes
 * the separated vector output loadable, as the original combined .text was. */
.section .vector_load_anchor,"a",%progbits
.word 0
.section .legacy_reset_compat,"ax",%progbits
.balign 4
.global sc7f0_legacy_reset_compat
.type sc7f0_legacy_reset_compat,%function
.thumb_func
sc7f0_legacy_reset_compat:
    dsb sy
    ldr r3, =0xe000ed00
    ldr r2, =0x05fa0004
    str r2, [r3, #12]
    dsb sy
1:  mov r8, r8
    b 1b
    mov r8, r8
    .balign 4
    .ltorg
.size sc7f0_legacy_reset_compat, .-sc7f0_legacy_reset_compat
