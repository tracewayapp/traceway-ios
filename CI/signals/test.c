#include "TracewaySignalSupport.h"
#include <assert.h>
#include <stddef.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t captured, delivered, same_context, masked;
static siginfo_t *original_info;
static void *original_context;

static void previous(int sig, siginfo_t *info, void *context) {
    sigset_t mask;
    sigprocmask(SIG_SETMASK, NULL, &mask);
    masked = sigismember(&mask, SIGUSR2) && sigismember(&mask, sig);
    same_context = original_info == info && original_context == context;
    delivered++;
}

static void record(int sig, siginfo_t *info, void *context) {
    captured++;
    original_info = info;
    original_context = context;
    tw_forward_signal(sig, info, context, record);
}

static void later(int sig) {
    (void)sig;
    delivered++;
}

// Exercise a delayed callback while another thread repeatedly replaces the
// predecessor. The callback and its sa_mask must always come from one action.
static atomic_bool forwarding;
static void expect_blocked(int sig) {
    (void)sig;
    sigset_t mask;
    sigprocmask(SIG_SETMASK, NULL, &mask);
    assert(sigismember(&mask, SIGUSR1) == 1);
}
static void expect_unblocked(int sig) {
    (void)sig;
    sigset_t mask;
    sigprocmask(SIG_SETMASK, NULL, &mask);
    assert(sigismember(&mask, SIGUSR1) == 0);
}
static void *deliver_while_reconfiguring(void *unused) {
    (void)unused;
    while (atomic_load(&forwarding))
        tw_forward_signal(SIGUSR2, NULL, NULL, NULL);
    return NULL;
}
static void test_reconfiguration(void) {
    struct sigaction a = {0}, b = {0};
    a.sa_handler = expect_blocked;
    sigemptyset(&a.sa_mask);
    sigaddset(&a.sa_mask, SIGUSR1);
    b.sa_handler = expect_unblocked;
    sigemptyset(&b.sa_mask);
    sigaction(SIGUSR2, &a, NULL);
    tw_install_signal(SIGUSR2, record);
    atomic_store(&forwarding, true);
    pthread_t worker;
    assert(pthread_create(&worker, NULL, deliver_while_reconfiguring, NULL) == 0);
    for (int i = 0; i < 4000; i++) {
        tw_uninstall_signal(SIGUSR2, record);
        sigaction(SIGUSR2, i % 2 ? &a : &b, NULL);
        tw_install_signal(SIGUSR2, record);
    }
    atomic_store(&forwarding, false);
    assert(pthread_join(worker, NULL) == 0);
    tw_uninstall_signal(SIGUSR2, record);
}

int main(void) {
    assert(tw_try_lock_crash_record());
    assert(!tw_try_lock_crash_record());
    tw_unlock_crash_record();

    struct sigaction prior = {0};
    sigemptyset(&prior.sa_mask);
    sigaddset(&prior.sa_mask, SIGUSR2);
    prior.sa_flags = SA_SIGINFO;
    prior.sa_sigaction = previous;
    sigaction(SIGSEGV, &prior, NULL);
    tw_install_signal(SIGSEGV, record);
    raise(SIGSEGV);
    assert(captured == 1 && delivered == 1 && same_context && masked);
    tw_uninstall_signal(SIGSEGV, record);

    tw_install_signal(SIGSEGV, record);
    tw_uninstall_signal(SIGSEGV, record);
    raise(SIGSEGV);
    assert(captured == 1 && delivered == 2);

    tw_install_signal(SIGUSR1, record);
    signal(SIGUSR1, later);
    tw_uninstall_signal(SIGUSR1, record);
    tw_install_signal(SIGUSR1, record);
    raise(SIGUSR1);
    assert(captured == 1 && delivered == 3);

    test_reconfiguration();

    // SIGTERM has a default terminating disposition without a core dump.
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        signal(SIGTERM, SIG_DFL);
        tw_install_signal(SIGTERM, record);
        raise(SIGTERM);
        _exit(1);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
}
