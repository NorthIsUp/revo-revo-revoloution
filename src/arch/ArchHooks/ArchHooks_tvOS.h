#ifndef ARCH_HOOKS_TVOS_H
#define ARCH_HOOKS_TVOS_H

#include "ArchHooks.h"

class ArchHooks_tvOS : public ArchHooks
{
public:
	void Init();
	RString GetArchName() const;
	void DumpDebugInfo();
	RString GetPreferredLanguage();
	float GetDisplayAspectRatio();
	void StartUploadServer() override;
	RString GetAppSetting( RString const &key ) const override;
	void SetAppSetting( RString const &key, RString const &value ) override;
};

#ifdef ARCH_HOOKS
#error "More than one ArchHooks selected!"
#endif
#define ARCH_HOOKS ArchHooks_tvOS

#endif
