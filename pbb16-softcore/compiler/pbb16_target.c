/* PBB16 stages 1-6 target for M2-Planet 1.13.1.
 * Local extension, 2026. SPDX-License-Identifier: GPL-3.0-or-later
 * See vendor/M2-Planet/LICENSE. Uses the upstream tokenizer and C parser.
 *
 * Stage 6 grammar (a strict subset of what the upstream parser accepts):
 *   program    := "int" "main" "(" ["void"] ")" "{" { statement } "}" EOF
 *                 (the last statement must definitely return)
 *   statement  := "int" ident ["=" expr] ";"   (declaration, one declarator,
 *                                               main's top level only)
 *               | expr ";"                     (expression or assignment)
 *               | "return" expr ";"            (last statement of its block)
 *               | "if" "(" expr ")" body ["else" body]
 *               | "while" "(" expr ")" body
 *               | "do" body "while" "(" expr ")" ";"
 *               | "for" "(" [expr] ";" expr ";" expr ")" body
 *               | "break" ";" | "continue" ";" (loops only, last in block)
 *   body       := statement-without-declaration | "{" { same } "}"
 *   expr       := ident "=" expr | relational  (assignment is right-associative)
 *   relational := additive { ("<"|"<="|">"|">="|"=="|"!=") additive }
 *   additive   := term { ("+" | "-") term }
 *   term       := unary { ("*" | "/" | "%") unary }
 *   unary      := "-" unary | primary
 *   primary    := literal | ident | "(" expr ")"
 *
 * The gate tracks each local's value while it is compile-time known, so
 * constant expressions keep their exact stage 1-3 overflow/div-by-zero
 * rejection even when routed through variables. Control flow snapshots and
 * merges the environment: a variable stays known after an if only when
 * every path that can fall through agrees on the same known value. Loops
 * merge the pre-loop state with the body end (the body may run zero or more
 * times); known-value checks inside a loop body cover first-iteration
 * values only. Once a value depends on something unknown, checks degrade
 * gracefully instead of lying.
 */
#include "cc.h"
#include "cc_emit.h"

struct pbb16_value
{
    int known;
    int value;
};

/* Gate symbol table: names point into the token stream (no copies needed). */
#define PBB16_MAX_LOCALS 32
static char* pbb16_local_names[PBB16_MAX_LOCALS];
static int pbb16_local_known[PBB16_MAX_LOCALS];
static int pbb16_local_values[PBB16_MAX_LOCALS];
static int pbb16_local_count;
static int pbb16_loop_depth;

static void unsupported(struct token_list* token, char* message)
{
    if(token != NULL) line_error_token(token);
    fputs("PBB16: ", stderr);
    fputs(message, stderr);
    fputs("\nSupported: int main(void) { statements; return EXPR; } with int locals,"
          " assignment, literals 0..32767, unary -, binary + - * / %%, parentheses,"
          " comparisons < <= > >= == !=, if/else, while/do-while/for, break/continue.\n", stderr);
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

static int is_identifier_name(char* s)
{
    int i = 0;
    if(!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '_'))
        return FALSE;
    while(s[i] != 0)
    {
        char c = s[i];
        if(!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
             (c >= '0' && c <= '9') || c == '_')) return FALSE;
        i = i + 1;
    }
    return TRUE;
}

static int is_reserved_name(char* s)
{
    /* Enough of C to keep locals out of the parser's way; "main" would
     * collide with the only function's global label. */
    static char* reserved[] = {
        "int", "void", "char", "short", "long", "unsigned", "signed",
        "const", "static", "extern", "register", "volatile", "inline",
        "if", "else", "while", "for", "do", "break", "continue", "goto",
        "switch", "case", "default", "struct", "union", "enum", "typedef",
        "sizeof", "return", "asm", "main"
    };
    unsigned i;
    for(i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i = i + 1)
        if(match(s, reserved[i])) return TRUE;
    return FALSE;
}

static int find_local(char* name)
{
    int i;
    for(i = 0; i < pbb16_local_count; i = i + 1)
        if(match(pbb16_local_names[i], name)) return i;
    return -1;
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

static struct pbb16_value validate_expression(struct token_list** token, int depth, int* operations);

static struct pbb16_value validate_primary(struct token_list** token, int depth, int* operations)
{
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "("))
    {
        /* Bound both host parser recursion and target temporary-stack use. */
        if(depth >= 64) unsupported(*token, "parentheses exceed 64 levels");
        *token = (*token)->next;
        struct pbb16_value value = validate_expression(token, depth + 1, operations);
        expect(token, ")");
        return value;
    }
    if(*token != NULL && is_identifier_name((*token)->s))
    {
        int slot = find_local((*token)->s);
        struct pbb16_value result;
        if(slot < 0) unsupported(*token, "use of undeclared variable");
        result.known = pbb16_local_known[slot];
        result.value = pbb16_local_values[slot];
        *token = (*token)->next;
        return result;
    }
    if(*token != NULL && (*token)->s[0] >= '0' && (*token)->s[0] <= '9')
    {
        struct pbb16_value result;
        result.known = TRUE;
        result.value = validate_literal(*token);
        *token = (*token)->next;
        return result;
    }
    unsupported(*token, "expected an integer literal, a declared variable or ( expression )");
    /* unreachable, but keeps host compilers from warning about a missing return */
    exit(EXIT_FAILURE);
}

/* unary = "-" unary | primary. Upstream handles unary minus in primary_expr
 * as 0 - x, so the gate mirrors it as one more counted operation. */
static struct pbb16_value validate_unary(struct token_list** token, int depth, int* operations)
{
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "-"))
    {
        struct token_list* operator_token = *token;
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        struct pbb16_value value = validate_unary(token, depth, operations);
        if(value.known)
        {
            if(value.value == (-32767 - 1))
                unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
            value.value = -value.value;
        }
        return value;
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
static struct pbb16_value validate_term(struct token_list** token, int depth, int* operations)
{
    struct pbb16_value value = validate_unary(token, depth, operations);
    skip_newlines(token);
    while(*token != NULL && (match((*token)->s, "*") || match((*token)->s, "/") || match((*token)->s, "%")))
    {
        struct token_list* operator_token = *token;
        char op = operator_token->s[0];
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        struct pbb16_value right = validate_unary(token, depth, operations);
        if((op == '/' || op == '%') && right.known && right.value == 0)
            unsupported(operator_token, "division by zero is undefined in C");
        if(value.known && right.known)
        {
            if(op == '*')
            {
                if(mul_exceeds_int16(value.value, right.value))
                    unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
                value.value = value.value * right.value;
            }
            else
            {
                if(value.value == (-32767 - 1) && right.value == -1)
                    unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
                if(op == '/') value.value = value.value / right.value;
                else value.value = value.value % right.value;
            }
        }
        else value.known = FALSE;
        skip_newlines(token);
    }
    return value;
}

/* additive = term { ("+" | "-") term }. */
static struct pbb16_value validate_additive(struct token_list** token, int depth, int* operations)
{
    struct pbb16_value value = validate_term(token, depth, operations);
    skip_newlines(token);
    while(*token != NULL && (match((*token)->s, "+") || match((*token)->s, "-")))
    {
        struct token_list* operator_token = *token;
        int subtract = match(operator_token->s, "-");
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        struct pbb16_value right = validate_term(token, depth, operations);
        if(value.known && right.known)
        {
            /* Check before adding/subtracting: safe even on a 16-bit C host. */
            if((!subtract && ((right.value > 0 && value.value > 32767 - right.value) ||
                              (right.value < 0 && value.value < (-32767 - 1) - right.value))) ||
               (subtract && ((right.value > 0 && value.value < (-32767 - 1) + right.value) ||
                             (right.value < 0 && value.value > 32767 + right.value))))
                unsupported(operator_token, "intermediate result exceeds signed 16-bit range");
            if(subtract) value.value = value.value - right.value;
            else value.value = value.value + right.value;
        }
        else value.known = FALSE;
        skip_newlines(token);
    }
    return value;
}

/* relational = additive { ("<"|"<="|">"|">="|"=="|"!=") additive }.
 * M2-Planet keeps all six operators at one flat precedence level (in C,
 * == and != sit below the others); the gate mirrors the parser so tracked
 * values always match the generated code. Comparisons yield 0/1 and can
 * never overflow. */
static struct pbb16_value validate_relational(struct token_list** token, int depth, int* operations)
{
    struct pbb16_value value = validate_additive(token, depth, operations);
    skip_newlines(token);
    for(;;)
    {
        int op;
        struct token_list* operator_token;
        struct pbb16_value right;
        if(*token == NULL) break;
        if(match((*token)->s, "<")) op = 0;
        else if(match((*token)->s, "<=")) op = 1;
        else if(match((*token)->s, ">")) op = 2;
        else if(match((*token)->s, ">=")) op = 3;
        else if(match((*token)->s, "==")) op = 4;
        else if(match((*token)->s, "!=")) op = 5;
        else break;
        operator_token = *token;
        *operations = *operations + 1;
        if(*operations > 256) unsupported(operator_token, "expression exceeds 256 operations");
        *token = (*token)->next;
        right = validate_additive(token, depth, operations);
        if(value.known && right.known)
        {
            int left = value.value;
            int r = right.value;
            if(op == 0) value.value = left < r;
            else if(op == 1) value.value = left <= r;
            else if(op == 2) value.value = left > r;
            else if(op == 3) value.value = left >= r;
            else if(op == 4) value.value = left == r;
            else value.value = left != r;
        }
        else value.known = FALSE;
        skip_newlines(token);
    }
    return value;
}

/* expr = ident "=" expr | relational. The assignment's value is the right-hand
 * side's value, so chained assignment works; each level costs one PUSH of the
 * target address on the hardware stack, counted as an operation. */
static struct pbb16_value validate_expression(struct token_list** token, int depth, int* operations)
{
    struct token_list* lookahead;
    skip_newlines(token);
    if(*token != NULL && is_identifier_name((*token)->s))
    {
        lookahead = (*token)->next;
        while(lookahead != NULL && match(lookahead->s, "\n")) lookahead = lookahead->next;
        if(lookahead != NULL && match(lookahead->s, "="))
        {
            struct token_list* name_token = *token;
            int slot = find_local(name_token->s);
            struct pbb16_value result;
            if(slot < 0) unsupported(name_token, "assignment to undeclared variable");
            *operations = *operations + 1;
            if(*operations > 256) unsupported(lookahead, "expression exceeds 256 operations");
            *token = lookahead->next;
            result = validate_expression(token, depth, operations);
            pbb16_local_known[slot] = result.known;
            pbb16_local_values[slot] = result.value;
            return result;
        }
    }
    {
        struct pbb16_value result = validate_relational(token, depth, operations);
        skip_newlines(token);
        if(*token != NULL && match((*token)->s, "="))
            unsupported(*token, "left side of = must be a declared variable");
        return result;
    }
}

/* "int" ident ["=" expr] ";" — one declarator per statement. The variable
 * only becomes visible after its initializer, so int x = x; is rejected. */
static void validate_declaration(struct token_list** token, int* operations)
{
    struct token_list* name_token;
    struct pbb16_value initial;
    initial.known = FALSE;
    initial.value = 0;

    *token = (*token)->next;
    skip_newlines(token);
    if(*token == NULL || !is_identifier_name((*token)->s))
        unsupported(*token, "expected a variable name after int (pointers and other types are not supported)");
    name_token = *token;
    if(is_reserved_name(name_token->s))
        unsupported(name_token, "reserved name cannot be used for a local variable");
    if(find_local(name_token->s) >= 0)
        unsupported(name_token, "redeclaration of a local variable");
    *token = (*token)->next;
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "["))
        unsupported(*token, "local arrays are not supported yet");
    if(*token != NULL && match((*token)->s, ","))
        unsupported(*token, "declare one variable per statement");
    if(*token != NULL && match((*token)->s, "="))
    {
        *token = (*token)->next;
        initial = validate_expression(token, 0, operations);
    }
    if(pbb16_local_count >= PBB16_MAX_LOCALS)
        unsupported(name_token, "too many local variables (maximum 32)");
    pbb16_local_names[pbb16_local_count] = name_token->s;
    pbb16_local_known[pbb16_local_count] = initial.known;
    pbb16_local_values[pbb16_local_count] = initial.value;
    pbb16_local_count = pbb16_local_count + 1;
    expect(token, ";");
}

/* Control flow snapshots the constant environment and merges it afterwards:
 * a variable stays compile-time known after an if only when every path that
 * can fall through agrees on the same known value. */
static void save_env(int* known, int* values)
{
    int i;
    for(i = 0; i < pbb16_local_count; i = i + 1)
    {
        known[i] = pbb16_local_known[i];
        values[i] = pbb16_local_values[i];
    }
}

static void restore_env(int* known, int* values)
{
    int i;
    for(i = 0; i < pbb16_local_count; i = i + 1)
    {
        pbb16_local_known[i] = known[i];
        pbb16_local_values[i] = values[i];
    }
}

/* Merge a branch environment into the live one. */
static void merge_env(int* branch_known, int* branch_values)
{
    int i;
    for(i = 0; i < pbb16_local_count; i = i + 1)
    {
        if(!pbb16_local_known[i] || !branch_known[i] ||
           pbb16_local_values[i] != branch_values[i])
        {
            pbb16_local_known[i] = FALSE;
            pbb16_local_values[i] = 0;
        }
    }
}

static int validate_if(struct token_list** token, int* operations, int block_depth);
static int validate_while(struct token_list** token, int* operations, int block_depth);
static int validate_do(struct token_list** token, int* operations, int block_depth);
static int validate_for(struct token_list** token, int* operations, int block_depth);

/* One statement. Returns TRUE when it never falls through (a return, a
 * break/continue, or an if whose every path does one of those). Declarations
 * stay at main's top level (in_block rejects them): the flat symbol table
 * has no scoping. */
static int validate_statement(struct token_list** token, int* operations, int block_depth, int in_block)
{
    skip_newlines(token);
    if(*token == NULL) unsupported(*token, "unexpected end of program");
    if(match((*token)->s, "int"))
    {
        if(in_block) unsupported(*token, "declare locals at the top level of main, not inside if/else/loop bodies");
        validate_declaration(token, operations);
        return FALSE;
    }
    if(match((*token)->s, "return"))
    {
        *token = (*token)->next;
        validate_expression(token, 0, operations);
        expect(token, ";");
        return TRUE;
    }
    if(match((*token)->s, "if")) return validate_if(token, operations, block_depth);
    if(match((*token)->s, "while")) return validate_while(token, operations, block_depth);
    if(match((*token)->s, "for")) return validate_for(token, operations, block_depth);
    if(match((*token)->s, "do")) return validate_do(token, operations, block_depth);
    if(match((*token)->s, "break") || match((*token)->s, "continue"))
    {
        if(pbb16_loop_depth == 0)
            unsupported(*token, "break/continue outside a loop");
        *token = (*token)->next;
        expect(token, ";");
        return TRUE;
    }
    if(match((*token)->s, "else")) unsupported(*token, "else without a matching if");
    if(match((*token)->s, "{")) unsupported(*token, "blocks are only supported as if/else/loop bodies");
    validate_expression(token, 0, operations);
    expect(token, ";");
    return FALSE;
}

/* Statements until "}"; returns TRUE when the block never falls through.
 * A non-falling-through statement must be the last one, same rule as main. */
static int validate_block(struct token_list** token, int* operations, int block_depth)
{
    int terminated = FALSE;
    for(;;)
    {
        skip_newlines(token);
        if(*token == NULL) unsupported(*token, "unexpected end of program inside a block");
        if(match((*token)->s, "}"))
        {
            *token = (*token)->next;
            return terminated;
        }
        if(terminated) unsupported(*token, "statement after return/break/continue in the same block");
        terminated = validate_statement(token, operations, block_depth, TRUE);
    }
}

/* An if/loop body: a single statement or a braced block. */
static int validate_body(struct token_list** token, int* operations, int block_depth)
{
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "{"))
    {
        *token = (*token)->next;
        return validate_block(token, operations, block_depth);
    }
    return validate_statement(token, operations, block_depth, TRUE);
}

/* "if" "(" expr ")" body ["else" body]. Both bodies are fully validated even
 * when the condition is compile-time known — dead code still has to be legal.
 * The environment afterwards merges every path that can fall through; when
 * no path can, following code is unreachable and the environment degrades to
 * all-unknown. */
static int validate_if(struct token_list** token, int* operations, int block_depth)
{
    int before_known[PBB16_MAX_LOCALS];
    int before_values[PBB16_MAX_LOCALS];
    int branch_known[PBB16_MAX_LOCALS];
    int branch_values[PBB16_MAX_LOCALS];
    int then_returns;
    int else_returns;

    if(block_depth >= 16) unsupported(*token, "control flow nested more than 16 deep");
    *token = (*token)->next;
    expect(token, "(");
    validate_expression(token, 0, operations);
    expect(token, ")");

    save_env(before_known, before_values);
    then_returns = validate_body(token, operations, block_depth + 1);
    save_env(branch_known, branch_values);
    restore_env(before_known, before_values);

    skip_newlines(token);
    if(*token == NULL || !match((*token)->s, "else"))
    {
        /* Without else the before-env always falls through. */
        if(!then_returns) merge_env(branch_known, branch_values);
        return FALSE;
    }
    *token = (*token)->next;
    else_returns = validate_body(token, operations, block_depth + 1);
    /* The live environment now holds the else path, branch_* the then path. */
    if(then_returns && else_returns)
    {
        int i;
        for(i = 0; i < pbb16_local_count; i = i + 1) pbb16_local_known[i] = FALSE;
        return TRUE;
    }
    if(then_returns) return FALSE;      /* only the else path falls through */
    if(else_returns) restore_env(branch_known, branch_values);
    else merge_env(branch_known, branch_values);
    return FALSE;
}

/* Validate a loop body and merge its end environment into the pre-loop one:
 * the body may run zero or more times, so a variable stays known only when
 * both agree. Known-value checks inside the body use first-iteration values. */
static void validate_loop_body(struct token_list** token, int* operations, int block_depth)
{
    int before_known[PBB16_MAX_LOCALS];
    int before_values[PBB16_MAX_LOCALS];
    int body_known[PBB16_MAX_LOCALS];
    int body_values[PBB16_MAX_LOCALS];

    save_env(before_known, before_values);
    pbb16_loop_depth = pbb16_loop_depth + 1;
    validate_body(token, operations, block_depth);
    pbb16_loop_depth = pbb16_loop_depth - 1;
    save_env(body_known, body_values);
    restore_env(before_known, before_values);
    merge_env(body_known, body_values);
}

/* Loops never definitely return (conservative: even while(1) { return x; }),
 * so main still needs a trailing return after a loop. */
static int validate_while(struct token_list** token, int* operations, int block_depth)
{
    if(block_depth >= 16) unsupported(*token, "control flow nested more than 16 deep");
    *token = (*token)->next;
    expect(token, "(");
    validate_expression(token, 0, operations);
    expect(token, ")");
    validate_loop_body(token, operations, block_depth + 1);
    return FALSE;
}

static int validate_do(struct token_list** token, int* operations, int block_depth)
{
    if(block_depth >= 16) unsupported(*token, "control flow nested more than 16 deep");
    *token = (*token)->next;
    validate_loop_body(token, operations, block_depth + 1);
    expect(token, "while");
    expect(token, "(");
    /* The condition sees the merged environment, not the body end. */
    validate_expression(token, 0, operations);
    expect(token, ")");
    expect(token, ";");
    return FALSE;
}

/* "for" "(" [expr] ";" expr ";" expr ")" body. The upstream parser requires
 * the condition and increment expressions (only the init may be empty), and
 * the gate validates the header in token order: init, condition, increment,
 * then the body. for-init declarations are rejected like all in-block ones. */
static int validate_for(struct token_list** token, int* operations, int block_depth)
{
    if(block_depth >= 16) unsupported(*token, "control flow nested more than 16 deep");
    *token = (*token)->next;
    expect(token, "(");
    skip_newlines(token);
    if(*token != NULL && match((*token)->s, "int"))
        unsupported(*token, "declare locals at the top level of main, not in a for header");
    if(*token != NULL && !match((*token)->s, ";"))
        validate_expression(token, 0, operations);
    expect(token, ";");
    validate_expression(token, 0, operations);
    expect(token, ";");
    validate_expression(token, 0, operations);
    expect(token, ")");
    validate_loop_body(token, operations, block_depth + 1);
    return FALSE;
}

/* Check capabilities before preprocessing so directives cannot bypass the gate.
 * Keep global_token in place for the original M2 parser after validation.
 */
void pbb16_validate_program(void)
{
    struct token_list* token = global_token;
    int operations = 0;
    int returned = FALSE;
    pbb16_local_count = 0;
    pbb16_loop_depth = 0;
    expect(&token, "int");
    expect(&token, "main");
    expect(&token, "(");
    skip_newlines(&token);
    if(token != NULL && match(token->s, "void")) token = token->next;
    expect(&token, ")");
    expect(&token, "{");
    for(;;)
    {
        skip_newlines(&token);
        if(token == NULL) unsupported(token, "unexpected end of program inside main");
        if(match(token->s, "}"))
        {
            if(!returned) unsupported(token, "missing return statement");
            break;
        }
        if(returned) unsupported(token, "statement after return/break/continue in the same block");
        returned = validate_statement(&token, &operations, 0, FALSE);
    }
    expect(&token, "}");
    skip_newlines(&token);
    if(token != NULL) unsupported(token, "only one main definition is supported");
}

void pbb16_write_load_immediate(int reg, int value)
{
    char* name = register_from_string(reg);
    require(value >= 0 && value <= 32767, "PBB16: immediate out of range\n");
    if(value <= 255)
    {
        emit_to_string("MOVI ");
        emit_to_string(name);
        emit_to_string(", ");
        emit_to_string(int2str(value, 10, TRUE));
        emit_to_string("\n");
    }
    else
    {
        /* MOVUI replaces the entire register; load high first, then OR low. */
        emit_to_string("MOVUI ");
        emit_to_string(name);
        emit_to_string(", ");
        emit_to_string(int2str(value >> 8, 10, TRUE));
        emit_to_string("\nORI ");
        emit_to_string(name);
        emit_to_string(", ");
        emit_to_string(int2str(value & 255, 10, TRUE));
        emit_to_string("\n");
    }
}
