#ifndef DIALOG_BOX_DRIVER_TVOS_H
#define DIALOG_BOX_DRIVER_TVOS_H

#include "DialogDriver.h"

class DialogDriver_tvOS : public DialogDriver {
 public:
  void Error(std::string sError, std::string sID);
  void OK(std::string sMessage, std::string sID);
  Dialog::Result OKCancel(std::string sMessage, std::string sID);
  Dialog::Result AbortRetryIgnore(std::string sMessage, std::string sID);
  Dialog::Result AbortRetry(std::string sMessage, std::string sID);
  Dialog::Result YesNo(std::string sMessage, std::string sID);
};

#endif
