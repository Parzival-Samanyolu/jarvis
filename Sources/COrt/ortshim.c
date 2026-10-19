#include "ortshim.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct OrtShimModel {
    OrtSession *session;
    OrtMemoryInfo *mem;
    char *in_name;
    char *out_name;
};

static const OrtApi *api(void) { return OrtGetApiBase()->GetApi(ORT_API_VERSION); }
static OrtEnv *env_singleton(void) {
    static OrtEnv *env = NULL;
    if (!env) api()->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "jarvis", &env);
    return env;
}

static int fail(OrtStatus *st, char *err, int errlen) {
    if (!st) return 0;
    snprintf(err, errlen, "%s", api()->GetErrorMessage(st));
    api()->ReleaseStatus(st);
    return 1;
}

OrtShimModel *ortshim_load(const char *path, char *err, int errlen) {
    const OrtApi *a = api();
    OrtSessionOptions *opts = NULL;
    if (fail(a->CreateSessionOptions(&opts), err, errlen)) return NULL;
    a->SetIntraOpNumThreads(opts, 1);
    OrtShimModel *m = calloc(1, sizeof *m);
    if (fail(a->CreateSession(env_singleton(), path, opts, &m->session), err, errlen)) { a->ReleaseSessionOptions(opts); free(m); return NULL; }
    a->ReleaseSessionOptions(opts);
    OrtAllocator *alloc = NULL;
    a->GetAllocatorWithDefaultOptions(&alloc);
    char *n = NULL;
    if (fail(a->SessionGetInputName(m->session, 0, alloc, &n), err, errlen)) { ortshim_free(m); return NULL; }
    m->in_name = strdup(n); alloc->Free(alloc, n);
    if (fail(a->SessionGetOutputName(m->session, 0, alloc, &n), err, errlen)) { ortshim_free(m); return NULL; }
    m->out_name = strdup(n); alloc->Free(alloc, n);
    if (fail(a->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &m->mem), err, errlen)) { ortshim_free(m); return NULL; }
    return m;
}

void ortshim_free(OrtShimModel *m) {
    if (!m) return;
    const OrtApi *a = api();
    if (m->mem) a->ReleaseMemoryInfo(m->mem);
    if (m->session) a->ReleaseSession(m->session);
    free(m->in_name); free(m->out_name); free(m);
}

int ortshim_run(OrtShimModel *m, const float *in, const int64_t *shape, int rank,
                float *out, int64_t out_cap, int64_t *out_len, int64_t *out_shape, int *out_rank,
                char *err, int errlen) {
    const OrtApi *a = api();
    int64_t n = 1;
    for (int i = 0; i < rank; i++) n *= shape[i];
    OrtValue *input = NULL, *output = NULL;
    if (fail(a->CreateTensorWithDataAsOrtValue(m->mem, (void *)in, (size_t)n * sizeof(float), shape, (size_t)rank,
                                               ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), err, errlen)) return 1;
    const char *in_names[1] = {m->in_name};
    const char *out_names[1] = {m->out_name};
    if (fail(a->Run(m->session, NULL, in_names, (const OrtValue *const *)&input, 1, out_names, 1, &output), err, errlen)) {
        a->ReleaseValue(input); return 2;
    }
    int rc = 0;
    OrtTensorTypeAndShapeInfo *info = NULL;
    float *data = NULL;
    if (fail(a->GetTensorTypeAndShape(output, &info), err, errlen)) { rc = 3; goto done; }
    size_t dims = 0; a->GetDimensionsCount(info, &dims);
    if (dims > 8) { snprintf(err, errlen, "output rank too large"); rc = 4; a->ReleaseTensorTypeAndShapeInfo(info); goto done; }
    a->GetDimensions(info, out_shape, dims);
    *out_rank = (int)dims;
    size_t count = 0; a->GetTensorShapeElementCount(info, &count);
    a->ReleaseTensorTypeAndShapeInfo(info);
    *out_len = (int64_t)count;
    if ((int64_t)count > out_cap) { snprintf(err, errlen, "output buffer too small (%zu)", count); rc = 5; goto done; }
    if (fail(a->GetTensorMutableData(output, (void **)&data), err, errlen)) { rc = 6; goto done; }
    memcpy(out, data, count * sizeof(float));
done:
    a->ReleaseValue(output); a->ReleaseValue(input);
    return rc;
}
