#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace clear {
using Token = int32_t;
struct Cancellation {
    int (*callback)(void *) = nullptr;
    void *opaque = nullptr;
    bool stopped() const { return callback && callback(opaque); }
};
// This is the replaceable inference boundary. It has no pinyin, candidate,
// consumption, fuzzy-matching, learning, or UI responsibilities. Logits are
// unmodified vocabulary-sized values for precisely the supplied token prefix.
class PrefixScorer {
public:
    virtual ~PrefixScorer() = default;
    virtual const std::string &version() const = 0;
    virtual std::vector<float> logits(const std::vector<Token> &prefix, Cancellation cancel) = 0;
    virtual void reset() = 0;
};
// Encoding is deliberately separate from scoring. Future backends must use the
// same pinned tokenizer IDs and may not reinterpret spelling/candidate rules.
class TokenCodec {
public:
    virtual ~TokenCodec() = default;
    virtual std::vector<Token> encode(const std::string &text, bool special, Cancellation cancel) = 0;
};
struct ScoringBackend {
    std::shared_ptr<PrefixScorer> scorer;
    std::shared_ptr<TokenCodec> codec;
};
ScoringBackend makeQwenBackend(const std::string &modelPath);
}
