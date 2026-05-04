#ifndef ARCH_HOOKS_TVOS_H
#define ARCH_HOOKS_TVOS_H

#include "ArchHooks.h"

class ArchHooks_tvOS : public ArchHooks {
 public:
  void Init();
  std::string GetArchName() const;
  void DumpDebugInfo();
  std::string GetPreferredLanguage();
  float GetDisplayAspectRatio();
  void StartUploadServer() override;
  std::string GetAppSetting(const std::string& key) const override;
  void SetAppSetting(const std::string& key, const std::string& value) override;
};

#ifdef ARCH_HOOKS
#error "More than one ArchHooks selected!"
#endif
#define ARCH_HOOKS ArchHooks_tvOS

#endif
