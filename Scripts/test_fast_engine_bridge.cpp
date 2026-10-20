// RimeDynamic registers its merged modules when the framework is loaded.
// The production static-link anchors are unnecessary in this macOS-only check.
void rime_require_module_octagram() {}
void rime_require_module_lua() {}
#include "../CRime/ClearRime.cpp"
