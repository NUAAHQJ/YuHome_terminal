#include "nlu_tokenizer.h"

#include <algorithm>
#include <sstream>

namespace yuhome::nlu {
namespace {

std::vector<uint32_t> DecodeUtf8(const std::string &text)
{
    std::vector<uint32_t> codePoints;
    for (size_t i = 0; i < text.size();) {
        const uint8_t first = static_cast<uint8_t>(text[i]);
        uint32_t codePoint = 0;
        size_t length = 0;
        if (first < 0x80) {
            codePoint = first;
            length = 1;
        } else if ((first & 0xE0) == 0xC0 && i + 1 < text.size()) {
            codePoint = static_cast<uint32_t>(first & 0x1F) << 6;
            codePoint |= static_cast<uint8_t>(text[i + 1]) & 0x3F;
            length = 2;
        } else if ((first & 0xF0) == 0xE0 && i + 2 < text.size()) {
            codePoint = static_cast<uint32_t>(first & 0x0F) << 12;
            codePoint |= static_cast<uint32_t>(static_cast<uint8_t>(text[i + 1]) & 0x3F) << 6;
            codePoint |= static_cast<uint8_t>(text[i + 2]) & 0x3F;
            length = 3;
        } else if ((first & 0xF8) == 0xF0 && i + 3 < text.size()) {
            codePoint = static_cast<uint32_t>(first & 0x07) << 18;
            codePoint |= static_cast<uint32_t>(static_cast<uint8_t>(text[i + 1]) & 0x3F) << 12;
            codePoint |= static_cast<uint32_t>(static_cast<uint8_t>(text[i + 2]) & 0x3F) << 6;
            codePoint |= static_cast<uint8_t>(text[i + 3]) & 0x3F;
            length = 4;
        } else {
            codePoint = 0xFFFD;
            length = 1;
        }
        codePoints.push_back(codePoint);
        i += length;
    }
    return codePoints;
}

std::string EncodeUtf8(uint32_t codePoint)
{
    std::string result;
    if (codePoint <= 0x7F) {
        result.push_back(static_cast<char>(codePoint));
    } else if (codePoint <= 0x7FF) {
        result.push_back(static_cast<char>(0xC0 | (codePoint >> 6)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else if (codePoint <= 0xFFFF) {
        result.push_back(static_cast<char>(0xE0 | (codePoint >> 12)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else {
        result.push_back(static_cast<char>(0xF0 | (codePoint >> 18)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    }
    return result;
}

bool IsWhitespace(uint32_t codePoint)
{
    return codePoint == 0x20 || codePoint == 0x09 || codePoint == 0x0A || codePoint == 0x0D ||
        codePoint == 0x00A0 || codePoint == 0x1680 || (codePoint >= 0x2000 && codePoint <= 0x200A) ||
        codePoint == 0x2028 || codePoint == 0x2029 || codePoint == 0x202F || codePoint == 0x205F ||
        codePoint == 0x3000;
}

bool IsControl(uint32_t codePoint)
{
    if (codePoint == 0x09 || codePoint == 0x0A || codePoint == 0x0D) {
        return false;
    }
    return codePoint < 0x20 || (codePoint >= 0x7F && codePoint <= 0x9F) || codePoint == 0xFFFD;
}

bool IsChinese(uint32_t codePoint)
{
    return (codePoint >= 0x3400 && codePoint <= 0x4DBF) ||
        (codePoint >= 0x4E00 && codePoint <= 0x9FFF) ||
        (codePoint >= 0xF900 && codePoint <= 0xFAFF) ||
        (codePoint >= 0x20000 && codePoint <= 0x2A6DF) ||
        (codePoint >= 0x2A700 && codePoint <= 0x2B73F) ||
        (codePoint >= 0x2B740 && codePoint <= 0x2B81F) ||
        (codePoint >= 0x2B820 && codePoint <= 0x2CEAF) ||
        (codePoint >= 0x2F800 && codePoint <= 0x2FA1F);
}

bool IsPunctuation(uint32_t codePoint)
{
    const bool ascii = (codePoint >= 33 && codePoint <= 47) ||
        (codePoint >= 58 && codePoint <= 64) ||
        (codePoint >= 91 && codePoint <= 96) ||
        (codePoint >= 123 && codePoint <= 126);
    return ascii || (codePoint >= 0x2000 && codePoint <= 0x206F) ||
        (codePoint >= 0x2E00 && codePoint <= 0x2E7F) ||
        (codePoint >= 0x3001 && codePoint <= 0x303F) ||
        (codePoint >= 0xFE10 && codePoint <= 0xFE1F) ||
        (codePoint >= 0xFE30 && codePoint <= 0xFE4F) ||
        (codePoint >= 0xFF01 && codePoint <= 0xFF65);
}

std::vector<std::string> SplitUtf8Characters(const std::string &text)
{
    std::vector<std::string> result;
    for (uint32_t codePoint : DecodeUtf8(text)) {
        result.push_back(EncodeUtf8(codePoint));
    }
    return result;
}

}  // namespace

bool BertTokenizer::LoadVocabulary(const std::string &vocabulary, std::string &error)
{
    vocabulary_.clear();
    std::istringstream input(vocabulary);
    std::string token;
    int64_t index = 0;
    while (std::getline(input, token)) {
        if (!token.empty() && token.back() == '\r') {
            token.pop_back();
        }
        vocabulary_.emplace(token, index++);
    }
    const auto findId = [this](const char *tokenName, int64_t &target) {
        const auto found = vocabulary_.find(tokenName);
        if (found == vocabulary_.end()) {
            return false;
        }
        target = found->second;
        return true;
    };
    if (!findId("[PAD]", padId_) || !findId("[UNK]", unknownId_) ||
        !findId("[CLS]", clsId_) || !findId("[SEP]", sepId_)) {
        error = "Vocabulary is missing required BERT special tokens";
        vocabulary_.clear();
        return false;
    }
    return true;
}

bool BertTokenizer::IsReady() const
{
    return !vocabulary_.empty();
}

std::vector<std::string> BertTokenizer::BasicTokenize(const std::string &text) const
{
    std::vector<std::string> tokens;
    std::string current;
    const auto flush = [&tokens, &current]() {
        if (!current.empty()) {
            tokens.push_back(current);
            current.clear();
        }
    };
    for (uint32_t codePoint : DecodeUtf8(text)) {
        if (IsControl(codePoint)) {
            continue;
        }
        if (IsWhitespace(codePoint)) {
            flush();
            continue;
        }
        if (codePoint >= 'A' && codePoint <= 'Z') {
            codePoint += 'a' - 'A';
        }
        if (IsChinese(codePoint) || IsPunctuation(codePoint)) {
            flush();
            tokens.push_back(EncodeUtf8(codePoint));
        } else {
            current += EncodeUtf8(codePoint);
        }
    }
    flush();
    return tokens;
}

std::vector<std::string> BertTokenizer::WordPieceTokenize(const std::string &token) const
{
    const std::vector<std::string> characters = SplitUtf8Characters(token);
    if (characters.size() > 100) {
        return {"[UNK]"};
    }
    std::vector<std::string> pieces;
    size_t start = 0;
    while (start < characters.size()) {
        size_t end = characters.size();
        std::string selected;
        while (start < end) {
            std::string candidate = start == 0 ? "" : "##";
            for (size_t index = start; index < end; ++index) {
                candidate += characters[index];
            }
            if (vocabulary_.find(candidate) != vocabulary_.end()) {
                selected = candidate;
                break;
            }
            --end;
        }
        if (selected.empty()) {
            return {"[UNK]"};
        }
        pieces.push_back(selected);
        start = end;
    }
    return pieces;
}

TokenizedInput BertTokenizer::Encode(const std::string &text, size_t maxLength) const
{
    TokenizedInput result;
    if (!IsReady() || maxLength < 2) {
        return result;
    }
    result.inputIds.reserve(maxLength);
    result.inputIds.push_back(clsId_);
    for (const std::string &token : BasicTokenize(text)) {
        for (const std::string &piece : WordPieceTokenize(token)) {
            if (result.inputIds.size() >= maxLength - 1) {
                break;
            }
            const auto found = vocabulary_.find(piece);
            result.inputIds.push_back(found == vocabulary_.end() ? unknownId_ : found->second);
        }
        if (result.inputIds.size() >= maxLength - 1) {
            break;
        }
    }
    result.inputIds.push_back(sepId_);
    result.attentionMask.assign(result.inputIds.size(), 1);
    result.tokenTypeIds.assign(result.inputIds.size(), 0);
    while (result.inputIds.size() < maxLength) {
        result.inputIds.push_back(padId_);
        result.attentionMask.push_back(0);
        result.tokenTypeIds.push_back(0);
    }
    return result;
}

}  // namespace yuhome::nlu
