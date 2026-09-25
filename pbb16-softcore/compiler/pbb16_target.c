/* PBB16 stage-1 target for M2-Planet 1.13.1.
 * Local extension, 2026. SPDX-License-Identifier: GPL-3.0-or-later
 * See vendor/M2-Planet/LICENSE. Uses the upstream tokenizer and C parser.
 */
#include "cc.h"
#include "cc_emit.h"

static void unsupported(struct token_list* token, char* message)
{
    if(token != NULL) line_error_token(token);
    fputs("PBB16 stage 1: ", stderr);
    fputs(message, stderr);
    fputs("\nSupported: int main(void) { return N; }, N = 0..32767.\n", stderr);
    exit(EXIT_FAILURE);
}

static void skip_newlines(struct token_list** token)
{
    while(*token != NULL && match((*token)->s, "\n")) *token = (*token)->next;
}

static void expect(struct token_list** token, char* text)
{
    skip_newlines(token);
    if(*token == NULL || !match((*token)->s, text))
        unsupported(*token, "unexpected token or incomplete program");
    *token = (*token)->next;
}

/* A capability gate, not a substitute parser: the original M2 parser still
 * processes the accepted tokens and invokes the immediate/return emitters.
 * Before expanding the backend, expand this gate and its negative tests too.
 * No preprocessing: otherwise #if/#define could bypass this milestone's scope.
 */
void pbb16_validate_program(void)
{
    struct token_list* token = global_token;
    expect(&token, "int");
    expect(&token, "main");
    expect(&token, "(");
    skip_newlines(&token);
    if(token != NULL && match(token->s, "void")) token = token->next;
    expect(&token, ")");
    expect(&token, "{");
    expect(&token, "return");
    skip_newlines(&token);
    if(token == NULL) unsupported(token, "missing integer literal");

    /* Check digits and range before upstream strtoint: do not silently accept
     * suffixes, invalid octal, overflowing host integers or truncated values. */
    char* s = token->s;
    int base = 10;
    int i = 0;
    int value = 0;
    if(s[0] == '0')
    {
        base = 8;
        if(s[1] == 'x' || s[1] == 'X')
        {
            base = 16;
            i = 2;
        }
    }
    if(s[i] == 0) unsupported(token, "missing digits in integer literal");
    while(s[i] != 0)
    {
        int digit = -1;
        if(s[i] >= '0' && s[i] <= '9') digit = s[i] - '0';
        else if(s[i] >= 'a' && s[i] <= 'f') digit = s[i] - 'a' + 10;
        else if(s[i] >= 'A' && s[i] <= 'F') digit = s[i] - 'A' + 10;
        if(digit < 0 || digit >= base) unsupported(token, "invalid or unsupported integer literal");
        if(value > (32767 - digit) / base) unsupported(token, "literal exceeds signed 16-bit range");
        value = value * base + digit;
        i = i + 1;
    }
    /* M2libc strtoint only recognizes lowercase 0x; preserve source otherwise. */
    if(s[0] == '0' && s[1] == 'X') s[1] = 'x';
    token = token->next;
    expect(&token, ";");
    expect(&token, "}");
    skip_newlines(&token);
    if(token != NULL) unsupported(token, "only one main definition is supported");
}

void pbb16_write_load_immediate(int reg, int value)
{
    require(reg == REGISTER_ZERO, "PBB16 stage 1: only R0 immediate results implemented\n");
    require(value >= 0 && value <= 32767, "PBB16 stage 1: immediate out of range\n");
    if(value <= 255)
    {
        emit_to_string("MOVI R0, ");
        emit_to_string(int2str(value, 10, TRUE));
        emit_to_string("\n");
    }
    else
    {
        /* MOVUI replaces the entire register; load high first, then OR low. */
        emit_to_string("MOVUI R0, ");
        emit_to_string(int2str(value >> 8, 10, TRUE));
        emit_to_string("\nORI R0, ");
        emit_to_string(int2str(value & 255, 10, TRUE));
        emit_to_string("\n");
    }
}
