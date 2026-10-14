/* Stage 8 example: normalized logical values and short-circuit side effects. */
int is_nonzero(int value)
{
    return !!value;
}

int main(void)
{
    int x = 0;
    0 && (x = 99);
    1 || (x = 99);
    if (!x && 3 < 4) {
        x = 41;
    }
    return x + is_nonzero(7);
}
