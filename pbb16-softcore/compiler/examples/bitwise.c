int mix(int value)
{
    return ((value << 3) | ((~253) & 3)) ^ ((-8 >> 2) ^ -2);
}

int main(void)
{
    return mix(5);
}
