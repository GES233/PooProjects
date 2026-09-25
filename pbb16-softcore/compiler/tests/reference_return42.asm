; Hand-written oracle for the startup/call contract; not compiler output.
        .org 0x0000
_start:
        MOVUI R6, 0xEF
        ORI   R6, 0xFE
        CALL  main
_exit:
        HLT
main:
        MOVI  R0, 42
        RET
