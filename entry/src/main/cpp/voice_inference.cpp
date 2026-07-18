#include <napi/native_api.h>
#include <rawfile/raw_file_manager.h>

#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"

namespace {

constexpr const char *kKwsEncoder = "voice/kws/encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx";
constexpr const char *kKwsDecoder = "voice/kws/decoder-epoch-13-avg-2-chunk-8-left-64.onnx";
constexpr const char *kKwsJoiner = "voice/kws/joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx";
constexpr const char *kKwsTokens = "voice/kws/tokens.txt";
constexpr const char *kKwsKeywords = "voice/kws/keywords.txt";
constexpr const char *kAsrEncoder = "voice/asr/encoder-epoch-99-avg-1.int8.onnx";
constexpr const char *kAsrDecoder = "voice/asr/decoder-epoch-99-avg-1.onnx";
constexpr const char *kAsrJoiner = "voice/asr/joiner-epoch-99-avg-1.int8.onnx";
constexpr const char *kAsrTokens = "voice/asr/tokens.txt";
constexpr const char *kSpeakerModel =
    "voice/speaker/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx";
constexpr const char *kAsrHotwords =
    "开灯\n"
    "打开灯\n"
    "打开客厅灯\n"
    "客厅灯\n"
    "点亮客厅灯\n"
    "开启客厅照明\n"
    "关灯\n"
    "关闭客厅灯\n"
    "打开空调\n"
    "开启空调\n"
    "关闭空调\n"
    "关掉空调\n";

const SherpaOnnxKeywordSpotter *g_keywordSpotter = nullptr;
const SherpaOnnxOnlineStream *g_keywordStream = nullptr;
const SherpaOnnxOnlineRecognizer *g_recognizer = nullptr;
const SherpaOnnxOnlineStream *g_commandStream = nullptr;
const SherpaOnnxSpeakerEmbeddingExtractor *g_speakerExtractor = nullptr;
const SherpaOnnxOnlineStream *g_speakerStream = nullptr;
int32_t g_modelGeneration = 0;
bool g_speakerLoading = false;
bool g_voiceModelsLoading = false;
std::mutex g_inferenceMutex;

struct VoiceModelLoadWork {
    napi_async_work asyncWork = nullptr;
    napi_deferred deferred = nullptr;
    NativeResourceManager *manager = nullptr;
    const SherpaOnnxKeywordSpotter *keywordSpotter = nullptr;
    const SherpaOnnxOnlineStream *keywordStream = nullptr;
    const SherpaOnnxOnlineRecognizer *recognizer = nullptr;
    int32_t generation = 0;
};

struct SpeakerLoadWork {
    napi_async_work asyncWork = nullptr;
    napi_deferred deferred = nullptr;
    NativeResourceManager *manager = nullptr;
    const SherpaOnnxSpeakerEmbeddingExtractor *extractor = nullptr;
    int32_t generation = 0;
};

struct WakeDecodeWork {
    napi_async_work asyncWork = nullptr;
    napi_deferred deferred = nullptr;
    std::vector<float> samples;
    std::vector<int16_t> pcm16Samples;
    int32_t sampleRate = 0;
    int32_t generation = 0;
    std::string json = R"({"keyword":"","tokens":[],"timestamps":[]})";
};

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value MakeInt(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeFloat32Array(napi_env env, const float *values, int32_t count)
{
    napi_value arrayBuffer = nullptr;
    void *data = nullptr;
    const size_t byteLength = count > 0 ? static_cast<size_t>(count) * sizeof(float) : 0;
    napi_create_arraybuffer(env, byteLength, &data, &arrayBuffer);
    if (values != nullptr && data != nullptr && byteLength > 0) {
        std::memcpy(data, values, byteLength);
    }
    napi_value result = nullptr;
    napi_create_typedarray(env, napi_float32_array, count, arrayBuffer, 0, &result);
    return result;
}

napi_value MakeInitResult(napi_env env, bool success, const std::string &message,
    bool speakerReady = false, int32_t speakerDimension = 0)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "success", MakeBool(env, success));
    napi_set_named_property(env, result, "message", MakeString(env, message));
    napi_set_named_property(env, result, "speakerReady", MakeBool(env, speakerReady));
    napi_set_named_property(env, result, "speakerDimension", MakeInt(env, speakerDimension));
    return result;
}

napi_value MakeDecodeResult(napi_env env, const std::string &json, bool endpoint)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "json", MakeString(env, json));
    napi_set_named_property(env, result, "endpoint", MakeBool(env, endpoint));
    return result;
}

napi_value MakeSpeakerResult(napi_env env, bool success, bool ready, const std::string &message,
    const float *embedding = nullptr, int32_t dimension = 0)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "success", MakeBool(env, success));
    napi_set_named_property(env, result, "ready", MakeBool(env, ready));
    napi_set_named_property(env, result, "message", MakeString(env, message));
    napi_set_named_property(env, result, "dimension", MakeInt(env, dimension));
    napi_set_named_property(env, result, "embedding", MakeFloat32Array(env, embedding, dimension));
    return result;
}

void DestroyCommandStream()
{
    if (g_commandStream != nullptr) {
        SherpaOnnxDestroyOnlineStream(g_commandStream);
        g_commandStream = nullptr;
    }
}

void DestroyKeywordStream()
{
    if (g_keywordStream != nullptr) {
        SherpaOnnxDestroyOnlineStream(g_keywordStream);
        g_keywordStream = nullptr;
    }
}

void DestroySpeakerStream()
{
    if (g_speakerStream != nullptr) {
        SherpaOnnxDestroyOnlineStream(g_speakerStream);
        g_speakerStream = nullptr;
    }
}

void DestroyAll()
{
    ++g_modelGeneration;
    DestroyCommandStream();
    DestroyKeywordStream();
    DestroySpeakerStream();
    if (g_recognizer != nullptr) {
        SherpaOnnxDestroyOnlineRecognizer(g_recognizer);
        g_recognizer = nullptr;
    }
    if (g_keywordSpotter != nullptr) {
        SherpaOnnxDestroyKeywordSpotter(g_keywordSpotter);
        g_keywordSpotter = nullptr;
    }
    if (g_speakerExtractor != nullptr) {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(g_speakerExtractor);
        g_speakerExtractor = nullptr;
    }
}

bool ReadAudioArgs(napi_env env, napi_callback_info info, float **samples, int32_t *sampleCount,
    int32_t *sampleRate)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 2) {
        napi_throw_error(env, nullptr, "Expected Float32Array samples and sampleRate");
        return false;
    }

    napi_typedarray_type type;
    size_t length = 0;
    void *data = nullptr;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, argv[0], &type, &length, &data, &arrayBuffer, &byteOffset) != napi_ok ||
        type != napi_float32_array || data == nullptr) {
        napi_throw_type_error(env, nullptr, "samples must be a Float32Array");
        return false;
    }
    int32_t rate = 0;
    if (napi_get_value_int32(env, argv[1], &rate) != napi_ok || rate <= 0) {
        napi_throw_type_error(env, nullptr, "sampleRate must be a positive integer");
        return false;
    }
    *samples = static_cast<float *>(data);
    // API 11 reports the Float32Array byte length here, unlike standard N-API.
    *sampleCount = static_cast<int32_t>(length / sizeof(float));
    *sampleRate = rate;
    return true;
}

SherpaOnnxKeywordSpotterConfig MakeKeywordConfig()
{
    SherpaOnnxKeywordSpotterConfig config;
    std::memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = kKwsEncoder;
    config.model_config.transducer.decoder = kKwsDecoder;
    config.model_config.transducer.joiner = kKwsJoiner;
    config.model_config.tokens = kKwsTokens;
    config.model_config.num_threads = 1;
    config.model_config.provider = "cpu";
    config.model_config.modeling_unit = "cjkchar";
    config.max_active_paths = 4;
    config.num_trailing_blanks = 1;
    config.keywords_score = 1.5F;
    config.keywords_threshold = 0.35F;
    config.keywords_file = kKwsKeywords;
    return config;
}

SherpaOnnxOnlineRecognizerConfig MakeRecognizerConfig()
{
    SherpaOnnxOnlineRecognizerConfig config;
    std::memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = kAsrEncoder;
    config.model_config.transducer.decoder = kAsrDecoder;
    config.model_config.transducer.joiner = kAsrJoiner;
    config.model_config.tokens = kAsrTokens;
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.model_config.modeling_unit = "cjkchar";
    config.decoding_method = "modified_beam_search";
    config.max_active_paths = 4;
    config.hotwords_score = 2.0F;
    config.hotwords_buf = kAsrHotwords;
    config.hotwords_buf_size = static_cast<int32_t>(std::strlen(kAsrHotwords));
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = 1.8F;
    config.rule2_min_trailing_silence = 0.8F;
    config.rule3_min_utterance_length = 8.0F;
    return config;
}

SherpaOnnxSpeakerEmbeddingExtractorConfig MakeSpeakerConfig()
{
    SherpaOnnxSpeakerEmbeddingExtractorConfig config;
    std::memset(&config, 0, sizeof(config));
    config.model = kSpeakerModel;
    config.num_threads = 1;
    config.provider = "cpu";
    return config;
}

void DestroyVoiceModelLoadResult(VoiceModelLoadWork *work)
{
    if (work->keywordStream != nullptr) {
        SherpaOnnxDestroyOnlineStream(work->keywordStream);
        work->keywordStream = nullptr;
    }
    if (work->recognizer != nullptr) {
        SherpaOnnxDestroyOnlineRecognizer(work->recognizer);
        work->recognizer = nullptr;
    }
    if (work->keywordSpotter != nullptr) {
        SherpaOnnxDestroyKeywordSpotter(work->keywordSpotter);
        work->keywordSpotter = nullptr;
    }
}

void ExecuteVoiceModelLoad(napi_env env, void *data)
{
    (void)env;
    auto *work = static_cast<VoiceModelLoadWork *>(data);
    const SherpaOnnxKeywordSpotterConfig keywordConfig = MakeKeywordConfig();
    work->keywordSpotter = SherpaOnnxCreateKeywordSpotterOHOS(&keywordConfig, work->manager);
    if (work->keywordSpotter != nullptr) {
        work->keywordStream = SherpaOnnxCreateKeywordStream(work->keywordSpotter);
    }

    const SherpaOnnxOnlineRecognizerConfig recognizerConfig = MakeRecognizerConfig();
    work->recognizer = SherpaOnnxCreateOnlineRecognizerOHOS(&recognizerConfig, work->manager);
}

void CompleteVoiceModelLoad(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<VoiceModelLoadWork *>(data);
    g_voiceModelsLoading = false;
    napi_value result = nullptr;
    const bool loaded = work->keywordSpotter != nullptr && work->keywordStream != nullptr &&
        work->recognizer != nullptr;
    if (status != napi_ok || !loaded) {
        DestroyVoiceModelLoadResult(work);
        result = MakeInitResult(env, false, "Failed to initialize KWS or ASR model");
    } else if (work->generation != g_modelGeneration) {
        DestroyVoiceModelLoadResult(work);
        result = MakeInitResult(env, false, "Voice model load was cancelled");
    } else {
        g_keywordSpotter = work->keywordSpotter;
        g_keywordStream = work->keywordStream;
        g_recognizer = work->recognizer;
        work->keywordSpotter = nullptr;
        work->keywordStream = nullptr;
        work->recognizer = nullptr;
        result = MakeInitResult(env, true, "KWS and ASR models loaded", false, 0);
    }
    if (work->manager != nullptr) {
        OH_ResourceManager_ReleaseNativeResourceManager(work->manager);
        work->manager = nullptr;
    }
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

napi_value Initialize(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    if (argc != 1) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "resourceManager is required"));
        return promise;
    }
    if (g_keywordSpotter != nullptr && g_keywordStream != nullptr && g_recognizer != nullptr) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, true, "KWS and ASR models already loaded", false, 0));
        return promise;
    }
    if (g_voiceModelsLoading) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Voice models are already loading"));
        return promise;
    }

    DestroyAll();
    NativeResourceManager *manager = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
    if (manager == nullptr) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Failed to create NativeResourceManager"));
        return promise;
    }

    auto *work = new VoiceModelLoadWork();
    work->deferred = deferred;
    work->manager = manager;
    work->generation = g_modelGeneration;
    napi_value resourceName = MakeString(env, "voice-kws-asr-model-load");
    const napi_status createStatus = napi_create_async_work(env, nullptr, resourceName,
        ExecuteVoiceModelLoad, CompleteVoiceModelLoad, work, &work->asyncWork);
    if (createStatus != napi_ok) {
        OH_ResourceManager_ReleaseNativeResourceManager(manager);
        delete work;
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Failed to create voice model load task"));
        return promise;
    }
    g_voiceModelsLoading = true;
    napi_queue_async_work(env, work->asyncWork);
    return promise;
}

void ExecuteSpeakerLoad(napi_env env, void *data)
{
    (void)env;
    auto *work = static_cast<SpeakerLoadWork *>(data);
    const SherpaOnnxSpeakerEmbeddingExtractorConfig config = MakeSpeakerConfig();
    work->extractor = SherpaOnnxCreateSpeakerEmbeddingExtractorOHOS(&config, work->manager);
}

void CompleteSpeakerLoad(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<SpeakerLoadWork *>(data);
    g_speakerLoading = false;
    napi_value result = nullptr;
    if (status != napi_ok || work->extractor == nullptr) {
        result = MakeInitResult(env, false, "Failed to load speaker model");
    } else if (work->generation != g_modelGeneration) {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(work->extractor);
        work->extractor = nullptr;
        result = MakeInitResult(env, false, "Speaker model load was cancelled");
    } else {
        DestroySpeakerStream();
        if (g_speakerExtractor != nullptr) {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(g_speakerExtractor);
        }
        g_speakerExtractor = work->extractor;
        work->extractor = nullptr;
        const int32_t dimension = SherpaOnnxSpeakerEmbeddingExtractorDim(g_speakerExtractor);
        result = MakeInitResult(env, true, "Speaker model loaded", true, dimension);
    }
    if (work->manager != nullptr) {
        OH_ResourceManager_ReleaseNativeResourceManager(work->manager);
        work->manager = nullptr;
    }
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

napi_value InitializeSpeaker(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    if (argc != 1) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "resourceManager is required"));
        return promise;
    }
    if (g_speakerExtractor != nullptr) {
        const int32_t dimension = SherpaOnnxSpeakerEmbeddingExtractorDim(g_speakerExtractor);
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, true, "Speaker model already loaded", true, dimension));
        return promise;
    }
    if (g_speakerLoading) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Speaker model is already loading"));
        return promise;
    }

    NativeResourceManager *manager = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
    if (manager == nullptr) {
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Failed to create NativeResourceManager"));
        return promise;
    }

    auto *work = new SpeakerLoadWork();
    work->deferred = deferred;
    work->manager = manager;
    work->generation = g_modelGeneration;
    napi_value resourceName = MakeString(env, "voice-speaker-model-load");
    const napi_status createStatus = napi_create_async_work(env, nullptr, resourceName,
        ExecuteSpeakerLoad, CompleteSpeakerLoad, work, &work->asyncWork);
    if (createStatus != napi_ok) {
        OH_ResourceManager_ReleaseNativeResourceManager(manager);
        delete work;
        napi_resolve_deferred(env, deferred,
            MakeInitResult(env, false, "Failed to create speaker model load task"));
        return promise;
    }
    g_speakerLoading = true;
    napi_queue_async_work(env, work->asyncWork);
    return promise;
}

napi_value ResetWake(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_inferenceMutex);
    if (g_keywordSpotter == nullptr) {
        return MakeBool(env, false);
    }
    DestroyKeywordStream();
    g_keywordStream = SherpaOnnxCreateKeywordStream(g_keywordSpotter);
    return MakeBool(env, g_keywordStream != nullptr);
}

napi_value AcceptWake(napi_env env, napi_callback_info info)
{
    float *samples = nullptr;
    int32_t sampleCount = 0;
    int32_t sampleRate = 0;
    if (!ReadAudioArgs(env, info, &samples, &sampleCount, &sampleRate)) {
        return nullptr;
    }
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);

    auto *work = new WakeDecodeWork();
    work->deferred = deferred;
    work->sampleRate = sampleRate;
    work->generation = g_modelGeneration;
    work->samples.resize(static_cast<size_t>(sampleCount));
    std::memcpy(work->samples.data(), samples, static_cast<size_t>(sampleCount) * sizeof(float));

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "VoiceWakeDecode", NAPI_AUTO_LENGTH, &resourceName);
    const napi_status createStatus = napi_create_async_work(env, nullptr, resourceName,
        [](napi_env executeEnv, void *data) {
            (void)executeEnv;
            auto *decode = static_cast<WakeDecodeWork *>(data);
            if (!decode->pcm16Samples.empty()) {
                decode->samples.resize(decode->pcm16Samples.size());
                for (size_t i = 0; i < decode->pcm16Samples.size(); ++i) {
                    decode->samples[i] = static_cast<float>(decode->pcm16Samples[i]) / 32768.0F;
                }
                decode->pcm16Samples.clear();
            }
            std::lock_guard<std::mutex> lock(g_inferenceMutex);
            if (decode->generation != g_modelGeneration || g_keywordSpotter == nullptr ||
                g_keywordStream == nullptr || decode->samples.empty()) {
                return;
            }
            SherpaOnnxOnlineStreamAcceptWaveform(g_keywordStream, decode->sampleRate,
                decode->samples.data(), static_cast<int32_t>(decode->samples.size()));
            int32_t decodeCount = 0;
            while (SherpaOnnxIsKeywordStreamReady(g_keywordSpotter, g_keywordStream) && decodeCount < 16) {
                SherpaOnnxDecodeKeywordStream(g_keywordSpotter, g_keywordStream);
                ++decodeCount;
            }
            const char *json = SherpaOnnxGetKeywordResultAsJson(g_keywordSpotter, g_keywordStream);
            if (json != nullptr) {
                decode->json = json;
                SherpaOnnxFreeKeywordResultJson(json);
            }
        },
        [](napi_env completeEnv, napi_status status, void *data) {
            auto *decode = static_cast<WakeDecodeWork *>(data);
            const std::string result = status == napi_ok ? decode->json :
                R"({"keyword":"","tokens":[],"timestamps":[]})";
            napi_resolve_deferred(completeEnv, decode->deferred, MakeString(completeEnv, result));
            napi_delete_async_work(completeEnv, decode->asyncWork);
            delete decode;
        }, work, &work->asyncWork);
    if (createStatus != napi_ok || napi_queue_async_work(env, work->asyncWork) != napi_ok) {
        napi_resolve_deferred(env, deferred,
            MakeString(env, R"({"keyword":"","tokens":[],"timestamps":[]})"));
        if (work->asyncWork != nullptr) {
            napi_delete_async_work(env, work->asyncWork);
        }
        delete work;
    }
    return promise;
}

napi_value AcceptWakePcm16(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 2) {
        return nullptr;
    }
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, argv[0], &isArrayBuffer);
    if (!isArrayBuffer) {
        return nullptr;
    }
    void *data = nullptr;
    size_t byteLength = 0;
    int32_t sampleRate = 0;
    if (napi_get_arraybuffer_info(env, argv[0], &data, &byteLength) != napi_ok || data == nullptr ||
        byteLength < sizeof(int16_t) || napi_get_value_int32(env, argv[1], &sampleRate) != napi_ok ||
        sampleRate <= 0) {
        return nullptr;
    }

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto *work = new WakeDecodeWork();
    work->deferred = deferred;
    work->sampleRate = sampleRate;
    work->generation = g_modelGeneration;
    const size_t sampleCount = byteLength / sizeof(int16_t);
    work->pcm16Samples.resize(sampleCount);
    std::memcpy(work->pcm16Samples.data(), data, sampleCount * sizeof(int16_t));

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "VoiceWakeDecodePcm16", NAPI_AUTO_LENGTH, &resourceName);
    const napi_status createStatus = napi_create_async_work(env, nullptr, resourceName,
        [](napi_env executeEnv, void *workData) {
            (void)executeEnv;
            auto *decode = static_cast<WakeDecodeWork *>(workData);
            decode->samples.resize(decode->pcm16Samples.size());
            for (size_t i = 0; i < decode->pcm16Samples.size(); ++i) {
                decode->samples[i] = static_cast<float>(decode->pcm16Samples[i]) / 32768.0F;
            }
            decode->pcm16Samples.clear();
            std::lock_guard<std::mutex> lock(g_inferenceMutex);
            if (decode->generation != g_modelGeneration || g_keywordSpotter == nullptr ||
                g_keywordStream == nullptr || decode->samples.empty()) {
                return;
            }
            SherpaOnnxOnlineStreamAcceptWaveform(g_keywordStream, decode->sampleRate,
                decode->samples.data(), static_cast<int32_t>(decode->samples.size()));
            int32_t decodeCount = 0;
            while (SherpaOnnxIsKeywordStreamReady(g_keywordSpotter, g_keywordStream) && decodeCount < 16) {
                SherpaOnnxDecodeKeywordStream(g_keywordSpotter, g_keywordStream);
                ++decodeCount;
            }
            const char *json = SherpaOnnxGetKeywordResultAsJson(g_keywordSpotter, g_keywordStream);
            if (json != nullptr) {
                decode->json = json;
                SherpaOnnxFreeKeywordResultJson(json);
            }
        },
        [](napi_env completeEnv, napi_status status, void *workData) {
            auto *decode = static_cast<WakeDecodeWork *>(workData);
            const std::string result = status == napi_ok ? decode->json :
                R"({"keyword":"","tokens":[],"timestamps":[]})";
            napi_resolve_deferred(completeEnv, decode->deferred, MakeString(completeEnv, result));
            napi_delete_async_work(completeEnv, decode->asyncWork);
            delete decode;
        }, work, &work->asyncWork);
    if (createStatus != napi_ok || napi_queue_async_work(env, work->asyncWork) != napi_ok) {
        napi_resolve_deferred(env, deferred,
            MakeString(env, R"({"keyword":"","tokens":[],"timestamps":[]})"));
        if (work->asyncWork != nullptr) {
            napi_delete_async_work(env, work->asyncWork);
        }
        delete work;
    }
    return promise;
}

napi_value StartCommand(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_recognizer == nullptr) {
        return MakeBool(env, false);
    }
    DestroyCommandStream();
    g_commandStream = SherpaOnnxCreateOnlineStream(g_recognizer);
    return MakeBool(env, g_commandStream != nullptr);
}

napi_value AcceptCommand(napi_env env, napi_callback_info info)
{
    float *samples = nullptr;
    int32_t sampleCount = 0;
    int32_t sampleRate = 0;
    if (!ReadAudioArgs(env, info, &samples, &sampleCount, &sampleRate)) {
        return nullptr;
    }
    if (g_recognizer == nullptr || g_commandStream == nullptr) {
        return MakeDecodeResult(env, R"({"text":"","tokens":[],"timestamps":[]})", false);
    }
    SherpaOnnxOnlineStreamAcceptWaveform(g_commandStream, sampleRate, samples, sampleCount);
    int32_t decodeCount = 0;
    while (SherpaOnnxIsOnlineStreamReady(g_recognizer, g_commandStream) && decodeCount < 16) {
        SherpaOnnxDecodeOnlineStream(g_recognizer, g_commandStream);
        ++decodeCount;
    }
    const char *json = SherpaOnnxGetOnlineStreamResultAsJson(g_recognizer, g_commandStream);
    const std::string result = json == nullptr ? R"({"text":"","tokens":[],"timestamps":[]})" : json;
    if (json != nullptr) {
        SherpaOnnxDestroyOnlineStreamResultJson(json);
    }
    const bool endpoint = SherpaOnnxOnlineStreamIsEndpoint(g_recognizer, g_commandStream) != 0;
    return MakeDecodeResult(env, result, endpoint);
}

napi_value FinishCommand(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_recognizer == nullptr || g_commandStream == nullptr) {
        return MakeString(env, R"({"text":"","tokens":[],"timestamps":[]})");
    }
    SherpaOnnxOnlineStreamInputFinished(g_commandStream);
    int32_t decodeCount = 0;
    while (SherpaOnnxIsOnlineStreamReady(g_recognizer, g_commandStream) && decodeCount < 64) {
        SherpaOnnxDecodeOnlineStream(g_recognizer, g_commandStream);
        ++decodeCount;
    }
    const char *json = SherpaOnnxGetOnlineStreamResultAsJson(g_recognizer, g_commandStream);
    const std::string result = json == nullptr ? R"({"text":"","tokens":[],"timestamps":[]})" : json;
    if (json != nullptr) {
        SherpaOnnxDestroyOnlineStreamResultJson(json);
    }
    return MakeString(env, result);
}

napi_value StartSpeaker(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_speakerExtractor == nullptr) {
        return MakeBool(env, false);
    }
    DestroySpeakerStream();
    g_speakerStream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(g_speakerExtractor);
    return MakeBool(env, g_speakerStream != nullptr);
}

napi_value AcceptSpeaker(napi_env env, napi_callback_info info)
{
    float *samples = nullptr;
    int32_t sampleCount = 0;
    int32_t sampleRate = 0;
    if (!ReadAudioArgs(env, info, &samples, &sampleCount, &sampleRate)) {
        return nullptr;
    }
    if (g_speakerExtractor == nullptr || g_speakerStream == nullptr) {
        return MakeBool(env, false);
    }
    SherpaOnnxOnlineStreamAcceptWaveform(g_speakerStream, sampleRate, samples, sampleCount);
    return MakeBool(env, true);
}

napi_value FinishSpeaker(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_speakerExtractor == nullptr || g_speakerStream == nullptr) {
        return MakeSpeakerResult(env, false, false, "Speaker stream is not active");
    }

    SherpaOnnxOnlineStreamInputFinished(g_speakerStream);
    if (SherpaOnnxSpeakerEmbeddingExtractorIsReady(g_speakerExtractor, g_speakerStream) == 0) {
        DestroySpeakerStream();
        return MakeSpeakerResult(env, false, false, "Not enough speech for speaker embedding");
    }

    const int32_t dimension = SherpaOnnxSpeakerEmbeddingExtractorDim(g_speakerExtractor);
    const float *embedding = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(
        g_speakerExtractor, g_speakerStream);
    if (embedding == nullptr || dimension <= 0) {
        DestroySpeakerStream();
        return MakeSpeakerResult(env, false, true, "Failed to compute speaker embedding");
    }

    napi_value result = MakeSpeakerResult(env, true, true, "Speaker embedding ready",
        embedding, dimension);
    SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(embedding);
    DestroySpeakerStream();
    return result;
}

napi_value CancelSpeaker(napi_env env, napi_callback_info info)
{
    (void)info;
    DestroySpeakerStream();
    return MakeBool(env, true);
}

napi_value Release(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_inferenceMutex);
    DestroyAll();
    return MakeBool(env, true);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"initialize", nullptr, Initialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initializeSpeaker", nullptr, InitializeSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resetWake", nullptr, ResetWake, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptWake", nullptr, AcceptWake, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptWakePcm16", nullptr, AcceptWakePcm16, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCommand", nullptr, StartCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptCommand", nullptr, AcceptCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"finishCommand", nullptr, FinishCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startSpeaker", nullptr, StartSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptSpeaker", nullptr, AcceptSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"finishSpeaker", nullptr, FinishSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelSpeaker", nullptr, CancelSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

}  // namespace

static napi_module g_voiceInferenceModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "voice_inference",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVoiceInferenceModule()
{
    napi_module_register(&g_voiceInferenceModule);
}
