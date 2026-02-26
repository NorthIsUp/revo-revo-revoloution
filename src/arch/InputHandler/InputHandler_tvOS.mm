#include "global.h"
#include "InputHandler_tvOS.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "InputFilter.h"
#include "RageInput.h"
#include "RageTimer.h"

#import <GameController/GameController.h>

REGISTER_INPUT_HANDLER_CLASS( tvOS );

static void MapButton( InputHandler_tvOS *handler, DeviceInput di, float value, float threshold = 0.5f )
{
	di.level = value;
	di.bDown = (value >= threshold);
	handler->QueueButton( di );
}

static InputDevice DeviceForControllerIndex( GCController *controller )
{
	NSArray<GCController *> *controllers = [GCController controllers];
	NSUInteger idx = [controllers indexOfObject:controller];
	if( idx == NSNotFound )
		idx = 0;
	if( idx >= (NSUInteger)NUM_JOYSTICKS )
		idx = NUM_JOYSTICKS - 1;
	return (InputDevice)(DEVICE_JOY1 + idx);
}

static void SendButton( InputDevice dev, DeviceButton btn, float value )
{
	if( !INPUTFILTER )
		return;
	DeviceInput di( dev, btn, value, RageTimer() );
	INPUTFILTER->ButtonPressed( di );
}

static void RegisterHandlers( GCController *controller )
{
	if( controller.extendedGamepad )
	{
		GCExtendedGamepad *gp = controller.extendedGamepad;

		gp.dpad.left.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_LEFT, v );
		};
		gp.dpad.right.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_RIGHT, v );
		};
		gp.dpad.up.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_UP, v );
		};
		gp.dpad.down.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_DOWN, v );
		};

		gp.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_1, v );
		};
		gp.buttonB.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_2, v );
		};
		gp.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_3, v );
		};
		gp.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_4, v );
		};

		gp.leftShoulder.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_5, v );
		};
		gp.rightShoulder.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_6, v );
		};
		gp.leftTrigger.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_7, v );
		};
		gp.rightTrigger.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_8, v );
		};

		if (@available(tvOS 13.0, *)) {
			gp.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
				SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_9, v );
			};
			if( gp.buttonOptions )
			{
				gp.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
					SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_10, v );
				};
			}
		}

		gp.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *d, float xVal, float yVal) {
			InputDevice dev = DeviceForControllerIndex(controller);
			SendButton( dev, JOY_LEFT_2, -fminf(xVal, 0.0f) );
			SendButton( dev, JOY_RIGHT_2, fmaxf(xVal, 0.0f) );
			SendButton( dev, JOY_UP_2, fmaxf(yVal, 0.0f) );
			SendButton( dev, JOY_DOWN_2, -fminf(yVal, 0.0f) );
		};

		LOG->Info("Registered value-changed handlers for extended gamepad '%s'",
			controller.vendorName ? [controller.vendorName UTF8String] : "(unknown)");
	}
	else if( controller.microGamepad )
	{
		GCMicroGamepad *gp = controller.microGamepad;
		gp.reportsAbsoluteDpadValues = YES;
		gp.allowsRotation = NO;

		gp.dpad.valueChangedHandler = ^(GCControllerDirectionPad *d, float xVal, float yVal) {
			InputDevice dev = DeviceForControllerIndex(controller);
			SendButton( dev, JOY_LEFT, fmaxf(-xVal, 0.0f) > 0.3f ? fmaxf(-xVal, 0.0f) : 0.0f );
			SendButton( dev, JOY_RIGHT, fmaxf(xVal, 0.0f) > 0.3f ? fmaxf(xVal, 0.0f) : 0.0f );
			SendButton( dev, JOY_UP, fmaxf(yVal, 0.0f) > 0.3f ? fmaxf(yVal, 0.0f) : 0.0f );
			SendButton( dev, JOY_DOWN, fmaxf(-yVal, 0.0f) > 0.3f ? fmaxf(-yVal, 0.0f) : 0.0f );
		};
		gp.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_1, v );
		};
		gp.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
			SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_3, v );
		};

		if (@available(tvOS 13.0, *)) {
			gp.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
				SendButton( DeviceForControllerIndex(controller), JOY_BUTTON_9, v );
			};
		}

		LOG->Info("Registered value-changed handlers for micro gamepad '%s'",
			controller.vendorName ? [controller.vendorName UTF8String] : "(unknown)");
	}
}

InputHandler_tvOS::InputHandler_tvOS()
{
	m_pConnectObserver = nil;
	m_pDisconnectObserver = nil;
	m_bDevicesChanged = false;

	m_pConnectObserver = [[NSNotificationCenter defaultCenter]
		addObserverForName:GCControllerDidConnectNotification
		object:nil
		queue:[NSOperationQueue mainQueue]
		usingBlock:^(NSNotification *note) {
			GCController *c = note.object;
			LOG->Info("Game controller connected: '%s'",
				c.vendorName ? [c.vendorName UTF8String] : "(unknown)");
			RegisterHandlers( c );
			m_bDevicesChanged = true;
		}];

	m_pDisconnectObserver = [[NSNotificationCenter defaultCenter]
		addObserverForName:GCControllerDidDisconnectNotification
		object:nil
		queue:[NSOperationQueue mainQueue]
		usingBlock:^(NSNotification *note) {
			LOG->Info("Game controller disconnected.");
			m_bDevicesChanged = true;
		}];

	LOG->Info("InputHandler_tvOS: Initialized. Found %d controller(s).",
		(int)[[GCController controllers] count]);

	for( GCController *c in [GCController controllers] )
	{
		if( c.extendedGamepad )
			LOG->Info("  - Extended gamepad: '%s'", c.vendorName ? [c.vendorName UTF8String] : "(unknown)");
		else if( c.microGamepad )
			LOG->Info("  - Micro gamepad (Siri Remote): '%s'", c.vendorName ? [c.vendorName UTF8String] : "(unknown)");
		else
			LOG->Info("  - Unknown controller type: '%s'", c.vendorName ? [c.vendorName UTF8String] : "(unknown)");

		RegisterHandlers( c );
	}
}

InputHandler_tvOS::~InputHandler_tvOS()
{
	if( m_pConnectObserver )
	{
		[[NSNotificationCenter defaultCenter] removeObserver:(id)m_pConnectObserver];
		m_pConnectObserver = nil;
	}
	if( m_pDisconnectObserver )
	{
		[[NSNotificationCenter defaultCenter] removeObserver:(id)m_pDisconnectObserver];
		m_pDisconnectObserver = nil;
	}
}

InputDevice InputHandler_tvOS::GetDeviceForController( id controllerObj )
{
	return DeviceForControllerIndex( (GCController *)controllerObj );
}

void InputHandler_tvOS::Update()
{
	if( m_bDevicesChanged )
		m_bDevicesChanged = false;

	UpdateTimer();
}

void InputHandler_tvOS::HandleController( id controllerObj, InputDevice dev )
{
	/* Input is now handled via value-changed handlers registered in
	 * RegisterHandlers(). This method is kept for interface compatibility. */
}

void InputHandler_tvOS::GetDevicesAndDescriptions( std::vector<InputDeviceInfo>& vDevicesOut )
{
	NSArray<GCController *> *controllers = [GCController controllers];
	if( [controllers count] == 0 )
	{
		vDevicesOut.push_back( InputDeviceInfo(DEVICE_JOY1, "Apple TV Remote") );
		return;
	}

	for( NSUInteger i = 0; i < [controllers count] && i < (NSUInteger)NUM_JOYSTICKS; i++ )
	{
		GCController *c = controllers[i];
		InputDevice dev = (InputDevice)(DEVICE_JOY1 + i);

		if( c.extendedGamepad )
		{
			RString desc = ssprintf("MFi Gamepad: %s", c.vendorName ? [c.vendorName UTF8String] : "Unknown");
			vDevicesOut.push_back( InputDeviceInfo(dev, desc) );
		}
		else
		{
			vDevicesOut.push_back( InputDeviceInfo(dev, "Apple TV Remote") );
		}
	}
}
