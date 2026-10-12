/* Stage 5 example: comparisons and if/else.
 * max(-7, 3) = 3, clamped to non-negative, then scaled by 14 -> 42. */
int main(void) {
    int a = 20 - 27;
    int b = 3;
    int max;
    if (a > b) {
        max = a;
    } else {
        max = b;
    }
    if (max < 0) {
        max = 0 - max;
    }
    if (max == 3) {
        max = max * 14;
    }
    return max;
}
