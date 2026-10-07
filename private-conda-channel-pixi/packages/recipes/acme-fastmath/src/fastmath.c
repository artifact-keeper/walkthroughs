#include "fastmath.h"
/* Newton's method square root: no libm needed. */
static double acme_sqrt(double x) {
    if (x <= 0.0) return 0.0;
    double r = x > 1.0 ? x : 1.0;
    for (int i = 0; i < 64; i++) r = 0.5 * (r + x / r);
    return r;
}
double acme_hypot(double a, double b) { return acme_sqrt(a * a + b * b); }
