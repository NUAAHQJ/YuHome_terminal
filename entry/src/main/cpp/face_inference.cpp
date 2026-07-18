#include <node_api.h>
#include <rawfile/raw_file_manager.h>
#include <net.h>

#include <cstdint>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr const char* kBackendName = "native-face-inference";
constexpr const char* kPlannedEngine = "ncnn";
constexpr const char* kDetectorParam = "face_ncnn/det_500m.ncnn.param";
constexpr const char* kDetectorBin = "face_ncnn/det_500m.ncnn.bin";
constexpr const char* kLandmarkParam = "face_ncnn/2d106det.ncnn.param";
constexpr const char* kLandmarkBin = "face_ncnn/2d106det.ncnn.bin";
constexpr const char* kRecognizerParam = "face_ncnn/w600k_mbf.ncnn.param";
constexpr const char* kRecognizerBin = "face_ncnn/w600k_mbf.ncnn.bin";
constexpr bool kEnableNcnnForward = true;
constexpr bool kEnableNcnnZeroForwardProbe = false;
constexpr bool kEnableFacePresenceHardGate = false;
constexpr bool kEnableDetectedFaceCrop = false;

struct ModelState {
    std::unique_ptr<ncnn::Net> net;
    std::vector<unsigned char> paramData;
    std::vector<unsigned char> binData;
};

struct FaceBox {
    float x0 = 0.0f;
    float y0 = 0.0f;
    float x1 = 0.0f;
    float y1 = 0.0f;
};

struct FaceDetection {
    bool ok = false;
    float score = 0.0f;
    FaceBox box;
};

ModelState gDetector;
ModelState gLandmark;
std::unique_ptr<ncnn::Net> gRecognizer;
std::vector<unsigned char> gRecognizerParamData;
std::vector<unsigned char> gRecognizerBinData;
std::string gLastEngineMessage = "NCNN runtime linked; recognizer model not loaded.";

bool ReadRawFile(NativeResourceManager* manager, const char* fileName, std::vector<unsigned char>& out)
{
    if (manager == nullptr || fileName == nullptr) {
        return false;
    }
    RawFile* file = OH_ResourceManager_OpenRawFile(manager, fileName);
    if (file == nullptr) {
        return false;
    }

    const long size = OH_ResourceManager_GetRawFileSize(file);
    if (size <= 0) {
        OH_ResourceManager_CloseRawFile(file);
        return false;
    }

    out.resize(static_cast<size_t>(size));
    size_t total = 0;
    while (total < out.size()) {
        const int read = OH_ResourceManager_ReadRawFile(file, out.data() + total, out.size() - total);
        if (read <= 0) {
            break;
        }
        total += static_cast<size_t>(read);
    }
    OH_ResourceManager_CloseRawFile(file);
    return total == out.size();
}

void ConfigureNet(ncnn::Net& net)
{
    net.opt.use_vulkan_compute = false;
    net.opt.num_threads = 1;
    net.opt.use_packing_layout = false;
    net.opt.use_fp16_packed = false;
    net.opt.use_fp16_storage = false;
    net.opt.use_fp16_arithmetic = false;
    net.opt.use_bf16_storage = false;
}

bool LoadNetFromRawFiles(NativeResourceManager* manager, const char* paramName, const char* binName, ModelState& state, std::string& error)
{
    std::vector<unsigned char> paramData;
    std::vector<unsigned char> binData;
    const bool paramOk = ReadRawFile(manager, paramName, paramData);
    const bool binOk = ReadRawFile(manager, binName, binData);
    if (!paramOk || !binOk) {
        error = std::string("read failed: ") + paramName;
        return false;
    }

    paramData.push_back('\0');
    state.paramData = std::move(paramData);
    state.binData = std::move(binData);
    auto net = std::make_unique<ncnn::Net>();
    ConfigureNet(*net);

    const int loadParam = net->load_param_mem(reinterpret_cast<const char*>(state.paramData.data()));
    const size_t loadModelBytes = loadParam == 0 ? net->load_model(state.binData.data()) : 0;
    if (loadParam != 0 || loadModelBytes == 0) {
        error = "load failed param=" + std::to_string(loadParam) + " bytes=" + std::to_string(loadModelBytes);
        return false;
    }
    state.net = std::move(net);
    return true;
}

napi_value MakeString(napi_env env, const char* value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

void SetNamedString(napi_env env, napi_value object, const char* name, const char* value)
{
    napi_set_named_property(env, object, name, MakeString(env, value));
}

void SetNamedBool(napi_env env, napi_value object, const char* name, bool value)
{
    napi_set_named_property(env, object, name, MakeBool(env, value));
}

void SetNamedInt(napi_env env, napi_value object, const char* name, int32_t value)
{
    napi_value jsValue = nullptr;
    napi_create_int32(env, value, &jsValue);
    napi_set_named_property(env, object, name, jsValue);
}

void SetNamedDouble(napi_env env, napi_value object, const char* name, double value)
{
    napi_value jsValue = nullptr;
    napi_create_double(env, value, &jsValue);
    napi_set_named_property(env, object, name, jsValue);
}

void SetNamedDoubleArray(napi_env env, napi_value object, const char* name, const std::vector<float>& values)
{
    napi_value array = nullptr;
    napi_create_array_with_length(env, values.size(), &array);
    for (size_t i = 0; i < values.size(); ++i) {
        napi_value item = nullptr;
        napi_create_double(env, static_cast<double>(values[i]), &item);
        napi_set_element(env, array, static_cast<uint32_t>(i), item);
    }
    napi_set_named_property(env, object, name, array);
}

napi_value MakeEmbeddingResult(
    napi_env env,
    bool ok,
    const std::string& message,
    const std::vector<float>& embedding,
    const char* preprocessVersion = "center",
    const char* cropMode = "center",
    double qualityScore = -1.0)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetNamedBool(env, result, "ok", ok);
    SetNamedInt(env, result, "dimension", ok ? static_cast<int32_t>(embedding.size()) : 0);
    SetNamedString(env, result, "message", message.c_str());
    SetNamedString(env, result, "preprocessVersion", preprocessVersion);
    SetNamedString(env, result, "cropMode", cropMode);
    SetNamedDouble(env, result, "qualityScore", qualityScore);
    if (ok) {
        SetNamedDoubleArray(env, result, "embedding", embedding);
    }
    return result;
}

uint32_t ReadLeU32(const uint8_t* data)
{
    return static_cast<uint32_t>(data[0]) |
        (static_cast<uint32_t>(data[1]) << 8) |
        (static_cast<uint32_t>(data[2]) << 16) |
        (static_cast<uint32_t>(data[3]) << 24);
}

float ReadMatValue(const ncnn::Mat& mat, size_t index)
{
    if (index >= mat.total()) {
        return 0.0f;
    }
    return mat[index];
}

float MaxScore(const ncnn::Mat& mat)
{
    float best = 0.0f;
    for (size_t i = 0; i < mat.total(); ++i) {
        const float value = ReadMatValue(mat, i);
        if (value > best) {
            best = value;
        }
    }
    return best;
}

size_t MaxScoreIndex(const ncnn::Mat& mat, float& bestScore)
{
    bestScore = 0.0f;
    size_t bestIndex = 0;
    for (size_t i = 0; i < mat.total(); ++i) {
        const float value = ReadMatValue(mat, i);
        if (value > bestScore) {
            bestScore = value;
            bestIndex = i;
        }
    }
    return bestIndex;
}

FaceBox DecodeScrfdBox(const ncnn::Mat& boxMat, size_t anchorIndex, int gridWidth, int stride, float scaleX, float scaleY)
{
    const int pointsPerLevel = gridWidth * gridWidth;
    const int anchor = static_cast<int>(anchorIndex / static_cast<size_t>(pointsPerLevel));
    const int point = static_cast<int>(anchorIndex % static_cast<size_t>(pointsPerLevel));
    const int y = point / gridWidth;
    const int x = point % gridWidth;
    const size_t boxOffset = anchorIndex * 4;
    const float left = ReadMatValue(boxMat, boxOffset) * static_cast<float>(stride);
    const float top = ReadMatValue(boxMat, boxOffset + 1) * static_cast<float>(stride);
    const float right = ReadMatValue(boxMat, boxOffset + 2) * static_cast<float>(stride);
    const float bottom = ReadMatValue(boxMat, boxOffset + 3) * static_cast<float>(stride);
    const float centerX = static_cast<float>(x * stride);
    const float centerY = static_cast<float>(y * stride);
    FaceBox box;
    box.x0 = (centerX - left) / scaleX;
    box.y0 = (centerY - top) / scaleY;
    box.x1 = (centerX + right) / scaleX;
    box.y1 = (centerY + bottom) / scaleY;
    (void)anchor;
    return box;
}

void ClampBox(FaceBox& box, uint32_t width, uint32_t height)
{
    box.x0 = std::max(0.0f, std::min(box.x0, static_cast<float>(width - 1)));
    box.y0 = std::max(0.0f, std::min(box.y0, static_cast<float>(height - 1)));
    box.x1 = std::max(0.0f, std::min(box.x1, static_cast<float>(width - 1)));
    box.y1 = std::max(0.0f, std::min(box.y1, static_cast<float>(height - 1)));
}

FaceBox ExpandToSquareBox(FaceBox box, uint32_t width, uint32_t height)
{
    ClampBox(box, width, height);
    const float boxW = std::max(1.0f, box.x1 - box.x0);
    const float boxH = std::max(1.0f, box.y1 - box.y0);
    const float centerX = (box.x0 + box.x1) * 0.5f;
    const float centerY = (box.y0 + box.y1) * 0.5f;
    const float side = std::max(boxW, boxH) * 1.35f;
    FaceBox square;
    square.x0 = centerX - side * 0.5f;
    square.y0 = centerY - side * 0.5f;
    square.x1 = centerX + side * 0.5f;
    square.y1 = centerY + side * 0.5f;
    ClampBox(square, width, height);
    return square;
}

bool RunFaceDetection(const uint8_t* rgba, uint32_t width, uint32_t height, FaceDetection& detection, std::string& error)
{
    if (gDetector.net == nullptr) {
        error = "detector not loaded";
        return false;
    }
    constexpr int targetSize = 640;
    ncnn::Mat in(targetSize, targetSize, 3);
    for (int y = 0; y < targetSize; ++y) {
        const uint32_t srcY = static_cast<uint32_t>((static_cast<uint64_t>(y) * height) / targetSize);
        for (int x = 0; x < targetSize; ++x) {
            const uint32_t srcX = static_cast<uint32_t>((static_cast<uint64_t>(x) * width) / targetSize);
            const size_t rgbaIndex = (static_cast<size_t>(srcY) * width + srcX) * 4;
            const float r = static_cast<float>(rgba[rgbaIndex]);
            const float g = static_cast<float>(rgba[rgbaIndex + 1]);
            const float b = static_cast<float>(rgba[rgbaIndex + 2]);
            in.channel(0).row(y)[x] = (r - 127.5f) / 128.0f;
            in.channel(1).row(y)[x] = (g - 127.5f) / 128.0f;
            in.channel(2).row(y)[x] = (b - 127.5f) / 128.0f;
        }
    }

    ncnn::Extractor extractor = gDetector.net->create_extractor();
    extractor.input("in0", in);
    ncnn::Mat out0;
    ncnn::Mat out1;
    ncnn::Mat out2;
    ncnn::Mat box0;
    ncnn::Mat box1;
    ncnn::Mat box2;
    const int ret0 = extractor.extract("out0", out0);
    const int ret1 = extractor.extract("out1", out1);
    const int ret2 = extractor.extract("out2", out2);
    const int boxRet0 = extractor.extract("out3", box0);
    const int boxRet1 = extractor.extract("out4", box1);
    const int boxRet2 = extractor.extract("out5", box2);
    if (ret0 != 0 || ret1 != 0 || ret2 != 0 || boxRet0 != 0 || boxRet1 != 0 || boxRet2 != 0) {
        error = "detector extract failed";
        return false;
    }

    float best0 = 0.0f;
    float best1 = 0.0f;
    float best2 = 0.0f;
    const size_t index0 = MaxScoreIndex(out0, best0);
    const size_t index1 = MaxScoreIndex(out1, best1);
    const size_t index2 = MaxScoreIndex(out2, best2);
    const float scaleX = static_cast<float>(targetSize) / static_cast<float>(width);
    const float scaleY = static_cast<float>(targetSize) / static_cast<float>(height);
    detection.ok = true;
    if (best0 >= best1 && best0 >= best2) {
        detection.score = best0;
        detection.box = DecodeScrfdBox(box0, index0, 80, 8, scaleX, scaleY);
    } else if (best1 >= best0 && best1 >= best2) {
        detection.score = best1;
        detection.box = DecodeScrfdBox(box1, index1, 40, 16, scaleX, scaleY);
    } else {
        detection.score = best2;
        detection.box = DecodeScrfdBox(box2, index2, 20, 32, scaleX, scaleY);
    }
    detection.box = ExpandToSquareBox(detection.box, width, height);
    return true;
}

std::string ReadStringArg(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
    return std::string(buffer.data(), copied);
}

napi_value GetBackendInfo(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetNamedString(env, result, "backend", kBackendName);
    SetNamedString(env, result, "plannedEngine", kPlannedEngine);
    SetNamedBool(env, result, "nativeReady", true);
    SetNamedBool(env, result, "engineReady", gDetector.net != nullptr && gLandmark.net != nullptr && gRecognizer != nullptr);
    SetNamedString(env, result, "message", gLastEngineMessage.c_str());
    return result;
}

bool HasSuffix(const std::string& value, const char* suffix)
{
    const size_t suffixLength = std::strlen(suffix);
    return value.size() >= suffixLength &&
        value.compare(value.size() - suffixLength, suffixLength, suffix) == 0;
}

napi_value CheckModelName(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string modelName;
    if (argc >= 1 && argv[0] != nullptr) {
        modelName = ReadStringArg(env, argv[0]);
    }

    const bool hasSupportedSuffix = HasSuffix(modelName, ".onnx") || HasSuffix(modelName, ".param") || HasSuffix(modelName, ".bin");
    const bool underFaceDir = modelName.rfind("face/", 0) == 0 || modelName.rfind("face_ncnn/", 0) == 0;
    const bool ok = underFaceDir && hasSupportedSuffix;

    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetNamedBool(env, result, "ok", ok);
    SetNamedString(env, result, "modelName", modelName.c_str());
    SetNamedString(env, result, "message", ok ? "Model name accepted by native bridge." : "Expected rawfile path like face/w600k_mbf.onnx or face_ncnn/w600k_mbf.ncnn.param.");
    return result;
}

napi_value LoadRecognizer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    bool ok = false;
    std::string message;

    if (argc < 1 || argv[0] == nullptr) {
        message = "resourceManager argument is required.";
    } else {
        NativeResourceManager* manager = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
        if (manager == nullptr) {
            message = "Failed to init native resource manager.";
        } else {
            std::string detectorError;
            const bool detectorOk = LoadNetFromRawFiles(manager, kDetectorParam, kDetectorBin, gDetector, detectorError);
            std::string landmarkError;
            const bool landmarkOk = LoadNetFromRawFiles(manager, kLandmarkParam, kLandmarkBin, gLandmark, landmarkError);
            std::vector<unsigned char> paramData;
            std::vector<unsigned char> binData;
            const bool paramOk = ReadRawFile(manager, kRecognizerParam, paramData);
            const bool binOk = ReadRawFile(manager, kRecognizerBin, binData);
            OH_ResourceManager_ReleaseNativeResourceManager(manager);

            if (!paramOk || !binOk) {
                message = "Failed to read NCNN recognizer model from rawfile.";
            } else {
                paramData.push_back('\0');
                gRecognizerParamData = std::move(paramData);
                gRecognizerBinData = std::move(binData);
                auto net = std::make_unique<ncnn::Net>();
                ConfigureNet(*net);

                const int loadParam = net->load_param_mem(reinterpret_cast<const char*>(gRecognizerParamData.data()));
                const size_t loadModelBytes = loadParam == 0 ? net->load_model(gRecognizerBinData.data()) : 0;
                if (loadParam == 0 && loadModelBytes > 0) {
                    gRecognizer = std::move(net);
                    ok = detectorOk && landmarkOk;
                    message = ok ? "NCNN face models loaded from rawfile." :
                        "NCNN partial load det=" + std::string(detectorOk ? "ok" : detectorError) +
                        " lm=" + std::string(landmarkOk ? "ok" : landmarkError);
                } else {
                    message = "NCNN load failed param=" + std::to_string(loadParam) + " modelBytes=" + std::to_string(loadModelBytes);
                }
            }
        }
    }

    gLastEngineMessage = message;

    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetNamedBool(env, result, "ok", ok);
    SetNamedString(env, result, "message", message.c_str());
    SetNamedInt(env, result, "dimension", ok ? 512 : 0);
    return result;
}

napi_value ExtractEmbeddingStub(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    bool ok = false;
    std::string message;
    std::vector<float> embedding;
    double qualityScore = -1.0;
    const char* cropMode = "center";

    if (gRecognizer == nullptr) {
        message = "Recognizer model is not loaded yet.";
    } else if (argc < 1 || argv[0] == nullptr) {
        message = "RGBA input ArrayBuffer is required.";
    } else {
        void* rawData = nullptr;
        size_t rawLength = 0;
        napi_status bufferStatus = napi_get_arraybuffer_info(env, argv[0], &rawData, &rawLength);
        if (bufferStatus != napi_ok || rawData == nullptr || rawLength < 8) {
            message = "Invalid ArrayBuffer input.";
        } else {
            const uint8_t* input = reinterpret_cast<const uint8_t*>(rawData);
            const uint32_t width = ReadLeU32(input);
            const uint32_t height = ReadLeU32(input + 4);
            const size_t expectedLength = 8 + static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
            if (width < 16 || height < 16 || rawLength < expectedLength) {
                message = "RGBA input size mismatch.";
            } else if (!kEnableNcnnForward && !kEnableNcnnZeroForwardProbe) {
                ok = true;
                message = "native stub ok";
            } else {
                constexpr int targetSize = 112;
                const uint8_t* rgba = input + 8;
                const uint32_t crop = width < height ? width : height;
                const uint32_t cropX = (width - crop) / 2;
                const uint32_t cropY = (height - crop) / 2;
                std::string detectorMessage;
                FaceDetection detection;
                bool useFaceBox = false;
                if (kEnableNcnnForward) {
                    std::string detectorError;
                    const bool detectorOk = RunFaceDetection(rgba, width, height, detection, detectorError);
                    if (!detectorOk) {
                        detectorMessage = " detector=failed";
                        if (kEnableFacePresenceHardGate) {
                            message = "face detector failed: " + detectorError;
                            return MakeEmbeddingResult(env, false, message, embedding);
                        }
                    } else {
                        qualityScore = static_cast<double>(detection.score);
                        detectorMessage = " faceScore=" + std::to_string(detection.score);
                        if (kEnableFacePresenceHardGate && detection.score < 0.65f) {
                            message = "no clear face score=" + std::to_string(detection.score);
                            return MakeEmbeddingResult(env, false, message, embedding);
                        }
                    }
                }

                ncnn::Mat in(targetSize, targetSize, 3);
                if (!kEnableNcnnForward && kEnableNcnnZeroForwardProbe) {
                    in.fill(0.0f);
                } else {
                    useFaceBox = kEnableDetectedFaceCrop && detection.ok && detection.score >= 0.45f &&
                        detection.box.x1 > detection.box.x0 && detection.box.y1 > detection.box.y0;
                    cropMode = useFaceBox ? "face" : "center";
                    for (int y = 0; y < targetSize; ++y) {
                        const float yRatio = (static_cast<float>(y) + 0.5f) / static_cast<float>(targetSize);
                        const uint32_t srcY = useFaceBox ?
                            static_cast<uint32_t>(std::max(0.0f, std::min(detection.box.y0 + yRatio * (detection.box.y1 - detection.box.y0), static_cast<float>(height - 1)))) :
                            cropY + static_cast<uint32_t>((static_cast<uint64_t>(y) * crop) / targetSize);
                        for (int x = 0; x < targetSize; ++x) {
                            const float xRatio = (static_cast<float>(x) + 0.5f) / static_cast<float>(targetSize);
                            const uint32_t srcX = useFaceBox ?
                                static_cast<uint32_t>(std::max(0.0f, std::min(detection.box.x0 + xRatio * (detection.box.x1 - detection.box.x0), static_cast<float>(width - 1)))) :
                                cropX + static_cast<uint32_t>((static_cast<uint64_t>(x) * crop) / targetSize);
                            const size_t rgbaIndex = (static_cast<size_t>(srcY) * width + srcX) * 4;
                            const float r = static_cast<float>(rgba[rgbaIndex]);
                            const float g = static_cast<float>(rgba[rgbaIndex + 1]);
                            const float b = static_cast<float>(rgba[rgbaIndex + 2]);
                            in.channel(0).row(y)[x] = (r - 127.5f) / 128.0f;
                            in.channel(1).row(y)[x] = (g - 127.5f) / 128.0f;
                            in.channel(2).row(y)[x] = (b - 127.5f) / 128.0f;
                        }
                    }
                }

                ncnn::Extractor extractor = gRecognizer->create_extractor();
                extractor.input("in0", in);
                ncnn::Mat out;
                const int extractRet = extractor.extract("out0", out);
                if (extractRet != 0 || out.total() == 0) {
                    message = "NCNN extract failed ret=" + std::to_string(extractRet);
                } else {
                    embedding.resize(out.total());
                    float norm = 0.0f;
                    for (size_t i = 0; i < embedding.size(); ++i) {
                        embedding[i] = out[i];
                        norm += embedding[i] * embedding[i];
                    }
                    norm = std::sqrt(norm);
                    if (norm > 1e-6f) {
                        for (float& value : embedding) {
                            value /= norm;
                        }
                    }
                    ok = embedding.size() == 512;
                    if (!kEnableNcnnForward && kEnableNcnnZeroForwardProbe) {
                        message = ok ? "ncnn zero ok" : "ncnn zero dim=" + std::to_string(embedding.size());
                    } else {
                        message = ok ? (useFaceBox ? "Embedding extracted from face crop." : "Embedding extracted from center crop.") + detectorMessage :
                            "Unexpected embedding dimension=" + std::to_string(embedding.size()) + detectorMessage;
                    }
                }
            }
        }
    }

    return MakeEmbeddingResult(env, ok, message, embedding, "center", cropMode, qualityScore);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        { "getBackendInfo", nullptr, GetBackendInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "checkModelName", nullptr, CheckModelName, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "loadRecognizer", nullptr, LoadRecognizer, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "extractEmbedding", nullptr, ExtractEmbeddingStub, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
