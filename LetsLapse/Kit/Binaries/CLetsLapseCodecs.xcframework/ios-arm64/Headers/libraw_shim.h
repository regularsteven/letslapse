#include "libraw/libraw.h"

// Swift does not import C arrays past 4096 elements; `cblack` is 4102.
static inline unsigned letslapse_libraw_cblack(const libraw_data_t *data, int index) {
    return data->color.cblack[index];
}
