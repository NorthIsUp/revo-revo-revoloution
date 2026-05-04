#include "DialogDriver_tvOS.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "global.h"

REGISTER_DIALOG_DRIVER_CLASS(tvOS);

void DialogDriver_tvOS::OK(std::string sMessage, std::string sID) {
  LOG->Info("Dialog OK: %s", sMessage.c_str());
}

void DialogDriver_tvOS::Error(std::string sError, std::string sID) {
  LOG->Warn("Dialog Error: %s", sError.c_str());
}

Dialog::Result DialogDriver_tvOS::OKCancel(std::string sMessage, std::string sID) {
  LOG->Info("Dialog OKCancel: %s", sMessage.c_str());
  return Dialog::ok;
}

Dialog::Result DialogDriver_tvOS::AbortRetryIgnore(std::string sMessage, std::string sID) {
  LOG->Info("Dialog AbortRetryIgnore: %s", sMessage.c_str());
  return Dialog::ignore;
}

Dialog::Result DialogDriver_tvOS::AbortRetry(std::string sMessage, std::string sID) {
  LOG->Info("Dialog AbortRetry: %s", sMessage.c_str());
  return Dialog::abort;
}

Dialog::Result DialogDriver_tvOS::YesNo(std::string sMessage, std::string sID) {
  LOG->Info("Dialog YesNo: %s", sMessage.c_str());
  return Dialog::yes;
}
