/* The outer 20 stays on the stack while (3 + 5) is evaluated. */
int main(void)
{
    return 20 - (3 + 5);
}
