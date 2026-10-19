#ifndef ORTSHIM_H
#define ORTSHIM_H
#include <stdint.h>

typedef struct OrtShimModel OrtShimModel;

/// Loads an ONNX model with one float input and one float output. Returns NULL and fills err on failure.
OrtShimModel *ortshim_load(const char *path, char *err, int errlen);
void ortshim_free(OrtShimModel *m);

/// Runs the model. `out` has room for `out_cap` floats; the element count is written to *out_len and the
/// output shape (up to 8 dims) to out_shape / *out_rank. Returns 0 on success.
int ortshim_run(OrtShimModel *m, const float *in, const int64_t *shape, int rank,
                float *out, int64_t out_cap, int64_t *out_len, int64_t *out_shape, int *out_rank,
                char *err, int errlen);
#endif
