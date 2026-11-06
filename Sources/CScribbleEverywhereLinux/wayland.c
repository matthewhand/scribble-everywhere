#include "CPalimpsestLinux.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-cursor.h>

#include "wlr-layer-shell-unstable-v1.h"
#include "tablet-unstable-v2.h"

enum { MAX_OUTPUTS = 8, MAX_EXTRA_FDS = 32 };

struct shm_buffer {
    struct wl_buffer *buffer;
    void *data;
    size_t size;
    int width;
    int height;
    int stride;
    int busy;
};

struct output {
    struct palimpsest_wl *wl;
    uint32_t registry_name;
    int id;
    int alive;
    struct wl_output *output;
    struct wl_surface *surface;
    struct zwlr_layer_surface_v1 *layer;
    int x;
    int y;
    int scale;
    int mode_w;
    int mode_h;
    int logical_w;
    int logical_h;
    int configured;
    struct shm_buffer buffers[2];
};

struct palimpsest_wl {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_pointer *pointer;
    struct wl_keyboard *keyboard;
    struct wl_touch *touch;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zwp_tablet_manager_v2 *tablet_manager;
    struct zwp_tablet_seat_v2 *tablet_seat;

    struct wl_cursor_theme *cursor_theme;
    struct wl_cursor_image *cursor_image;
    struct wl_buffer *cursor_buffer;
    struct wl_surface *cursor_surface;
    int cursor_scale;

    struct output outputs[MAX_OUTPUTS];
    int output_count;

    int margin_top;
    int margin_right;
    int margin_bottom;
    int margin_left;

    int pointer_output;
    double pointer_x;
    double pointer_y;
    int tablet_output;
    double tablet_x;
    double tablet_y;
    double tablet_pressure;

    palimpsest_event_fn on_event;
    void *userdata;
};

static void emit(struct palimpsest_wl *wl, struct palimpsest_event event) {
    if (wl->on_event) {
        wl->on_event(&event, wl->userdata);
    }
}

static uint32_t cap_version(uint32_t offered, uint32_t wanted) {
    return offered < wanted ? offered : wanted;
}

static struct output *output_by_id(struct palimpsest_wl *wl, int32_t id) {
    for (int i = 0; i < wl->output_count; i++) {
        if (wl->outputs[i].alive && wl->outputs[i].id == id) {
            return &wl->outputs[i];
        }
    }
    return NULL;
}

static struct output *output_for_surface(struct palimpsest_wl *wl, struct wl_surface *surface) {
    if (!surface) {
        return NULL;
    }
    for (int i = 0; i < wl->output_count; i++) {
        if (wl->outputs[i].alive && wl->outputs[i].surface == surface) {
            return &wl->outputs[i];
        }
    }
    return NULL;
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)buffer;
    struct shm_buffer *buf = data;
    buf->busy = 0;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static void buffer_destroy(struct shm_buffer *buf) {
    if (buf->buffer) {
        wl_buffer_destroy(buf->buffer);
    }
    if (buf->data && buf->size) {
        munmap(buf->data, buf->size);
    }
    memset(buf, 0, sizeof(*buf));
}

static int buffer_create(struct palimpsest_wl *wl, struct shm_buffer *buf, int width, int height) {
    int stride = width * 4;
    size_t size = (size_t)stride * (size_t)height;
    int fd = memfd_create("palimpsest", MFD_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return -1;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(wl->shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (!buffer) {
        munmap(data, size);
        return -1;
    }
    buf->buffer = buffer;
    buf->data = data;
    buf->size = size;
    buf->width = width;
    buf->height = height;
    buf->stride = stride;
    buf->busy = 0;
    wl_buffer_add_listener(buffer, &buffer_listener, buf);
    return 0;
}

static void output_destroy_surface(struct output *out) {
    for (int i = 0; i < 2; i++) {
        buffer_destroy(&out->buffers[i]);
    }
    if (out->layer) {
        zwlr_layer_surface_v1_destroy(out->layer);
        out->layer = NULL;
    }
    if (out->surface) {
        wl_surface_destroy(out->surface);
        out->surface = NULL;
    }
    out->configured = 0;
    out->logical_w = 0;
    out->logical_h = 0;
}

static void allocate_output_buffers(struct output *out) {
    int scale = out->scale > 0 ? out->scale : 1;
    int width = out->logical_w * scale;
    int height = out->logical_h * scale;
    if (width <= 0 || height <= 0 || !out->wl->shm) {
        return;
    }
    if (out->buffers[0].buffer && out->buffers[0].width == width && out->buffers[0].height == height) {
        return;
    }
    for (int i = 0; i < 2; i++) {
        buffer_destroy(&out->buffers[i]);
        if (buffer_create(out->wl, &out->buffers[i], width, height) != 0) {
            buffer_destroy(&out->buffers[i]);
        }
    }
    if (out->surface) {
        wl_surface_set_buffer_scale(out->surface, scale);
    }
}

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *layer,
                            uint32_t serial, uint32_t width, uint32_t height) {
    struct output *out = data;
    zwlr_layer_surface_v1_ack_configure(layer, serial);
    int scale = out->scale > 0 ? out->scale : 1;
    if (width == 0 && out->mode_w > 0) {
        width = (uint32_t)(out->mode_w / scale);
    }
    if (height == 0 && out->mode_h > 0) {
        height = (uint32_t)(out->mode_h / scale);
    }
    out->logical_w = (int)width;
    out->logical_h = (int)height;
    out->configured = 1;
    allocate_output_buffers(out);
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *layer) {
    (void)layer;
    struct output *out = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_CLOSED;
    event.output_id = out->id;
    output_destroy_surface(out);
    emit(out->wl, event);
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure,
    .closed = layer_closed,
};

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
                            int32_t physical_width, int32_t physical_height, int32_t subpixel,
                            const char *make, const char *model, int32_t transform) {
    (void)output;
    (void)physical_width;
    (void)physical_height;
    (void)subpixel;
    (void)make;
    (void)model;
    (void)transform;
    struct output *out = data;
    out->x = x;
    out->y = y;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
                        int32_t width, int32_t height, int32_t refresh) {
    (void)output;
    (void)refresh;
    if ((flags & WL_OUTPUT_MODE_CURRENT) == 0) {
        return;
    }
    struct output *out = data;
    out->mode_w = width;
    out->mode_h = height;
}

static void output_done(void *data, struct wl_output *output) {
    (void)data;
    (void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)output;
    struct output *out = data;
    out->scale = factor > 0 ? factor : 1;
}

static void output_name(void *data, struct wl_output *output, const char *name) {
    (void)data;
    (void)output;
    (void)name;
}

static void output_description(void *data, struct wl_output *output, const char *description) {
    (void)data;
    (void)output;
    (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void ensure_cursor(struct palimpsest_wl *wl, int scale) {
    if (scale < 1) {
        scale = 1;
    }
    if (wl->cursor_surface && wl->cursor_scale == scale) {
        return;
    }
    if (wl->cursor_surface) {
        wl_surface_destroy(wl->cursor_surface);
        wl->cursor_surface = NULL;
    }
    if (wl->cursor_theme) {
        wl_cursor_theme_destroy(wl->cursor_theme);
        wl->cursor_theme = NULL;
    }
    wl->cursor_image = NULL;
    wl->cursor_buffer = NULL;
    if (!wl->shm || !wl->compositor) {
        return;
    }
    wl->cursor_theme = wl_cursor_theme_load(NULL, 24 * scale, wl->shm);
    if (!wl->cursor_theme) {
        return;
    }
    struct wl_cursor *cursor = wl_cursor_theme_get_cursor(wl->cursor_theme, "crosshair");
    if (!cursor) {
        cursor = wl_cursor_theme_get_cursor(wl->cursor_theme, "left_ptr");
    }
    if (!cursor || cursor->image_count < 1) {
        return;
    }
    wl->cursor_image = cursor->images[0];
    wl->cursor_buffer = wl_cursor_image_get_buffer(wl->cursor_image);
    wl->cursor_surface = wl_compositor_create_surface(wl->compositor);
    if (!wl->cursor_surface) {
        return;
    }
    wl_surface_set_buffer_scale(wl->cursor_surface, scale);
    wl->cursor_scale = scale;
}

static void set_pointer_cursor(struct palimpsest_wl *wl, struct wl_pointer *pointer,
                               uint32_t serial, int scale) {
    ensure_cursor(wl, scale);
    if (!wl->cursor_surface || !wl->cursor_buffer || !wl->cursor_image) {
        wl_pointer_set_cursor(pointer, serial, NULL, 0, 0);
        return;
    }
    int divisor = scale > 0 ? scale : 1;
    int hotspot_x = (int)wl->cursor_image->hotspot_x / divisor;
    int hotspot_y = (int)wl->cursor_image->hotspot_y / divisor;
    wl_pointer_set_cursor(pointer, serial, wl->cursor_surface, hotspot_x, hotspot_y);
    wl_surface_attach(wl->cursor_surface, wl->cursor_buffer, 0, 0);
    wl_surface_damage(wl->cursor_surface, 0, 0,
                      (int32_t)wl->cursor_image->width / divisor,
                      (int32_t)wl->cursor_image->height / divisor);
    wl_surface_commit(wl->cursor_surface);
}

static void pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    struct palimpsest_wl *wl = data;
    struct output *out = output_for_surface(wl, surface);
    wl->pointer_output = out ? out->id : -1;
    wl->pointer_x = wl_fixed_to_double(x);
    wl->pointer_y = wl_fixed_to_double(y);
    set_pointer_cursor(wl, pointer, serial, out ? out->scale : 1);
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_POINTER_ENTER;
    event.output_id = wl->pointer_output;
    event.x = wl->pointer_x;
    event.y = wl->pointer_y;
    emit(wl, event);
}

static void pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface) {
    (void)pointer;
    (void)serial;
    (void)surface;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_POINTER_LEAVE;
    event.output_id = wl->pointer_output;
    emit(wl, event);
    wl->pointer_output = -1;
}

static void pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y) {
    (void)pointer;
    (void)time;
    struct palimpsest_wl *wl = data;
    wl->pointer_x = wl_fixed_to_double(x);
    wl->pointer_y = wl_fixed_to_double(y);
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_POINTER_MOTION;
    event.output_id = wl->pointer_output;
    event.x = wl->pointer_x;
    event.y = wl->pointer_y;
    emit(wl, event);
}

static void pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state) {
    (void)pointer;
    (void)serial;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_POINTER_BUTTON;
    event.output_id = wl->pointer_output;
    event.x = wl->pointer_x;
    event.y = wl->pointer_y;
    event.code = button;
    event.pressed = state == WL_POINTER_BUTTON_STATE_PRESSED ? 1 : 0;
    emit(wl, event);
}

static void pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time,
                         uint32_t axis, wl_fixed_t value) {
    (void)data;
    (void)pointer;
    (void)time;
    (void)axis;
    (void)value;
}

static void pointer_frame(void *data, struct wl_pointer *pointer) {
    (void)data;
    (void)pointer;
}

static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t axis_source) {
    (void)data;
    (void)pointer;
    (void)axis_source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis) {
    (void)data;
    (void)pointer;
    (void)time;
    (void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis,
                                  int32_t discrete) {
    (void)data;
    (void)pointer;
    (void)axis;
    (void)discrete;
}

static void pointer_axis_value120(void *data, struct wl_pointer *pointer, uint32_t axis,
                                  int32_t value120) {
    (void)data;
    (void)pointer;
    (void)axis;
    (void)value120;
}

static void pointer_axis_relative_direction(void *data, struct wl_pointer *pointer, uint32_t axis,
                                            uint32_t direction) {
    (void)data;
    (void)pointer;
    (void)axis;
    (void)direction;
}

static void pointer_warp(void *data, struct wl_pointer *pointer, wl_fixed_t x, wl_fixed_t y) {
    pointer_motion(data, pointer, 0, x, y);
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative_direction,
#ifdef WL_POINTER_WARP_SINCE_VERSION
    .warp = pointer_warp,
#endif
};

static void keyboard_keymap(void *data, struct wl_keyboard *keyboard, uint32_t format,
                            int32_t fd, uint32_t size) {
    (void)data;
    (void)keyboard;
    (void)format;
    (void)size;
    if (fd >= 0) {
        close(fd);
    }
}

static void keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial,
                         uint32_t time, uint32_t key, uint32_t state) {
    (void)keyboard;
    (void)serial;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_KEY;
    event.output_id = -1;
    event.code = key;
    // pressed (1) and repeated (2) both count as down. Release is 0.
    event.pressed = state == WL_KEYBOARD_KEY_STATE_RELEASED ? 0 : (int32_t)state;
    emit(wl, event);
}

static void keyboard_enter(void *data, struct wl_keyboard *keyboard, uint32_t serial,
                           struct wl_surface *surface, struct wl_array *keys) {
    (void)keyboard;
    (void)serial;
    (void)surface;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event reset = {0};
    reset.kind = PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET;
    emit(wl, reset);
    // Wayland reports the keys already held on entry separately from key
    // presses. Restore only the Ctrl state needed by overlay shortcuts.
    uint32_t *key;
    if (keys) {
        wl_array_for_each(key, keys) {
            if (*key != 29 && *key != 97) continue;
            struct palimpsest_event event = {0};
            event.kind = PALIMPSEST_EVENT_KEY;
            event.code = *key;
            event.pressed = 1;
            emit(wl, event);
        }
    }
}

static void keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial,
                           struct wl_surface *surface) {
    (void)keyboard;
    (void)serial;
    (void)surface;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET;
    emit(data, event);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *keyboard, uint32_t serial,
                               uint32_t mods_depressed, uint32_t mods_latched,
                               uint32_t mods_locked, uint32_t group) {
    (void)data;
    (void)keyboard;
    (void)serial;
    (void)mods_depressed;
    (void)mods_latched;
    (void)mods_locked;
    (void)group;
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *keyboard, int32_t rate,
                                 int32_t delay) {
    (void)data;
    (void)keyboard;
    (void)rate;
    (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

static void touch_down(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time,
                       struct wl_surface *surface, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)touch;
    (void)serial;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct output *out = output_for_surface(wl, surface);
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TOUCH_DOWN;
    event.output_id = out ? out->id : -1;
    event.x = wl_fixed_to_double(x);
    event.y = wl_fixed_to_double(y);
    event.touch_id = id;
    event.pressed = 1;
    emit(wl, event);
}

static void touch_up(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time, int32_t id) {
    (void)touch;
    (void)serial;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TOUCH_UP;
    event.output_id = -1;
    event.touch_id = id;
    event.pressed = 0;
    emit(wl, event);
}

static void touch_motion(void *data, struct wl_touch *touch, uint32_t time, int32_t id,
                         wl_fixed_t x, wl_fixed_t y) {
    (void)touch;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TOUCH_MOTION;
    event.output_id = -1;
    event.x = wl_fixed_to_double(x);
    event.y = wl_fixed_to_double(y);
    event.touch_id = id;
    emit(wl, event);
}

static void touch_frame(void *data, struct wl_touch *touch) {
    (void)data;
    (void)touch;
}

static void touch_cancel(void *data, struct wl_touch *touch) {
    (void)touch;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TOUCH_CANCEL;
    emit(data, event);
}

static void touch_shape(void *data, struct wl_touch *touch, int32_t id, wl_fixed_t major,
                        wl_fixed_t minor) {
    (void)data;
    (void)touch;
    (void)id;
    (void)major;
    (void)minor;
}

static void touch_orientation(void *data, struct wl_touch *touch, int32_t id,
                              wl_fixed_t orientation) {
    (void)data;
    (void)touch;
    (void)id;
    (void)orientation;
}

static const struct wl_touch_listener touch_listener = {
    .down = touch_down,
    .up = touch_up,
    .motion = touch_motion,
    .frame = touch_frame,
    .cancel = touch_cancel,
    .shape = touch_shape,
    .orientation = touch_orientation,
};

static void tablet_tool_proximity_in(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t serial,
                                     struct zwp_tablet_v2 *tablet, struct wl_surface *surface) {
    (void)tool;
    (void)serial;
    (void)tablet;
    struct palimpsest_wl *wl = data;
    struct output *out = output_for_surface(wl, surface);
    wl->tablet_output = out ? out->id : -1;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_PROXIMITY;
    event.output_id = wl->tablet_output;
    event.pressed = 1;
    emit(wl, event);
}

static void tablet_tool_proximity_out(void *data, struct zwp_tablet_tool_v2 *tool) {
    (void)tool;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_PROXIMITY;
    event.output_id = wl->tablet_output;
    event.pressed = 0;
    emit(wl, event);
    wl->tablet_output = -1;
}

static void tablet_tool_down(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t serial) {
    (void)tool;
    (void)serial;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_DOWN;
    event.output_id = wl->tablet_output;
    event.x = wl->tablet_x;
    event.y = wl->tablet_y;
    event.pressure = wl->tablet_pressure;
    event.pressed = 1;
    emit(wl, event);
}

static void tablet_tool_up(void *data, struct zwp_tablet_tool_v2 *tool) {
    (void)tool;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_UP;
    event.output_id = wl->tablet_output;
    event.x = wl->tablet_x;
    event.y = wl->tablet_y;
    event.pressed = 0;
    emit(wl, event);
}

static void tablet_tool_motion(void *data, struct zwp_tablet_tool_v2 *tool, wl_fixed_t x, wl_fixed_t y) {
    (void)tool;
    struct palimpsest_wl *wl = data;
    wl->tablet_x = wl_fixed_to_double(x);
    wl->tablet_y = wl_fixed_to_double(y);
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_MOTION;
    event.output_id = wl->tablet_output;
    event.x = wl->tablet_x;
    event.y = wl->tablet_y;
    emit(wl, event);
}

static void tablet_tool_pressure(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t pressure) {
    (void)tool;
    struct palimpsest_wl *wl = data;
    wl->tablet_pressure = (double)pressure / 65535.0;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_PRESSURE;
    event.output_id = wl->tablet_output;
    event.pressure = wl->tablet_pressure;
    emit(wl, event);
}

static void tablet_tool_button(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t serial,
                               uint32_t button, uint32_t state) {
    (void)tool;
    (void)serial;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_BUTTON;
    event.output_id = wl->tablet_output;
    event.code = button;
    event.pressed = state == ZWP_TABLET_TOOL_V2_BUTTON_STATE_PRESSED ? 1 : 0;
    emit(wl, event);
}

static void tablet_tool_frame(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t time) {
    (void)tool;
    (void)time;
    struct palimpsest_wl *wl = data;
    struct palimpsest_event event = {0};
    event.kind = PALIMPSEST_EVENT_TABLET_FRAME;
    event.output_id = wl->tablet_output;
    event.x = wl->tablet_x;
    event.y = wl->tablet_y;
    event.pressure = wl->tablet_pressure;
    emit(wl, event);
}

static void tablet_tool_type(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t type) {
    (void)data;
    (void)tool;
    (void)type;
}

static void tablet_tool_hardware_serial(void *data, struct zwp_tablet_tool_v2 *tool,
                                        uint32_t hi, uint32_t lo) {
    (void)data;
    (void)tool;
    (void)hi;
    (void)lo;
}

static void tablet_tool_hardware_id_wacom(void *data, struct zwp_tablet_tool_v2 *tool,
                                          uint32_t hi, uint32_t lo) {
    (void)data;
    (void)tool;
    (void)hi;
    (void)lo;
}

static void tablet_tool_capability(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t capability) {
    (void)data;
    (void)tool;
    (void)capability;
}

static void tablet_tool_done(void *data, struct zwp_tablet_tool_v2 *tool) {
    (void)data;
    (void)tool;
}

static void tablet_tool_removed(void *data, struct zwp_tablet_tool_v2 *tool) {
    (void)data;
    (void)tool;
}

static void tablet_tool_distance(void *data, struct zwp_tablet_tool_v2 *tool, uint32_t distance) {
    (void)data;
    (void)tool;
    (void)distance;
}

static void tablet_tool_tilt(void *data, struct zwp_tablet_tool_v2 *tool, wl_fixed_t tilt_x,
                             wl_fixed_t tilt_y) {
    (void)data;
    (void)tool;
    (void)tilt_x;
    (void)tilt_y;
}

static void tablet_tool_rotation(void *data, struct zwp_tablet_tool_v2 *tool, wl_fixed_t degrees) {
    (void)data;
    (void)tool;
    (void)degrees;
}

static void tablet_tool_slider(void *data, struct zwp_tablet_tool_v2 *tool, int32_t position) {
    (void)data;
    (void)tool;
    (void)position;
}

static void tablet_tool_wheel(void *data, struct zwp_tablet_tool_v2 *tool, wl_fixed_t degrees,
                              int32_t clicks) {
    (void)data;
    (void)tool;
    (void)degrees;
    (void)clicks;
}

static const struct zwp_tablet_tool_v2_listener tablet_tool_listener = {
    .type = tablet_tool_type,
    .hardware_serial = tablet_tool_hardware_serial,
    .hardware_id_wacom = tablet_tool_hardware_id_wacom,
    .capability = tablet_tool_capability,
    .done = tablet_tool_done,
    .removed = tablet_tool_removed,
    .proximity_in = tablet_tool_proximity_in,
    .proximity_out = tablet_tool_proximity_out,
    .down = tablet_tool_down,
    .up = tablet_tool_up,
    .motion = tablet_tool_motion,
    .pressure = tablet_tool_pressure,
    .distance = tablet_tool_distance,
    .tilt = tablet_tool_tilt,
    .rotation = tablet_tool_rotation,
    .slider = tablet_tool_slider,
    .wheel = tablet_tool_wheel,
    .button = tablet_tool_button,
    .frame = tablet_tool_frame,
};

static void tablet_name(void *data, struct zwp_tablet_v2 *tablet, const char *name) {
    (void)data;
    (void)tablet;
    (void)name;
}

static void tablet_id(void *data, struct zwp_tablet_v2 *tablet, uint32_t vid, uint32_t pid) {
    (void)data;
    (void)tablet;
    (void)vid;
    (void)pid;
}

static void tablet_path(void *data, struct zwp_tablet_v2 *tablet, const char *path) {
    (void)data;
    (void)tablet;
    (void)path;
}

static void tablet_done(void *data, struct zwp_tablet_v2 *tablet) {
    (void)data;
    (void)tablet;
}

static void tablet_removed(void *data, struct zwp_tablet_v2 *tablet) {
    (void)data;
    (void)tablet;
}

static const struct zwp_tablet_v2_listener tablet_listener = {
    .name = tablet_name,
    .id = tablet_id,
    .path = tablet_path,
    .done = tablet_done,
    .removed = tablet_removed,
};

static void tablet_pad_ring_source(void *data, struct zwp_tablet_pad_ring_v2 *ring, uint32_t source) {
    (void)data;
    (void)ring;
    (void)source;
}

static void tablet_pad_ring_angle(void *data, struct zwp_tablet_pad_ring_v2 *ring,
                                  wl_fixed_t degrees) {
    (void)data;
    (void)ring;
    (void)degrees;
}

static void tablet_pad_ring_stop(void *data, struct zwp_tablet_pad_ring_v2 *ring) {
    (void)data;
    (void)ring;
}

static void tablet_pad_ring_frame(void *data, struct zwp_tablet_pad_ring_v2 *ring, uint32_t time) {
    (void)data;
    (void)ring;
    (void)time;
}

static const struct zwp_tablet_pad_ring_v2_listener tablet_pad_ring_listener = {
    .source = tablet_pad_ring_source,
    .angle = tablet_pad_ring_angle,
    .stop = tablet_pad_ring_stop,
    .frame = tablet_pad_ring_frame,
};

static void tablet_pad_strip_source(void *data, struct zwp_tablet_pad_strip_v2 *strip,
                                    uint32_t source) {
    (void)data;
    (void)strip;
    (void)source;
}

static void tablet_pad_strip_position(void *data, struct zwp_tablet_pad_strip_v2 *strip,
                                      uint32_t position) {
    (void)data;
    (void)strip;
    (void)position;
}

static void tablet_pad_strip_stop(void *data, struct zwp_tablet_pad_strip_v2 *strip) {
    (void)data;
    (void)strip;
}

static void tablet_pad_strip_frame(void *data, struct zwp_tablet_pad_strip_v2 *strip, uint32_t time) {
    (void)data;
    (void)strip;
    (void)time;
}

static const struct zwp_tablet_pad_strip_v2_listener tablet_pad_strip_listener = {
    .source = tablet_pad_strip_source,
    .position = tablet_pad_strip_position,
    .stop = tablet_pad_strip_stop,
    .frame = tablet_pad_strip_frame,
};

static void tablet_pad_group_buttons(void *data, struct zwp_tablet_pad_group_v2 *group,
                                     struct wl_array *buttons) {
    (void)data;
    (void)group;
    (void)buttons;
}

static void tablet_pad_group_ring(void *data, struct zwp_tablet_pad_group_v2 *group,
                                  struct zwp_tablet_pad_ring_v2 *ring) {
    (void)group;
    zwp_tablet_pad_ring_v2_add_listener(ring, &tablet_pad_ring_listener, data);
}

static void tablet_pad_group_strip(void *data, struct zwp_tablet_pad_group_v2 *group,
                                   struct zwp_tablet_pad_strip_v2 *strip) {
    (void)group;
    zwp_tablet_pad_strip_v2_add_listener(strip, &tablet_pad_strip_listener, data);
}

static void tablet_pad_group_modes(void *data, struct zwp_tablet_pad_group_v2 *group, uint32_t modes) {
    (void)data;
    (void)group;
    (void)modes;
}

static void tablet_pad_group_done(void *data, struct zwp_tablet_pad_group_v2 *group) {
    (void)data;
    (void)group;
}

static void tablet_pad_group_mode_switch(void *data, struct zwp_tablet_pad_group_v2 *group,
                                         uint32_t time, uint32_t serial, uint32_t mode) {
    (void)data;
    (void)group;
    (void)time;
    (void)serial;
    (void)mode;
}

static const struct zwp_tablet_pad_group_v2_listener tablet_pad_group_listener = {
    .buttons = tablet_pad_group_buttons,
    .ring = tablet_pad_group_ring,
    .strip = tablet_pad_group_strip,
    .modes = tablet_pad_group_modes,
    .done = tablet_pad_group_done,
    .mode_switch = tablet_pad_group_mode_switch,
};

static void tablet_pad_group(void *data, struct zwp_tablet_pad_v2 *pad,
                             struct zwp_tablet_pad_group_v2 *group) {
    (void)pad;
    zwp_tablet_pad_group_v2_add_listener(group, &tablet_pad_group_listener, data);
}

static void tablet_pad_path(void *data, struct zwp_tablet_pad_v2 *pad, const char *path) {
    (void)data;
    (void)pad;
    (void)path;
}

static void tablet_pad_buttons(void *data, struct zwp_tablet_pad_v2 *pad, uint32_t buttons) {
    (void)data;
    (void)pad;
    (void)buttons;
}

static void tablet_pad_done(void *data, struct zwp_tablet_pad_v2 *pad) {
    (void)data;
    (void)pad;
}

static void tablet_pad_button(void *data, struct zwp_tablet_pad_v2 *pad, uint32_t time,
                              uint32_t button, uint32_t state) {
    (void)data;
    (void)pad;
    (void)time;
    (void)button;
    (void)state;
}

static void tablet_pad_enter(void *data, struct zwp_tablet_pad_v2 *pad, uint32_t serial,
                             struct zwp_tablet_v2 *tablet, struct wl_surface *surface) {
    (void)data;
    (void)pad;
    (void)serial;
    (void)tablet;
    (void)surface;
}

static void tablet_pad_leave(void *data, struct zwp_tablet_pad_v2 *pad, uint32_t serial,
                             struct wl_surface *surface) {
    (void)data;
    (void)pad;
    (void)serial;
    (void)surface;
}

static void tablet_pad_removed(void *data, struct zwp_tablet_pad_v2 *pad) {
    (void)data;
    (void)pad;
}

static const struct zwp_tablet_pad_v2_listener tablet_pad_listener = {
    .group = tablet_pad_group,
    .path = tablet_pad_path,
    .buttons = tablet_pad_buttons,
    .done = tablet_pad_done,
    .button = tablet_pad_button,
    .enter = tablet_pad_enter,
    .leave = tablet_pad_leave,
    .removed = tablet_pad_removed,
};

static void tablet_seat_tablet_added(void *data, struct zwp_tablet_seat_v2 *seat,
                                     struct zwp_tablet_v2 *tablet) {
    (void)seat;
    zwp_tablet_v2_add_listener(tablet, &tablet_listener, data);
}

static void tablet_seat_tool_added(void *data, struct zwp_tablet_seat_v2 *seat,
                                   struct zwp_tablet_tool_v2 *tool) {
    (void)seat;
    zwp_tablet_tool_v2_add_listener(tool, &tablet_tool_listener, data);
}

static void tablet_seat_pad_added(void *data, struct zwp_tablet_seat_v2 *seat,
                                  struct zwp_tablet_pad_v2 *pad) {
    (void)seat;
    zwp_tablet_pad_v2_add_listener(pad, &tablet_pad_listener, data);
}

static const struct zwp_tablet_seat_v2_listener tablet_seat_listener = {
    .tablet_added = tablet_seat_tablet_added,
    .tool_added = tablet_seat_tool_added,
    .pad_added = tablet_seat_pad_added,
};

static void ensure_tablet_seat(struct palimpsest_wl *wl) {
    if (!wl->seat || !wl->tablet_manager || wl->tablet_seat) {
        return;
    }
    wl->tablet_seat = zwp_tablet_manager_v2_get_tablet_seat(wl->tablet_manager, wl->seat);
    if (wl->tablet_seat) {
        zwp_tablet_seat_v2_add_listener(wl->tablet_seat, &tablet_seat_listener, wl);
    }
}

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities) {
    struct palimpsest_wl *wl = data;
    if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !wl->pointer) {
        wl->pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(wl->pointer, &pointer_listener, wl);
    }
    if ((capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && !wl->keyboard) {
        wl->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(wl->keyboard, &keyboard_listener, wl);
    }
    if ((capabilities & WL_SEAT_CAPABILITY_TOUCH) && !wl->touch) {
        wl->touch = wl_seat_get_touch(seat);
        wl_touch_add_listener(wl->touch, &touch_listener, wl);
    }
    ensure_tablet_seat(wl);
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data;
    (void)seat;
    (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    struct palimpsest_wl *wl = data;
    if (strcmp(interface, "wl_compositor") == 0) {
        wl->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, cap_version(version, 4));
    } else if (strcmp(interface, "wl_shm") == 0) {
        wl->shm = wl_registry_bind(registry, name, &wl_shm_interface, cap_version(version, 1));
    } else if (strcmp(interface, "wl_seat") == 0) {
        wl->seat = wl_registry_bind(registry, name, &wl_seat_interface, cap_version(version, 7));
        wl_seat_add_listener(wl->seat, &seat_listener, wl);
        ensure_tablet_seat(wl);
    } else if (strcmp(interface, "wl_output") == 0) {
        if (wl->output_count >= MAX_OUTPUTS) {
            return;
        }
        struct output *out = &wl->outputs[wl->output_count];
        memset(out, 0, sizeof(*out));
        out->wl = wl;
        out->registry_name = name;
        out->id = wl->output_count;
        out->alive = 1;
        out->scale = 1;
        out->output = wl_registry_bind(registry, name, &wl_output_interface, cap_version(version, 4));
        wl_output_add_listener(out->output, &output_listener, out);
        wl->output_count += 1;
    } else if (strcmp(interface, "zwlr_layer_shell_v1") == 0) {
        wl->layer_shell = wl_registry_bind(
            registry, name, &zwlr_layer_shell_v1_interface, cap_version(version, 4));
    } else if (strcmp(interface, "zwp_tablet_manager_v2") == 0) {
        wl->tablet_manager = wl_registry_bind(
            registry, name, &zwp_tablet_manager_v2_interface, cap_version(version, 1));
        ensure_tablet_seat(wl);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct palimpsest_wl *wl = data;
    for (int i = 0; i < wl->output_count; i++) {
        struct output *out = &wl->outputs[i];
        if (out->alive && out->registry_name == name) {
            output_destroy_surface(out);
            if (out->output) {
                wl_output_destroy(out->output);
                out->output = NULL;
            }
            out->alive = 0;
        }
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void set_error(char *error, size_t error_len, const char *message) {
    if (error && error_len > 0) {
        snprintf(error, error_len, "%s", message);
    }
}

int palimpsest_wl_connect(void **out_session, palimpsest_event_fn on_event, void *userdata,
                          char *error, size_t error_len) {
    if (out_session) {
        *out_session = NULL;
    }
    struct palimpsest_wl *wl = calloc(1, sizeof(*wl));
    if (!wl) {
        set_error(error, error_len, "out of memory");
        return -1;
    }
    wl->on_event = on_event;
    wl->userdata = userdata;
    wl->pointer_output = -1;
    wl->tablet_output = -1;
    wl->tablet_pressure = 0.5;

    wl->display = wl_display_connect(NULL);
    if (!wl->display) {
        set_error(error, error_len, "could not connect to the Wayland compositor");
        free(wl);
        return -1;
    }
    wl->registry = wl_display_get_registry(wl->display);
    wl_registry_add_listener(wl->registry, &registry_listener, wl);
    wl_display_roundtrip(wl->display);
    wl_display_roundtrip(wl->display);

    if (!wl->compositor || !wl->shm || !wl->layer_shell) {
        set_error(error, error_len, "compositor is missing wl_compositor, wl_shm, or zwlr_layer_shell_v1");
        palimpsest_wl_destroy(wl);
        return -1;
    }
    if (wl->output_count == 0) {
        set_error(error, error_len, "compositor advertised no outputs");
        palimpsest_wl_destroy(wl);
        return -1;
    }
    if (out_session) {
        *out_session = wl;
    }
    return 0;
}

void palimpsest_wl_destroy(void *session) {
    struct palimpsest_wl *wl = session;
    if (!wl) {
        return;
    }
    for (int i = 0; i < wl->output_count; i++) {
        output_destroy_surface(&wl->outputs[i]);
        if (wl->outputs[i].output) {
            wl_output_destroy(wl->outputs[i].output);
        }
    }
    if (wl->cursor_surface) {
        wl_surface_destroy(wl->cursor_surface);
    }
    if (wl->cursor_theme) {
        wl_cursor_theme_destroy(wl->cursor_theme);
    }
    if (wl->tablet_seat) {
        zwp_tablet_seat_v2_destroy(wl->tablet_seat);
    }
    if (wl->tablet_manager) {
        zwp_tablet_manager_v2_destroy(wl->tablet_manager);
    }
    if (wl->pointer) {
        wl_pointer_destroy(wl->pointer);
    }
    if (wl->keyboard) {
        wl_keyboard_destroy(wl->keyboard);
    }
    if (wl->touch) {
        wl_touch_destroy(wl->touch);
    }
    if (wl->seat) {
        wl_seat_destroy(wl->seat);
    }
    if (wl->layer_shell) {
        zwlr_layer_shell_v1_destroy(wl->layer_shell);
    }
    if (wl->shm) {
        wl_shm_destroy(wl->shm);
    }
    if (wl->compositor) {
        wl_compositor_destroy(wl->compositor);
    }
    if (wl->registry) {
        wl_registry_destroy(wl->registry);
    }
    if (wl->display) {
        wl_display_disconnect(wl->display);
    }
    free(wl);
}

void palimpsest_wl_set_margins(void *session, int32_t top, int32_t right, int32_t bottom, int32_t left) {
    struct palimpsest_wl *wl = session;
    if (!wl) {
        return;
    }
    wl->margin_top = top;
    wl->margin_right = right;
    wl->margin_bottom = bottom;
    wl->margin_left = left;
}

int palimpsest_wl_show(void *session) {
    struct palimpsest_wl *wl = session;
    if (!wl || !wl->compositor || !wl->layer_shell) {
        return -1;
    }
    int created = 0;
    for (int i = 0; i < wl->output_count; i++) {
        struct output *out = &wl->outputs[i];
        if (!out->alive || !out->output || out->surface) {
            continue;
        }
        out->surface = wl_compositor_create_surface(wl->compositor);
        if (!out->surface) {
            continue;
        }
        out->layer = zwlr_layer_shell_v1_get_layer_surface(
            wl->layer_shell, out->surface, out->output,
            ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "palimpsest-ink");
        if (!out->layer) {
            wl_surface_destroy(out->surface);
            out->surface = NULL;
            continue;
        }
        zwlr_layer_surface_v1_add_listener(out->layer, &layer_listener, out);
        uint32_t anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
            | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        zwlr_layer_surface_v1_set_anchor(out->layer, anchor);
        // -1 + the bar margin keeps the overlay flush under the bar without
        // a second exclusive-zone inset.
        zwlr_layer_surface_v1_set_exclusive_zone(out->layer, -1);
        zwlr_layer_surface_v1_set_margin(out->layer, wl->margin_top, wl->margin_right,
                                         wl->margin_bottom, wl->margin_left);
        // ON_DEMAND keeps Esc/Ctrl+Z while the pointer is on the overlay,
        // without an exclusive grab that swallows clicks on the bar applet.
        zwlr_layer_surface_v1_set_keyboard_interactivity(
            out->layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND);
        zwlr_layer_surface_v1_set_size(out->layer, 0, 0);
        wl_surface_commit(out->surface);
        created += 1;
    }
    if (created == 0) {
        for (int i = 0; i < wl->output_count; i++) {
            if (wl->outputs[i].configured) {
                return 0;
            }
        }
        return -1;
    }
    for (int attempt = 0; attempt < 20; attempt++) {
        if (wl_display_roundtrip(wl->display) < 0) {
            return -1;
        }
        int ready = 1;
        for (int i = 0; i < wl->output_count; i++) {
            if (wl->outputs[i].alive && wl->outputs[i].surface && !wl->outputs[i].configured) {
                ready = 0;
            }
        }
        if (ready) {
            return 0;
        }
    }
    return -1;
}

void palimpsest_wl_hide(void *session) {
    struct palimpsest_wl *wl = session;
    if (!wl) {
        return;
    }
    for (int i = 0; i < wl->output_count; i++) {
        output_destroy_surface(&wl->outputs[i]);
    }
    if (wl->display) {
        wl_display_flush(wl->display);
    }
}

int palimpsest_wl_output_count(void *session) {
    struct palimpsest_wl *wl = session;
    return wl ? wl->output_count : 0;
}

int palimpsest_wl_output_info(void *session, int32_t index, struct palimpsest_output_info *out_info) {
    struct palimpsest_wl *wl = session;
    if (!wl || !out_info || index < 0 || index >= wl->output_count) {
        return -1;
    }
    struct output *out = &wl->outputs[index];
    memset(out_info, 0, sizeof(*out_info));
    out_info->id = out->id;
    out_info->x = out->x;
    out_info->y = out->y;
    out_info->scale = out->scale > 0 ? out->scale : 1;
    out_info->logical_width = out->logical_w;
    out_info->logical_height = out->logical_h;
    if (out->buffers[0].buffer) {
        out_info->buffer_width = out->buffers[0].width;
        out_info->buffer_height = out->buffers[0].height;
    }
    out_info->margin_top = wl->margin_top;
    out_info->margin_right = wl->margin_right;
    out_info->margin_bottom = wl->margin_bottom;
    out_info->margin_left = wl->margin_left;
    return out->alive ? 0 : -1;
}

int palimpsest_wl_present(void *session, int32_t output_id, const uint8_t *rgba,
                          int32_t width, int32_t height, int32_t stride) {
    struct palimpsest_wl *wl = session;
    struct output *out = wl ? output_by_id(wl, output_id) : NULL;
    if (!out || !out->surface || !rgba || width <= 0 || height <= 0 || stride < width * 4) {
        return -1;
    }
    struct shm_buffer *buf = NULL;
    for (int i = 0; i < 2; i++) {
        if (out->buffers[i].buffer && !out->buffers[i].busy
            && out->buffers[i].width == width && out->buffers[i].height == height) {
            buf = &out->buffers[i];
            break;
        }
    }
    if (!buf) {
        return -2;
    }
    uint8_t *destination = buf->data;
    for (int32_t y = 0; y < height; y++) {
        const uint8_t *src = rgba + (size_t)y * (size_t)stride;
        uint8_t *row = destination + (size_t)y * (size_t)buf->stride;
        for (int32_t x = 0; x < width; x++) {
            const uint8_t *pixel = src + (size_t)x * 4;
            uint32_t alpha = pixel[3];
            row[x * 4 + 0] = (uint8_t)(pixel[2] * alpha / 255);
            row[x * 4 + 1] = (uint8_t)(pixel[1] * alpha / 255);
            row[x * 4 + 2] = (uint8_t)(pixel[0] * alpha / 255);
            row[x * 4 + 3] = (uint8_t)alpha;
        }
    }
    int scale = out->scale > 0 ? out->scale : 1;
    wl_surface_set_buffer_scale(out->surface, scale);
    wl_surface_attach(out->surface, buf->buffer, 0, 0);
    wl_surface_damage(out->surface, 0, 0, out->logical_w, out->logical_h);
    wl_surface_commit(out->surface);
    buf->busy = 1;
    wl_display_flush(wl->display);
    return 0;
}

int palimpsest_wl_roundtrip(void *session) {
    struct palimpsest_wl *wl = session;
    if (!wl || !wl->display) {
        return -1;
    }
    return wl_display_roundtrip(wl->display) < 0 ? -1 : 0;
}

int palimpsest_wl_poll(void *session, const int *extra_fds, int extra_count, int *ready, int timeout_ms) {
    struct palimpsest_wl *wl = session;
    if (!wl || !wl->display) {
        return -1;
    }
    if (extra_count < 0) {
        extra_count = 0;
    }
    if (extra_count > MAX_EXTRA_FDS) {
        extra_count = MAX_EXTRA_FDS;
    }
    if (ready) {
        for (int i = 0; i < extra_count; i++) {
            ready[i] = 0;
        }
    }

    while (wl_display_prepare_read(wl->display) != 0) {
        if (wl_display_dispatch_pending(wl->display) < 0) {
            return -1;
        }
    }

    int want_write = 0;
    while (wl_display_flush(wl->display) < 0) {
        if (errno == EAGAIN) {
            want_write = 1;
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        wl_display_cancel_read(wl->display);
        return -1;
    }

    struct pollfd pfds[1 + MAX_EXTRA_FDS];
    int extra_index[MAX_EXTRA_FDS];
    nfds_t nfds = 0;
    pfds[nfds].fd = wl_display_get_fd(wl->display);
    pfds[nfds].events = POLLIN | (want_write ? POLLOUT : 0);
    pfds[nfds].revents = 0;
    int wayland_index = (int)nfds;
    nfds += 1;
    for (int i = 0; i < extra_count; i++) {
        extra_index[i] = -1;
        if (!extra_fds || extra_fds[i] < 0) {
            continue;
        }
        pfds[nfds].fd = extra_fds[i];
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        extra_index[i] = (int)nfds;
        nfds += 1;
    }

    int polled = poll(pfds, nfds, timeout_ms);
    if (polled < 0) {
        wl_display_cancel_read(wl->display);
        return errno == EINTR ? 0 : -1;
    }

    if (pfds[wayland_index].revents & (POLLIN | POLLHUP | POLLERR)) {
        if (wl_display_read_events(wl->display) < 0) {
            return -1;
        }
    } else {
        wl_display_cancel_read(wl->display);
    }
    if (wl_display_dispatch_pending(wl->display) < 0) {
        return -1;
    }
    if (pfds[wayland_index].revents & (POLLHUP | POLLERR)) {
        return -1;
    }
    if (ready) {
        for (int i = 0; i < extra_count; i++) {
            int index = extra_index[i];
            if (index >= 0 && (pfds[index].revents & (POLLIN | POLLHUP | POLLERR))) {
                ready[i] = 1;
            }
        }
    }
    return 0;
}
