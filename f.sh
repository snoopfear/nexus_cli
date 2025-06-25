cat << 'EOF' > /root/fake_proc/fakeproc.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sched.h>

// Пути к «фейковым» файлам
static const char *FAKE_CPUINFO = "/root/fake_proc/cpuinfo";
static const char *FAKE_STAT    = "/root/fake_proc/stat";

// Оригинальные функции
static int  (*real_open)(const char*, int, mode_t) = NULL;
static int  (*real_openat)(int, const char*, int, mode_t) = NULL;
static FILE *(*real_fopen)(const char*, const char*) = NULL;
static long (*real_sysconf)(int) = NULL;

// Обёртка для open()
static int do_open(const char *path, int flags, mode_t mode) {
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    if (strcmp(path, "/proc/cpuinfo")==0) return real_open(FAKE_CPUINFO, flags, mode);
    if (strcmp(path, "/proc/stat"   )==0) return real_open(FAKE_STAT,    flags, mode);
    return real_open(path, flags, mode);
}
int open(const char *path, int flags, ...) {
    mode_t m = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        m = va_arg(ap, mode_t);
        va_end(ap);
    }
    return do_open(path, flags, m);
}
int openat(int dirfd, const char *path, int flags, ...) {
    mode_t m = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        m = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    if (strcmp(path, "/proc/cpuinfo")==0) return real_openat(dirfd, FAKE_CPUINFO, flags, m);
    if (strcmp(path, "/proc/stat"   )==0) return real_openat(dirfd, FAKE_STAT,    flags, m);
    return real_openat(dirfd, path, flags, m);
}
FILE *fopen(const char *path, const char *mode) {
    if (!real_fopen) real_fopen = dlsym(RTLD_NEXT, "fopen");
    if (strcmp(path, "/proc/cpuinfo")==0) return real_fopen(FAKE_CPUINFO, mode);
    if (strcmp(path, "/proc/stat"   )==0) return real_fopen(FAKE_STAT,    mode);
    return real_fopen(path, mode);
}

// Подмена sysconf(_SC_NPROCESSORS_*)
#define FAKE_CPUS 12
long sysconf(int name) {
    if (!real_sysconf) real_sysconf = dlsym(RTLD_NEXT, "sysconf");
    if (name == _SC_NPROCESSORS_ONLN || name == _SC_NPROCESSORS_CONF)
        return FAKE_CPUS;
    return real_sysconf(name);
}

// Подмена get_nprocs()
int get_nprocs(void)       { return FAKE_CPUS; }
int get_nprocs_conf(void)  { return FAKE_CPUS; }
int __get_nprocs(void)     { return FAKE_CPUS; }
int __get_nprocs_conf(void){ return FAKE_CPUS; }

// Перехват sched_getaffinity (чтобы nproc увидел нужное число процессоров)
int sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask) {
    CPU_ZERO(mask);
    for (int i = 0; i < FAKE_CPUS; i++) CPU_SET(i, mask);
    return 0;
}
EOF

# Пересобираем
gcc -shared -fPIC -O2 -o /root/libfakeproc.so /root/fake_proc/fakeproc.c -ldl

# Подгружаем
export LD_PRELOAD=/root/libfakeproc.so

# Проверяем
nproc                             # → должно быть 12
cat /proc/cpuinfo | grep ^processor | wc -l   # → 12
cat /proc/stat | grep ^cpu[0-9] | wc -l       # → 12
cat /proc/cpuinfo | grep "cpu MHz" | head -n 12  # → 4700.000 x12
