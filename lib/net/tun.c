/* Linux TUN/TAP transport. Shen owns buffer bounds and packet queues. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int open_device(const char *name, short mode)
{
    struct ifreq request = {0};
    size_t length = strlen(name);
    if (length == 0 || length >= sizeof request.ifr_name)
        return -EINVAL;
    memcpy(request.ifr_name, name, length);
    request.ifr_flags = mode | IFF_NO_PI;
    int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -errno;
    if (ioctl(fd, TUNSETIFF, &request) < 0) {
        int code = errno;
        close(fd);
        return -code;
    }
    return fd;
}

int shen_tun_open(const char *name)
{
    return open_device(name, IFF_TUN);
}

int shen_tap_open(const char *name)
{
    return open_device(name, IFF_TAP);
}

int shen_tun_close(int fd)
{
    return close(fd) == 0 ? 0 : -errno;
}

static int io_error(int code)
{
    return code == EAGAIN || code == EWOULDBLOCK || code == EINTR ? 0 : -code;
}

int shen_tun_read(int fd, unsigned char *bytes, int capacity)
{
    ssize_t count = read(fd, bytes, (size_t)capacity);
    return count < 0 ? io_error(errno) : (int)count;
}

int shen_tun_write(int fd, const unsigned char *bytes, int64_t start, int count)
{
    ssize_t sent = write(fd, bytes + start, (size_t)count);
    if (sent < 0)
        return io_error(errno);
    return sent == count ? count : -EIO;
}

int shen_tun_wait(int fd, bool readable, bool writable, int milliseconds)
{
    struct pollfd p = {
        .fd = fd,
        .events = (readable ? POLLIN : 0) | (writable ? POLLOUT : 0),
    };
    int ready = poll(&p, 1, milliseconds);
    if (ready < 0)
        return io_error(errno);
    if (p.revents & POLLNVAL)
        return -EBADF;
    if (p.revents & (POLLERR | POLLHUP))
        return -EIO;
    return ready;
}

int64_t shen_tun_clock(int64_t origin)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return -errno;
    int64_t now = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return origin < 0 || origin > now ? -EINVAL : now - origin;
}
