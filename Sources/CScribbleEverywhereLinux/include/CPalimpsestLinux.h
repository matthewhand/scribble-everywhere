// C interop for the Linux shell: PNG encoding and the Wayland session.
// The Wayland listeners live in wayland.c so Swift does not depend on
// protocol struct layouts, which change with libwayland versions.

#ifndef C_PALIMPEST_LINUX_H
#define C_PALIMPEST_LINUX_H

#include <stddef.h>
#include <stdint.h>

/// Writes a top-left-origin straight RGBA8 buffer as a PNG. Returns 0 on success.
int palimpsest_write_png_rgba(const char *path, int width, int height, int stride,
                              const uint8_t *rgba);

/// Spawn a tool with stdout/stderr pipes. `argv`
/// includes argv[0] and a terminating NULL. Returns 0 on success.
int palimpsest_process_spawn(const char *path, char *const *argv, int *pid,
                             int *stdout_fd, int *stderr_fd);
/// Nonblocking reap: 0 while running, 1 when reaped, -1 on error.
int palimpsest_process_poll(int pid, int *status);
/// Kill and reap the direct child if it has not already been reaped.
void palimpsest_process_terminate(int pid, int needs_reap);

enum {
    PALIMPSEST_EVENT_POINTER_ENTER = 1,
    PALIMPSEST_EVENT_POINTER_LEAVE = 2,
    PALIMPSEST_EVENT_POINTER_MOTION = 3,
    PALIMPSEST_EVENT_POINTER_BUTTON = 4,
    PALIMPSEST_EVENT_TOUCH_DOWN = 5,
    PALIMPSEST_EVENT_TOUCH_UP = 6,
    PALIMPSEST_EVENT_TOUCH_MOTION = 7,
    PALIMPSEST_EVENT_TABLET_PROXIMITY = 8,
    PALIMPSEST_EVENT_TABLET_DOWN = 9,
    PALIMPSEST_EVENT_TABLET_UP = 10,
    PALIMPSEST_EVENT_TABLET_MOTION = 11,
    PALIMPSEST_EVENT_TABLET_PRESSURE = 12,
    PALIMPSEST_EVENT_TABLET_BUTTON = 13,
    PALIMPSEST_EVENT_TABLET_FRAME = 14,
    PALIMPSEST_EVENT_KEY = 15,
    PALIMPSEST_EVENT_CLOSED = 16,
    PALIMPSEST_EVENT_TOUCH_CANCEL = 17,
    PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET = 18
};

/// One input event. Coordinates are surface-local logical pixels.
/// `pressed` is 1 for a press / proximity-in, 0 for a release / proximity-out.
/// Key `code` is a Linux evdev code. Tablet pressure is 0...1.
typedef struct palimpsest_event {
    int32_t kind;
    int32_t output_id;
    double x;
    double y;
    double pressure;
    int32_t pressed;
    uint32_t code;
    int32_t touch_id;
} palimpsest_event;

typedef void (*palimpsest_event_fn)(const struct palimpsest_event *event, void *userdata);

typedef struct palimpsest_output_info {
    int32_t id;
    int32_t x;
    int32_t y;
    int32_t scale;
    int32_t logical_width;
    int32_t logical_height;
    int32_t buffer_width;
    int32_t buffer_height;
    int32_t margin_top;
    int32_t margin_right;
    int32_t margin_bottom;
    int32_t margin_left;
} palimpsest_output_info;

/// Connects to the compositor. On success `*out_session` is a session pointer
/// the caller frees with `palimpsest_wl_destroy`. Events are delivered on the
/// thread that calls `palimpsest_wl_poll` or `palimpsest_wl_roundtrip`.
int palimpsest_wl_connect(void **out_session, palimpsest_event_fn on_event, void *userdata,
                          char *error, size_t error_len);

void palimpsest_wl_destroy(void *session);

/// Insets the overlay from the screen edges so a bar stays clickable.
/// Call before `palimpsest_wl_show`. Values are logical pixels.
void palimpsest_wl_set_margins(void *session, int32_t top, int32_t right, int32_t bottom, int32_t left);

/// Creates one overlay layer surface per output and waits until they are configured.
int palimpsest_wl_show(void *session);

/// Destroys the overlay surfaces so pointer events reach the windows underneath.
void palimpsest_wl_hide(void *session);

int palimpsest_wl_output_count(void *session);
int palimpsest_wl_output_info(void *session, int32_t index, struct palimpsest_output_info *out);

/// Copies straight RGBA into the output's buffer as premultiplied ARGB8888 and commits.
/// Returns 0 on success, -2 when both buffers are still busy (caller should retry).
int palimpsest_wl_present(void *session, int32_t output_id, const uint8_t *rgba,
                          int32_t width, int32_t height, int32_t stride);

/// Dispatches compositor events. `extra_fds` are polled alongside the Wayland fd.
/// `ready[i]` is set to 1 when `extra_fds[i]` is readable. Returns -1 if the
/// compositor disconnects.
int palimpsest_wl_poll(void *session, const int *extra_fds, int extra_count, int *ready, int timeout_ms);

int palimpsest_wl_roundtrip(void *session);

#endif
