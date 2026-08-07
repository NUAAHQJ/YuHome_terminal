#include "nlu_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <sstream>

#include "nlu_tokenizer.h"
#include "onnxruntime_c_api.h"

namespace yuhome::nlu {
namespace {

constexpr size_t kMaxLength = 48;
constexpr uint32_t kRequiredOrtApiVersion = 16;
constexpr float kConfirmationThreshold = 0.15F;
constexpr float kInDomainThreshold = 0.70F;
constexpr float kIntentThreshold = 0.15F;

constexpr std::array<const char *, 3> kRouteLabels = {
    "in_domain", "requires_confirmation", "unknown"
};

constexpr std::array<const char *, 18> kIntentLabels = {
    "light_set",
    "ac_power_set",
    "curtain_set",
    "ac_temperature_set",
    "ac_mode_set",
    "light_status_query",
    "curtain_status_query",
    "ac_status_query",
    "door_status_query",
    "temperature_query",
    "humidity_query",
    "environment_query",
    "alarm_status_query",
    "comfort_warmer",
    "comfort_cooler",
    "sleep_scene",
    "away_scene",
    "home_scene"
};

template <size_t Size>
std::array<float, Size> Softmax(const float *logits)
{
    std::array<float, Size> probabilities {};
    const float maximum = *std::max_element(logits, logits + Size);
    float total = 0.0F;
    for (size_t index = 0; index < Size; ++index) {
        probabilities[index] = std::exp(logits[index] - maximum);
        total += probabilities[index];
    }
    if (total > 0.0F) {
        for (float &probability : probabilities) {
            probability /= total;
        }
    }
    return probabilities;
}

template <size_t Size>
size_t Argmax(const std::array<float, Size> &values)
{
    return static_cast<size_t>(std::distance(values.begin(),
        std::max_element(values.begin(), values.end())));
}

}  // namespace

struct Runtime::Impl {
    const OrtApi *api = nullptr;
    OrtEnv *environment = nullptr;
    OrtSession *session = nullptr;
    OrtMemoryInfo *memoryInfo = nullptr;
    BertTokenizer tokenizer;
    std::string modelVariant;
    std::string runtimeVersion;

    bool CheckStatus(OrtStatus *status, std::string &error) const
    {
        if (status == nullptr) {
            return true;
        }
        error = api == nullptr ? "Unknown ONNX Runtime error" : api->GetErrorMessage(status);
        if (api != nullptr) {
            api->ReleaseStatus(status);
        }
        return false;
    }

    void Release()
    {
        if (api != nullptr) {
            if (memoryInfo != nullptr) {
                api->ReleaseMemoryInfo(memoryInfo);
            }
            if (session != nullptr) {
                api->ReleaseSession(session);
            }
            if (environment != nullptr) {
                api->ReleaseEnv(environment);
            }
        }
        memoryInfo = nullptr;
        session = nullptr;
        environment = nullptr;
        api = nullptr;
        tokenizer = BertTokenizer();
        modelVariant.clear();
        runtimeVersion.clear();
    }
};

Runtime::Runtime() : impl_(std::make_unique<Impl>())
{
}

Runtime::~Runtime()
{
    Release();
}

bool Runtime::Initialize(const std::vector<uint8_t> &modelData, const std::string &vocabulary,
    const std::string &modelVariant, std::string &message)
{
    Release();
    if (modelData.empty()) {
        message = "NLU model data is empty";
        return false;
    }
    if (!impl_->tokenizer.LoadVocabulary(vocabulary, message)) {
        return false;
    }

    const OrtApiBase *apiBase = OrtGetApiBase();
    if (apiBase == nullptr) {
        message = "OrtGetApiBase returned null";
        Release();
        return false;
    }
    const char *runtimeVersion = apiBase->GetVersionString();
    impl_->runtimeVersion = runtimeVersion == nullptr ? "unknown" : runtimeVersion;
    // sherpa_onnx 1.13.3 packages ONNX Runtime 1.16.3. The v1.17.1
    // declarations are ABI-compatible for the API 16 calls used here.
    impl_->api = apiBase->GetApi(kRequiredOrtApiVersion);
    if (impl_->api == nullptr) {
        message = "ONNX Runtime does not support the requested C API version";
        Release();
        return false;
    }

    OrtSessionOptions *options = nullptr;
    if (!impl_->CheckStatus(impl_->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "yuhome-nlu",
        &impl_->environment), message) ||
        !impl_->CheckStatus(impl_->api->CreateSessionOptions(&options), message)) {
        if (options != nullptr) {
            impl_->api->ReleaseSessionOptions(options);
        }
        Release();
        return false;
    }

    bool configured = impl_->CheckStatus(impl_->api->SetIntraOpNumThreads(options, 2), message) &&
        impl_->CheckStatus(impl_->api->SetInterOpNumThreads(options, 1), message) &&
        impl_->CheckStatus(impl_->api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), message);
    bool sessionCreated = configured && impl_->CheckStatus(impl_->api->CreateSessionFromArray(
        impl_->environment, modelData.data(), modelData.size(), options, &impl_->session), message);
    impl_->api->ReleaseSessionOptions(options);
    if (!sessionCreated || !impl_->CheckStatus(impl_->api->CreateCpuMemoryInfo(
        OrtArenaAllocator, OrtMemTypeDefault, &impl_->memoryInfo), message)) {
        Release();
        return false;
    }

    impl_->modelVariant = modelVariant;
    std::ostringstream status;
    status << "NLU model loaded: " << modelVariant << ", onnxruntime=" << impl_->runtimeVersion
           << ", api=" << kRequiredOrtApiVersion;
    message = status.str();
    return true;
}

ClassificationResult Runtime::Classify(const std::string &text)
{
    ClassificationResult result;
    result.modelVariant = impl_->modelVariant;
    const auto startedAt = std::chrono::steady_clock::now();
    if (!IsReady()) {
        result.message = "NLU runtime is not ready";
        return result;
    }
    TokenizedInput encoded = impl_->tokenizer.Encode(text, kMaxLength);
    if (encoded.inputIds.size() != kMaxLength) {
        result.message = "NLU tokenizer failed";
        return result;
    }

    const std::array<int64_t, 2> shape = {1, static_cast<int64_t>(kMaxLength)};
    std::array<OrtValue *, 3> inputs = {nullptr, nullptr, nullptr};
    const std::array<std::vector<int64_t> *, 3> values = {
        &encoded.inputIds,
        &encoded.attentionMask,
        &encoded.tokenTypeIds
    };
    std::string error;
    for (size_t index = 0; index < inputs.size(); ++index) {
        if (!impl_->CheckStatus(impl_->api->CreateTensorWithDataAsOrtValue(impl_->memoryInfo,
            values[index]->data(), values[index]->size() * sizeof(int64_t), shape.data(), shape.size(),
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[index]), error)) {
            for (OrtValue *value : inputs) {
                if (value != nullptr) {
                    impl_->api->ReleaseValue(value);
                }
            }
            result.message = error;
            return result;
        }
    }

    constexpr std::array<const char *, 3> inputNames = {
        "input_ids", "attention_mask", "token_type_ids"
    };
    constexpr std::array<const char *, 2> outputNames = {
        "route_logits", "intent_logits"
    };
    std::array<OrtValue *, 2> outputs = {nullptr, nullptr};
    const bool ran = impl_->CheckStatus(impl_->api->Run(impl_->session, nullptr, inputNames.data(),
        inputs.data(), inputs.size(), outputNames.data(), outputNames.size(), outputs.data()), error);
    for (OrtValue *value : inputs) {
        impl_->api->ReleaseValue(value);
    }
    if (!ran) {
        for (OrtValue *value : outputs) {
            if (value != nullptr) {
                impl_->api->ReleaseValue(value);
            }
        }
        result.message = error;
        return result;
    }

    float *routeLogits = nullptr;
    float *intentLogits = nullptr;
    const bool outputReady = impl_->CheckStatus(
        impl_->api->GetTensorMutableData(outputs[0], reinterpret_cast<void **>(&routeLogits)), error) &&
        impl_->CheckStatus(
            impl_->api->GetTensorMutableData(outputs[1], reinterpret_cast<void **>(&intentLogits)), error);
    if (outputReady && routeLogits != nullptr && intentLogits != nullptr) {
        const std::array<float, kRouteLabels.size()> routeProbabilities = Softmax<kRouteLabels.size()>(routeLogits);
        const std::array<float, kIntentLabels.size()> intentProbabilities = Softmax<kIntentLabels.size()>(intentLogits);
        const size_t routeIndex = Argmax(routeProbabilities);
        const size_t intentIndex = Argmax(intentProbabilities);
        result.routeLabel = kRouteLabels[routeIndex];
        result.routeConfidence = routeProbabilities[routeIndex];
        result.intentConfidence = intentProbabilities[intentIndex];
        if (routeProbabilities[1] >= kConfirmationThreshold) {
            result.finalLabel = "requires_confirmation";
        } else if (routeProbabilities[0] >= kInDomainThreshold &&
            result.intentConfidence >= kIntentThreshold) {
            result.finalLabel = kIntentLabels[intentIndex];
        } else {
            result.finalLabel = "unknown";
        }
        result.success = true;
        result.message = "ok";
    } else {
        result.message = error.empty() ? "NLU output tensors are invalid" : error;
    }
    for (OrtValue *value : outputs) {
        if (value != nullptr) {
            impl_->api->ReleaseValue(value);
        }
    }
    result.latencyMs = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - startedAt).count();
    return result;
}

bool Runtime::IsReady() const
{
    return impl_->api != nullptr && impl_->session != nullptr && impl_->memoryInfo != nullptr &&
        impl_->tokenizer.IsReady();
}

std::string Runtime::ModelVariant() const
{
    return impl_->modelVariant;
}

std::string Runtime::RuntimeVersion() const
{
    return impl_->runtimeVersion;
}

void Runtime::Release()
{
    impl_->Release();
}

}  // namespace yuhome::nlu
