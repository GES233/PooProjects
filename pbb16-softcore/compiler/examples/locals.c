/* Stage 4: local variables live in the stack frame. */
int main(void) {
    int total = 40;
    int step = 3;
    total = total + step * 2;
    step = total % 7;
    return total - step;
}
