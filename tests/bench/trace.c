/* The path tracer of trace.shen in C: the same scene, random numbers and order of operations, so
   that the hash of the image is the same to the last bit. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

enum { WIDTH = 240, HEIGHT = 180, SAMPLES = 16, BOUNCES = 6, SPHERES = 9, FIELDS = 11 };

/* x y z radius, colour, light, mirror */
static const double scene[SPHERES][FIELDS] = {
    {-1000.5, 0, 0, 1000, 0.75, 0.25, 0.25, 0, 0, 0, 0},    /* the left wall */
    {1000.5, 0, 0, 1000, 0.25, 0.25, 0.75, 0, 0, 0, 0},     /* the right wall */
    {0, -1000.5, 0, 1000, 0.75, 0.75, 0.75, 0, 0, 0, 0},    /* the floor */
    {0, 1000.5, 0, 1000, 0.75, 0.75, 0.75, 0, 0, 0, 0},     /* the ceiling */
    {0, 0, -1001, 1000, 0.75, 0.75, 0.75, 0, 0, 0, 0},      /* the back wall */
    {0, 0, 1003, 1000, 0, 0, 0, 0, 0, 0, 0},                /* behind the camera */
    {-0.25, -0.25, -0.5, 0.25, 0.875, 0.875, 0.875, 0, 0, 0, 1}, /* a mirror */
    {0.25, -0.3125, -0.25, 0.1875, 0.25, 0.75, 0.25, 0, 0, 0, 0}, /* a green ball */
    {0, 1, -0.5, 0.625, 0, 0, 0, 6, 6, 6, 0},               /* the light */
};

static uint64_t state;

static uint64_t next_word(void)
{
    uint64_t x = state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state = x;
    return x * UINT64_C(2685821657736338717);
}

static double next_float(void) { return (double)(int64_t)(next_word() >> 11) * (1.0 / 9007199254740992.0); }

static void path(double dx, double dy, double dz, double *out)
{
    double ox = 0, oy = 0, oz = 2, tr = 1, tg = 1, tb = 1, rr = 0, rg = 0, rb = 0;
    for (int bounce = 0; bounce < BOUNCES; bounce++) {
        double best = 1e30;
        int hit = -1;
        for (int k = 0; k < SPHERES; k++) {
            const double *s = scene[k];
            double cx = ox - s[0], cy = oy - s[1], cz = oz - s[2];
            double b = cx * dx + (cy * dy + cz * dz);
            double c = cx * cx + (cy * cy + cz * cz) - s[3] * s[3];
            double disc = b * b - c;
            if (disc > 0) {
                double root = sqrt(disc), t = (0 - b) - root;
                if (!(t > 0.0009765625))
                    t = (0 - b) + root;
                if (t > 0.0009765625 && t < best) {
                    best = t;
                    hit = k;
                }
            }
        }
        if (hit < 0)
            break;
        const double *s = scene[hit];
        rr = rr + tr * s[7];
        rg = rg + tg * s[8];
        rb = rb + tb * s[9];
        tr = tr * s[4];
        tg = tg * s[5];
        tb = tb * s[6];
        ox = ox + best * dx;
        oy = oy + best * dy;
        oz = oz + best * dz;
        double nx = (ox - s[0]) / s[3], ny = (oy - s[1]) / s[3], nz = (oz - s[2]) / s[3];
        double dn = dx * nx + (dy * ny + dz * nz);
        if (dn > 0) {
            nx = 0 - nx;
            ny = 0 - ny;
            nz = 0 - nz;
            dn = 0 - dn;
        }
        if (s[10] > 0) {
            double twice = dn + dn;
            dx = dx - twice * nx;
            dy = dy - twice * ny;
            dz = dz - twice * nz;
        } else {
            double ux, uy, uz, len;
            for (;;) {
                ux = 2 * next_float() - 1;
                uy = 2 * next_float() - 1;
                uz = 2 * next_float() - 1;
                len = ux * ux + (uy * uy + uz * uz);
                if (len < 1 && len > 0.0009765625)
                    break;
            }
            double root = sqrt(len);
            dx = nx + ux / root;
            dy = ny + uy / root;
            dz = nz + uz / root;
            double norm = sqrt(dx * dx + (dy * dy + dz * dz));
            dx = dx / norm;
            dy = dy / norm;
            dz = dz / norm;
        }
    }
    out[0] += rr;
    out[1] += rg;
    out[2] += rb;
}

static double seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    static double pixels[HEIGHT * WIDTH * 3];
    static unsigned char image[HEIGHT * WIDTH * 3];
    state = (UINT64_C(1234567) << 32) + UINT64_C(89101112);
    double t0 = seconds();
    for (int y = 0; y < HEIGHT; y++)
        for (int x = 0; x < WIDTH; x++)
            for (int n = 0; n < SAMPLES; n++) {
                double px = ((double)x + next_float() - (double)WIDTH * 0.5) * (2.0 / (double)HEIGHT);
                double py = (((double)HEIGHT * 0.5) - (double)y - next_float()) * (2.0 / (double)HEIGHT);
                double pz = -2;
                double norm = sqrt(px * px + (py * py + pz * pz));
                path(px / norm, py / norm, pz / norm, &pixels[(y * WIDTH + x) * 3]);
            }
    double t1 = seconds();
    uint64_t hash = (UINT64_C(3421674724) << 32) + UINT64_C(2216829733);
    for (int i = 0; i < HEIGHT * WIDTH * 3; i++) {
        double v = sqrt(pixels[i] / (double)SAMPLES);
        int64_t b = (int64_t)(v * 255.5);
        image[i] = (unsigned char)(b > 255 ? 255 : b);
        hash = (hash ^ image[i]) * UINT64_C(1099511628211);
    }
    printf("trace %g s check %016llx\n", seconds() - t0, (unsigned long long)hash);
    if (argc > 1) {
        FILE *f = fopen(argv[1], "wb");
        fprintf(f, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
        fwrite(image, 1, sizeof image, f);
        fclose(f);
    }
    (void)t1;
    return 0;
}
