#ifndef TRACEWAY_SIGNAL_SUPPORT_H
#define TRACEWAY_SIGNAL_SUPPORT_H

#include <stdbool.h>
#include <signal.h>

typedef void (*tw_signal_callback)(int, siginfo_t *, void *);

bool tw_try_lock_crash_record(void);
void tw_unlock_crash_record(void);
bool tw_crash_record_busy(void);
void tw_suppress_crash_record(bool value);
bool tw_crash_record_suppressed(void);
void tw_publish_metadata(void *block);
void *tw_current_metadata(void);
void tw_install_signal(int signo, tw_signal_callback callback);
void tw_uninstall_signal(int signo, tw_signal_callback callback);
void tw_forward_signal(int signo, siginfo_t *info, void *context, tw_signal_callback callback);

#endif
