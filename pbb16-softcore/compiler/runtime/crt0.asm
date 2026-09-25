; PBB16 stage 1: reset enters direct mode with interrupts disabled.
; Keep the stack below MMIO (0xF000) and the exception vector page (0xFF00).
        .org 0x0000
_start:
        MOVUI R6, 0xEF
        ORI   R6, 0xFE
        CALL  FUNCTION_main
_exit:
        HLT                    ; R0 is the return value; no OS exit yet.
