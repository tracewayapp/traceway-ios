#include "TracewaySignalSupport.h"
#include <stdatomic.h>
#include <stddef.h>
#include <sched.h>
#include <sys/ucontext.h>

// No signal-handler operation may fall back to a blocking implementation.
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2 && ATOMIC_POINTER_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2, "lock-free atomics required");
static atomic_bool capture_gate;
static _Atomic(void *) metadata;
static atomic_bool suppress_record;
// Configuration writers are serialized. An asynchronous reader copies the
// published slot without waiting, even if it interrupted a writer.
static struct {
    struct sigaction actions[2];
    atomic_uint current, readers;
} previous[NSIG];

static struct sigaction read_previous(int signo) {
    atomic_fetch_add(&previous[signo].readers, 1);
    struct sigaction action = previous[signo].actions[atomic_load(&previous[signo].current)];
    atomic_fetch_sub(&previous[signo].readers, 1);
    return action;
}

static void publish_previous(int signo, const struct sigaction *action) {
    unsigned spare = 1 - atomic_load(&previous[signo].current);
    // A reader that started before the last publication can still be copying
    // the spare. Any reader starting after this check uses the current slot.
    while (atomic_load(&previous[signo].readers)) sched_yield();
    previous[signo].actions[spare] = *action;
    atomic_store(&previous[signo].current, spare);
}

// A reporter installed after Traceway may still chain back to our callback.
static bool chained[NSIG];

bool tw_try_lock_crash_record(void) {
    bool idle = false;
    return atomic_compare_exchange_strong(&capture_gate, &idle, true);
}

void tw_unlock_crash_record(void) {
    atomic_store(&capture_gate, false);
}

void tw_suppress_crash_record(bool value) {
    atomic_store(&suppress_record, value);
}

bool tw_crash_record_suppressed(void) {
    return atomic_load(&suppress_record);
}

bool tw_crash_record_busy(void) {
    return atomic_load(&capture_gate);
}

void tw_publish_metadata(void *block) {
    atomic_store(&metadata, block);
}

void *tw_current_metadata(void) {
    return atomic_load(&metadata);
}

void tw_install_signal(int signo, tw_signal_callback callback) {
    struct sigaction current;
    if (signo <= 0 || signo >= NSIG || sigaction(signo, NULL, &current) != 0) return;
    if (current.sa_sigaction == callback) return;
    if (chained[signo] && current.sa_handler != read_previous(signo).sa_handler) return;
    chained[signo] = false;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = callback;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    // Publish the predecessor before the new action can run on another thread.
    publish_previous(signo, &current);
    sigaction(signo, &action, NULL);
}

void tw_uninstall_signal(int signo, tw_signal_callback callback) {
    struct sigaction current;
    if (signo <= 0 || signo >= NSIG || sigaction(signo, NULL, &current) != 0) return;
    if (current.sa_sigaction == callback) {
        struct sigaction prior = read_previous(signo);
        sigaction(signo, &prior, NULL);
        chained[signo] = false;
    } else {
        chained[signo] = current.sa_handler != read_previous(signo).sa_handler;
    }
}

// Darwin can supply hardware fault codes even for a software raise(). Forward
// the original info/context to callbacks, and redeliver a defaulted signal
// explicitly. Returning to the interrupted instruction cannot reproduce raise().
void tw_forward_signal(int signo, siginfo_t *info, void *context, tw_signal_callback callback) {
    if (signo <= 0 || signo >= NSIG) return;
    struct sigaction prior = read_previous(signo);
    if (prior.sa_handler == SIG_DFL) {
        sigaction(signo, &prior, NULL);
        raise(signo);
        return;
    }
    struct sigaction current;
    if (sigaction(signo, NULL, &current) == 0 && current.sa_sigaction == callback) {
        if (prior.sa_flags & SA_RESETHAND) signal(signo, SIG_DFL);
        else sigaction(signo, &prior, NULL);
    }
    if (prior.sa_handler == SIG_IGN) return;

    sigset_t saved;
    sigprocmask(SIG_SETMASK, NULL, &saved);
    sigset_t mask = context ? ((const ucontext_t *)context)->uc_sigmask : saved;
    for (int i = 1; i < NSIG; i++)
        if (sigismember(&prior.sa_mask, i) == 1) sigaddset(&mask, i);
    if (!(prior.sa_flags & SA_NODEFER)) sigaddset(&mask, signo);
    sigprocmask(SIG_SETMASK, &mask, NULL);
    if (prior.sa_flags & SA_SIGINFO) prior.sa_sigaction(signo, info, context);
    else prior.sa_handler(signo);
    sigprocmask(SIG_SETMASK, &saved, NULL);
}
