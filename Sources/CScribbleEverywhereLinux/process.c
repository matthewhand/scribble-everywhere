#include "CPalimpsestLinux.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

void palimpsest_process_terminate(int pid, int needs_reap) {
    if (pid <= 0 || !needs_reap) return;
    // A tool may launch a legitimate application; only signal its direct
    // child and close our own pipes, never a process group or descendants.
    kill(pid, SIGKILL);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

int palimpsest_process_poll(int pid, int *status) {
    int raw;
    pid_t result = waitpid(pid, &raw, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) return -1;
    if (WIFEXITED(raw)) *status = WEXITSTATUS(raw);
    else if (WIFSIGNALED(raw)) *status = 128 + WTERMSIG(raw);
    else *status = -1;
    return 1;
}

int palimpsest_process_spawn(const char *path, char *const *argv, int *pid,
                             int *stdout_fd, int *stderr_fd) {
    int out[2] = {-1, -1}, err[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    int actions_ready = 0, attr_ready = 0, result = -1;
    pid_t child = -1;
    if (pipe2(out, O_CLOEXEC) || pipe2(err, O_CLOEXEC)) goto cleanup;
    // Preserve correct dup/close ordering even when the daemon inherited a
    // closed standard descriptor and pipe2 reused descriptor 0, 1 or 2.
    int *fds[] = {&out[0], &out[1], &err[0], &err[1]};
    for (int i = 0; i < 4; i++) {
        if (*fds[i] >= 3) continue;
        int duplicate = fcntl(*fds[i], F_DUPFD_CLOEXEC, 3);
        if (duplicate < 0) goto cleanup;
        close(*fds[i]);
        *fds[i] = duplicate;
    }
    if (posix_spawn_file_actions_init(&actions)) goto cleanup;
    actions_ready = 1;
    if (posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) ||
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) ||
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO) ||
        posix_spawn_file_actions_addclose(&actions, out[0]) ||
        posix_spawn_file_actions_addclose(&actions, out[1]) ||
        posix_spawn_file_actions_addclose(&actions, err[0]) ||
        posix_spawn_file_actions_addclose(&actions, err[1])) goto cleanup;
    if (posix_spawnattr_init(&attr)) goto cleanup;
    attr_ready = 1;
    sigset_t defaults, mask;
    if (sigemptyset(&defaults) || sigemptyset(&mask) ||
        sigaddset(&defaults, SIGHUP) || sigaddset(&defaults, SIGINT) ||
        sigaddset(&defaults, SIGQUIT) || sigaddset(&defaults, SIGTERM) ||
        sigaddset(&defaults, SIGPIPE) ||
        posix_spawnattr_setsigdefault(&attr, &defaults) ||
        posix_spawnattr_setsigmask(&attr, &mask) ||
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) goto cleanup;
    // The daemon ignores SIGPIPE and its host may block or ignore shutdown
    // signals. Restore normal behavior in the child without touching the
    // daemon's own signal dispositions or mask.
    if (posix_spawn(&child, path, &actions, &attr, argv, environ)) goto cleanup;
    close(out[1]); out[1] = -1;
    close(err[1]); err[1] = -1;
    int out_flags = fcntl(out[0], F_GETFL);
    int err_flags = fcntl(err[0], F_GETFL);
    if (out_flags < 0 || err_flags < 0 || fcntl(out[0], F_SETFL, out_flags | O_NONBLOCK) < 0 ||
        fcntl(err[0], F_SETFL, err_flags | O_NONBLOCK) < 0) {
        palimpsest_process_terminate(child, 1);
        goto cleanup;
    }
    *pid = (int)child;
    *stdout_fd = out[0]; out[0] = -1;
    *stderr_fd = err[0]; err[0] = -1;
    result = 0;
cleanup:
    if (attr_ready) posix_spawnattr_destroy(&attr);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    for (int i = 0; i < 2; i++) {
        if (out[i] >= 0) close(out[i]);
        if (err[i] >= 0) close(err[i]);
    }
    return result;
}
