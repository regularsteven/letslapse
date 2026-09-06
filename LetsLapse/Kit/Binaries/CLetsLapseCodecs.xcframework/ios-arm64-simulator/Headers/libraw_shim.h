#include "libraw/libraw.h"

static inline unsigned letslapse_libraw_cblack(const libraw_data_t *data, int index) {
    return data->color.cblack[index];
}
