/* Stage 7 example: stack arguments and nested function calls. */
int add(int left, int right)
{
    return left + right;
}

int twice(int value)
{
    return add(value, value);
}

int main(void)
{
    return add(twice(10), 22);
}
