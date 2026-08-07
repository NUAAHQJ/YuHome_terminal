#ifndef YUHOME_NLU_TOKENIZER_H
#define YUHOME_NLU_TOKENIZER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace yuhome::nlu {

struct TokenizedInput {
    std::vector<int64_t> inputIds;
    std::vector<int64_t> attentionMask;
    std::vector<int64_t> tokenTypeIds;
};

class BertTokenizer {
public:
    bool LoadVocabulary(const std::string &vocabulary, std::string &error);
    bool IsReady() const;
    TokenizedInput Encode(const std::string &text, size_t maxLength) const;

private:
    std::vector<std::string> BasicTokenize(const std::string &text) const;
    std::vector<std::string> WordPieceTokenize(const std::string &token) const;

    std::unordered_map<std::string, int64_t> vocabulary_;
    int64_t padId_ = 0;
    int64_t unknownId_ = 100;
    int64_t clsId_ = 101;
    int64_t sepId_ = 102;
};

}  // namespace yuhome::nlu

#endif
