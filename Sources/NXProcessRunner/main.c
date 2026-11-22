#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "NXProcessRunner requires a program to launch.\n");
        return 64;
    }

    if (setpgid(0, 0) != 0) {
        perror("NXProcessRunner: setpgid");
        return 70;
    }

    execv(argv[1], &argv[1]);
    perror("NXProcessRunner: execv");
    return 127;
}
