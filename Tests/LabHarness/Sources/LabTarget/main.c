#include <stdio.h>
#include <unistd.h>

__attribute__((noinline)) int luma_target_score(int a, int b) {
    int total = 0;
    for (int i = 0; i < a; i++) {
        if (i % 3 == 0)
            total += b;
        else
            total -= i;
    }
    return total;
}

int main(void) {
    volatile int sink = 0;
    printf("%d\n", getpid());
    fflush(stdout);
    for (;;) {
        sink += luma_target_score(7, sink & 7);
        sleep(1);
    }
}
