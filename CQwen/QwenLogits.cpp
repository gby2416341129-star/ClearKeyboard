#include "ScoringBackend.h"
#include "llama.h"
#include <algorithm>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace clear {
namespace {
#if defined(CLEAR_KEYBOARD_EXTENSION) && CLEAR_KEYBOARD_EXTENSION
constexpr bool extension = true;
#else
constexpr bool extension = false;
#endif
class QwenLogits final : public PrefixScorer, public TokenCodec {
    std::string path;
    const std::string identity = "qwen35:bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517:caa8191:raw-logits-v1";
    llama_model *model = nullptr;
    llama_context *context = nullptr;
    const llama_vocab *vocab = nullptr;
    bool modelUsesGPU = false;
    std::vector<Token> evaluated;
    Cancellation active;
    static bool abort(void *opaque) {return static_cast<QwenLogits *>(opaque)->active.stopped();}
    static bool progress(float, void *opaque) {return !abort(opaque);}
    bool prepare(Cancellation cancel) {
        active = cancel;
        if(cancel.stopped()) return false;
        if(context) return true;
        static std::once_flag once;
        std::call_once(once, [] {
            if constexpr(!extension) {
                setenv("GGML_METAL_NO_RESIDENCY", "1", 1);
                setenv("GGML_METAL_TENSOR_DISABLE", "1", 1);
            }
            llama_backend_init();
        });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = extension ? 0 : -1; mp.load_mode = LLAMA_LOAD_MODE_MMAP; mp.use_extra_bufts = false;
        mp.progress_callback = progress; mp.progress_callback_user_data = this;
        if(!model) {model = llama_model_load_from_file(path.c_str(), mp); modelUsesGPU = !extension && model;}
        if(!model && !extension && !cancel.stopped()) {mp.n_gpu_layers = 0; model = llama_model_load_from_file(path.c_str(), mp); modelUsesGPU = false;}
        if(!model) {
            if(cancel.stopped()) return false;
            throw std::runtime_error("Cannot load the pinned Qwen3.5 GGUF");
        }
        char architecture[64] = {};
        llama_model_meta_val_str(model, "general.architecture", architecture, sizeof(architecture));
        if(std::string(architecture) != "qwen35") throw std::runtime_error("Unexpected Qwen architecture");
        vocab = llama_model_get_vocab(model);
        if(cancel.stopped()) return false;
        auto cp = llama_context_default_params();
        cp.n_ctx = 768; cp.n_batch = extension ? 32 : 64; cp.n_ubatch = extension ? 4 : 16;
        cp.n_seq_max = 1; cp.n_rs_seq = 0; cp.no_perf = true;
        cp.offload_kqv = modelUsesGPU; cp.op_offload = modelUsesGPU;
        cp.n_threads = cp.n_threads_batch = std::max(1, std::min(2, int(std::thread::hardware_concurrency())));
        cp.abort_callback = abort; cp.abort_callback_data = this;
        context = llama_init_from_model(model, cp);
        if(!context && modelUsesGPU && !cancel.stopped()) {
            llama_model_free(model); model = nullptr; vocab = nullptr; mp.n_gpu_layers = 0;
            model = llama_model_load_from_file(path.c_str(), mp); modelUsesGPU = false;
            if(model) {
                vocab = llama_model_get_vocab(model); cp.offload_kqv = false; cp.op_offload = false;
                context = llama_init_from_model(model, cp);
            }
        }
        if(!context && !cancel.stopped()) throw std::runtime_error("Cannot create Qwen hybrid context");
        evaluated.clear();
        return context && !cancel.stopped();
    }
public:
    explicit QwenLogits(std::string modelPath): path(std::move(modelPath)) {}
    ~QwenLogits() override {if(context) llama_free(context); if(model) llama_model_free(model);}
    const std::string &version() const override {return identity;}
    void reset() override {
        evaluated.clear();
        if(context) llama_memory_clear(llama_get_memory(context), false);
    }
    std::vector<Token> encode(const std::string &text, bool special, Cancellation cancel) override {
        struct Clear {Cancellation &c; ~Clear(){c={};}} clear{active};
        if(text.empty() || !prepare(cancel)) return {};
        int n = llama_tokenize(vocab, text.data(), int(text.size()), nullptr, 0, special, special);
        if(n >= 0) return {};
        std::vector<Token> tokens(size_t(-n));
        n = llama_tokenize(vocab, text.data(), int(text.size()), tokens.data(), int(tokens.size()), special, special);
        if(n < 0) throw std::runtime_error("Qwen tokenizer rejected input");
        tokens.resize(n); return tokens;
    }
    std::vector<float> logits(const std::vector<Token> &prefix, Cancellation cancel) override {
        struct Clear {Cancellation &c; ~Clear(){c={};}} clear{active};
        if(prefix.empty() || prefix.size() > 740 || !prepare(cancel)) return {};
        const int vocabulary = llama_vocab_n_tokens(vocab);
        if(std::any_of(prefix.begin(), prefix.end(), [&](Token t){return t < 0 || t >= vocabulary;}))
            throw std::runtime_error("Token prefix does not match the pinned vocabulary");
        if(evaluated.size() > prefix.size() || !std::equal(evaluated.begin(), evaluated.end(), prefix.begin())) reset();
        for(size_t offset = evaluated.size(); offset < prefix.size();) {
            if(cancel.stopped()) {reset(); return {};}
            int count = int(std::min(size_t(extension ? 32 : 64), prefix.size() - offset));
            auto batch = llama_batch_get_one(const_cast<Token *>(prefix.data() + offset), count);
            if(llama_decode(context, batch) != 0) {reset(); return {};}
            evaluated.insert(evaluated.end(), prefix.begin() + offset, prefix.begin() + offset + count);
            offset += count;
        }
        if(cancel.stopped()) {reset(); return {};}
        const float *values = llama_get_logits_ith(context, -1);
        if(!values) {reset(); throw std::runtime_error("Qwen produced no raw logits");}
        return {values, values + vocabulary};
    }
};
}
ScoringBackend makeQwenBackend(const std::string &modelPath) {
    auto backend = std::make_shared<QwenLogits>(modelPath);
    return {backend, backend};
}
}
