#include "global.h"
#include "RageUtil.h"
#include "DialogDriver_tvOS.h"
#include "RageLog.h"

REGISTER_DIALOG_DRIVER_CLASS( tvOS );

void DialogDriver_tvOS::OK( RString sMessage, RString sID )
{
	LOG->Info( "Dialog OK: %s", sMessage.c_str() );
}

void DialogDriver_tvOS::Error( RString sError, RString sID )
{
	LOG->Warn( "Dialog Error: %s", sError.c_str() );
}

Dialog::Result DialogDriver_tvOS::OKCancel( RString sMessage, RString sID )
{
	LOG->Info( "Dialog OKCancel: %s", sMessage.c_str() );
	return Dialog::ok;
}

Dialog::Result DialogDriver_tvOS::AbortRetryIgnore( RString sMessage, RString sID )
{
	LOG->Info( "Dialog AbortRetryIgnore: %s", sMessage.c_str() );
	return Dialog::ignore;
}

Dialog::Result DialogDriver_tvOS::AbortRetry( RString sMessage, RString sID )
{
	LOG->Info( "Dialog AbortRetry: %s", sMessage.c_str() );
	return Dialog::abort;
}

Dialog::Result DialogDriver_tvOS::YesNo( RString sMessage, RString sID )
{
	LOG->Info( "Dialog YesNo: %s", sMessage.c_str() );
	return Dialog::yes;
}
