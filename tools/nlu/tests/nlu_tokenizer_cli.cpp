#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#include "nlu_tokenizer.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "usage: nlu_tokenizer_cli <vocab.txt>\n";
        return 2;
    }
    std::ifstream vocabularyFile(argv[1], std::ios::binary);
    const std::string vocabulary((std::istreambuf_iterator<char>(vocabularyFile)),
        std::istreambuf_iterator<char>());
    yuhome::nlu::BertTokenizer tokenizer;
    std::string error;
    if (!tokenizer.LoadVocabulary(vocabulary, error)) {
        std::cerr << error << '\n';
        return 3;
    }
    std::string text;
    while (std::getline(std::cin, text)) {
        const yuhome::nlu::TokenizedInput encoded = tokenizer.Encode(text, 48);
        for (size_t i = 0; i < encoded.inputIds.size(); ++i) {
            if (i > 0) {
                std::cout << ',';
            }
            std::cout << encoded.inputIds[i];
        }
        std::cout << '\n';
    }
    return 0;
}
