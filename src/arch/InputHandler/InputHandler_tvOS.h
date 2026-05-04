#ifndef INPUT_HANDLER_TVOS_H
#define INPUT_HANDLER_TVOS_H

#include <objc/objc.h>

#include <vector>

#include "InputHandler.h"

class InputHandler_tvOS : public InputHandler {
 public:
  InputHandler_tvOS();
  ~InputHandler_tvOS();

  void Update();
  bool DevicesChanged() { return m_bDevicesChanged; }
  void GetDevicesAndDescriptions(std::vector<InputDeviceInfo>& vDevicesOut);

  void QueueButton(DeviceInput di) { ButtonPressed(di); }

 private:
  id m_pConnectObserver;
  id m_pDisconnectObserver;
  bool m_bDevicesChanged;

  InputDevice GetDeviceForController(id controller);
  void HandleController(id controller, InputDevice dev);
};

#endif
