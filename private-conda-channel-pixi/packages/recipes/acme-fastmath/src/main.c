#include <stdio.h>
#include <stdlib.h>
#include "fastmath.h"
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: acme-fastmath A B\n"); return 2; }
    printf("%f\n", acme_hypot(atof(argv[1]), atof(argv[2])));
    return 0;
}
