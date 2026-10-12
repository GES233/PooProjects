/* Stage 6 example: loops, break and continue.
 * odds = 1+3+5+7+9 = 25; n = first n with n*n > 50 = 8; t = 9.
 * 25 + 8 + 9 = 42. */
int main(void) {
    int i = 0;
    int odds = 0;
    int n = 0;
    int t = 0;
    while (i < 10) {
        i = i + 1;
        if (i % 2 == 0) {
            continue;
        }
        odds = odds + i;
    }
    for (n = 1; n < 100; n = n + 1) {
        if (n * n > 50) {
            break;
        }
    }
    do {
        t = t + 3;
    } while (t < 8);
    return odds + n + t;
}
