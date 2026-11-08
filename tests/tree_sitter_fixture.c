#include <stdint.h>
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
/* ABI is the first language field. Rejected before any other field is inspected. */
EXPORT const void *ts_fixture_bad_language(void)
{
    static const uint32_t version = 999;
    return &version;
}
EXPORT const void *ts_fixture_null_language(void)
{
    return 0;
}
