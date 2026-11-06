#include "CPalimpsestLinux.h"
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int palimpsest_write_png_rgba(const char *path, int width, int height, int stride,
                              const uint8_t *rgba) {
    FILE *file = fopen(path, "wb");
    if (!file) {
        return -1;
    }

    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) {
        fclose(file);
        return -1;
    }
    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, NULL);
        fclose(file);
        return -1;
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        fclose(file);
        return -1;
    }

    png_init_io(png, file);
    png_set_IHDR(png, info, width, height, 8, PNG_COLOR_TYPE_RGBA,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
                 PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    for (int y = 0; y < height; y++) {
        png_write_row(png, (png_const_bytep)(rgba + (size_t)y * stride));
    }

    png_write_end(png, info);
    png_destroy_write_struct(&png, &info);
    fclose(file);
    return 0;
}