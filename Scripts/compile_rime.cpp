#include "../CRime/private/rime_api.h"
#include <string>
#include <iostream>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  std::string path = argv[1];
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = path.c_str(); traits.user_data_dir = path.c_str();
  traits.app_name = "rime.clear.compiler"; traits.min_log_level = 2; traits.log_dir = "";
  static const char *modules[] = {"default", "deployer", "lua", "octagram", nullptr};
  traits.modules = modules;
  auto api = rime_get_api(); api->setup(&traits); api->deployer_initialize(&traits);
  bool ok = api->deploy_schema((path + "/clear_pinyin.schema.yaml").c_str());
  api->finalize();
  std::cout << (ok ? "Rime dictionary deployed\n" : "Rime dictionary deployment FAILED\n");
  return ok ? 0 : 1;
}
