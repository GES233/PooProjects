/* PBB16 stages 1-3 target for M2-Planet 1.13.1.
 * Local extension, 2026. SPDX-License-Identifier: GPL-3.0-or-later
 * See vendor/M2-Planet/LICENSE. Uses the upstream tokenizer and C parser.
 */
#include "cc.h"
#include "cc_emit.h"

static void unsupported(struct token_list* token, char* message)
{
    if(token != NULL) line_error_token(token);
    fputs("PBB16: ", stderr);
    fputs(message, stderr);
    fputs("\nSupported: int main(void) { return EXPR; }, literals 0..32767, unary -, binary + - * / %%, parentheses.\n", stderr);
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

static int validate_literal(struct token_list* token)
{
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
    return value;
}

static int validate_expression(struct token_list** token, int depth, int* operations);

static int validate_primary(struct token_list** token, int depth, int* operations)
{
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "("))
    {
        /* Bound both host parser recursion and target temporary-stack use. */
        if(depth >= 64) unsupported(*token, "parentheses exceed 64 levels");
        *token = (*token)->next;
        int value = validate_expression(token, depth + 1, operations);
        expect(token, ")");
        return value;
    }
    int value = validate_literal(*token);
    *token = (*token)->next;
    return value;
}

/* unary = "-" unary | primary. Upstream handles unary minus in primary_expr
 * as 0 - x, so the gate mirrors it as one more counted operation. */
static int validate_unary(struct token_list** token, int depth, int* operations)
{
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "-"))
    {
        struct token_list* operator_token = *token;
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        int value = validate_unary(token, depth, operations);
        if(value == (-32767 - 1)) unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
        return -value;
    }
    return validate_primary(token, depth, operations);
}

/* Exact signed-16-bit multiply check without 32-bit math.
 * -32768 * 1 == -32768 is the only representable product with a -32768
 * operand; after excluding it both magnitudes are <= 32767, so the
 * division test itself cannot overflow. The negative limit is 32768
 * (INT16_MIN), the positive one 32767. */
static int mul_exceeds_int16(int a, int b)
{
    int mag_a;
    int mag_b;
    int limit;
    if(a == 0 || b == 0) return FALSE;
    if(a == (-32767 - 1)) return b != 1;
    if(b == (-32767 - 1)) return a != 1;
    mag_a = a < 0 ? -a : a;
    mag_b = b < 0 ? -b : b;
    limit = ((a < 0) != (b < 0)) ? 32768 : 32767;
    return mag_a > limit / mag_b;
}

/* term = unary { ("*" | "/" | "%") unary }; C truncates toward zero,
 * matching the RISC-V-style DIV/REM semantics of the hardware. */
static int validate_term(struct token_list** token, int depth, int* operations)
{
    int value = validate_unary(token, depth, operations);
    skip_newlines(token);
    while(*token != NULL && (match((*token)->s, "*") || match((*token)->s, "/") || match((*token)->s, "%")))
    {
        struct token_list* operator_token = *token;
        char op = operator_token->s[0];
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        int right = validate_unary(token, depth, operations);
        if(op == '*')
        {
            if(mul_exceeds_int16(value, right))
                unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
            value = value * right;
        }
        else
        {
            if(right == 0) unsupported(operator_token, "division by zero is undefined in C");
            if(value == (-32767 - 1) && right == -1)
                unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
            if(op == '/') value = value / right;
            else value = value % right;
        }
        skip_newlines(token);
    }
    return value;
}

/* expr = term { ("+" | "-") term }; term = unary { ("*"|"/"|"%") unary };
 * unary = "-" unary | primary; primary = literal | "(" expr ")".
 * Evaluate only to reject signed overflow; do not replace tokens or fold code.
 * The M2 parser still generates every load, push, pop and arithmetic operation.
 */
static int validate_expression(struct token_list** token, int depth, int* operations)
{
    int value = validate_term(token, depth, operations);
    skip_newlines(token);
    while(*token != NULL && (match((*token)->s, "+") || match((*token)->s, "-")))
    {
        struct token_list* operator_token = *token;
        int subtract = match(operator_token->s, "-");
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        int right = validate_term(token, depth, operations);
        /* Check before adding/subtracting: safe even on a 16-bit C host. */
        if((!subtract && ((right > 0 && value > 32767 - right) ||
                          (right < 0 && value < (-32767 - 1) - right))) ||
           (subtract && ((right > 0 && value < (-32767 - 1) + right) ||
                         (right < 0 && value > 32767 + right))))
            unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
        if(subtract) value = value - right;
        else value = value + right;
        skip_newlines(token);
    }
    return value;
}

/* Check capabilities before preprocessing so directives cannot bypass the gate.
 * Keep global_token in place for the original M2 parser after validation.
 */
void pbb16_validate_program(void)
{
    struct token_list* token = global_token;
    int operations = 0;
    expect(&token, "int");
    expect(&token, "main");
    expect(&token, "(");
    skip_newlines(&token);
    if(token != NULL && match(token->s, "void")) token = token->next;
    expect(&token, ")");
    expect(&token, "{");
    expect(&token, "return");
    validate_expression(&token, 0, &operations);
    expect(&token, ";");
    expect(&token, "}");
    skip_newlines(&token);
    if(token != NULL) unsupported(token, "only one main definition is supported");
}

void pbb16_write_load_immediate(int reg, int value)
{
    require(reg == REGISTER_ZERO, "PBB16: only R0 immediate results implemented\n");
    require(value >= 0 && value <= 32767, "PBB16: immediate out of range\n");
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
