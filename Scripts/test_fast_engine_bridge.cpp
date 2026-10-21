// RimeDynamic registers its merged modules when the framework is loaded.
// The production static-link anchors are unnecessary in this macOS-only check.
void rime_require_module_octagram() {}
void rime_require_module_lua() {}
#include "../CRime/ClearRime.cpp"

// Diagnostic only: never overrides a device's calibrated production allowance.
extern "C" int cr_test_native_score_limit() {
    return sentence_model ? sentence_model->native_score_limit() : 0;
}
