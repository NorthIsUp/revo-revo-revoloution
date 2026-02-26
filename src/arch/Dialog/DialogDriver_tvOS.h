#ifndef DIALOG_BOX_DRIVER_TVOS_H
#define DIALOG_BOX_DRIVER_TVOS_H

#include "DialogDriver.h"

class DialogDriver_tvOS: public DialogDriver
{
public:
	void Error( RString sError, RString sID );
	void OK( RString sMessage, RString sID );
	Dialog::Result OKCancel( RString sMessage, RString sID );
	Dialog::Result AbortRetryIgnore( RString sMessage, RString sID );
	Dialog::Result AbortRetry( RString sMessage, RString sID );
	Dialog::Result YesNo( RString sMessage, RString sID );
};

#endif
