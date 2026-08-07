#ifndef YUHOME_NLU_RUNTIME_H
#define YUHOME_NLU_RUNTIME_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace yuhome::nlu {

struct ClassificationResult {
    bool success = false;
    std::string finalLabel = "unknown";
    std::string routeLabel = "unknown";
    float routeConfidence = 0.0F;
    float intentConfidence = 0.0F;
    double latencyMs = 0.0;
    std::string modelVariant;
    std::string message;
};

class Runtime {
public:
    Runtime();
    ~Runtime();
    Runtime(const Runtime &) = delete;
    Runtime &operator=(const Runtime &) = delete;

    bool Initialize(const std::vector<uint8_t> &modelData, const std::string &vocabulary,
        const std::string &modelVariant, std::string &message);
    ClassificationResult Classify(const std::string &text);
    bool IsReady() const;
    std::string ModelVariant() const;
    std::string RuntimeVersion() const;
    void Release();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace yuhome::nlu

#endif
