#include "global.h"
#include "ArchHooks_tvOS.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ProductInfo.h"
#include "RageFileManager.h"

#include <cstddef>
#include <cstdint>

#include <sys/types.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
extern "C" {
#include <mach/mach_time.h>
}

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

void ArchHooks_tvOS::Init()
{
	CFStringRef key = CFSTR( "ApplicationBundlePath" );

	CFBundleRef bundle = CFBundleGetMainBundle();
	CFStringRef appID = CFBundleGetIdentifier( bundle );
	if( appID == nil )
		return;

	CFStringRef version = CFStringRef( CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleVersionKey) );
	CFPropertyListRef old = CFPreferencesCopyAppValue( key, appID );
	CFURLRef path = CFBundleCopyBundleURL( bundle );
	CFPropertyListRef value = CFURLCopyFileSystemPath( path, kCFURLPOSIXPathStyle );
	CFMutableDictionaryRef newDict = nil;

	if( old && CFGetTypeID(old) != CFDictionaryGetTypeID() )
	{
		CFRelease( old );
		old = nil;
	}

	if( !old )
	{
		newDict = CFDictionaryCreateMutable( kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
						     &kCFTypeDictionaryValueCallBacks );
		CFDictionaryAddValue( newDict, version, value );
	}
	else
	{
		CFTypeRef oldValue;
		CFDictionaryRef dict = CFDictionaryRef( old );

		if( !CFDictionaryGetValueIfPresent(dict, version, &oldValue) || !CFEqual(oldValue, value) )
		{
			newDict = CFDictionaryCreateMutableCopy( kCFAllocatorDefault, 0, dict );
			CFDictionarySetValue( newDict, version, value );
		}
		CFRelease( old );
	}

	if( newDict )
	{
		CFPreferencesSetAppValue( key, newDict, appID );
		CFPreferencesAppSynchronize( appID );
		CFRelease( newDict );
	}
	CFRelease( value );
	CFRelease( path );
}

RString ArchHooks_tvOS::GetArchName() const
{
	return "tvOS (arm64)";
}

void ArchHooks_tvOS::DumpDebugInfo()
{
	RString SystemVersion;
	{
		NSString *version = [[UIDevice currentDevice] systemVersion];
		NSString *model = [[UIDevice currentDevice] model];
		SystemVersion = ssprintf("tvOS %s (%s)",
			[version cStringUsingEncoding:NSUTF8StringEncoding],
			[model cStringUsingEncoding:NSUTF8StringEncoding]);
	}

	size_t size;
#define GET_PARAM( name, var ) (size = sizeof(var), sysctlbyname(name, &var, &size, nil, 0) )
	float fRam;
	{
		uint64_t iRam = 0;
		GET_PARAM( "hw.memsize", iRam );
		fRam = float( double(iRam) / 1073741824.0 );
	}

	int iCPUs = 0;
	int iMaxCPUs = 0;
	GET_PARAM( "hw.logicalcpu_max", iMaxCPUs );
	GET_PARAM( "hw.logicalcpu", iCPUs );
#undef GET_PARAM

	LOG->Info( "CPUs: %d/%d", iCPUs, iMaxCPUs );
	LOG->Info( "%s", SystemVersion.c_str() );
	LOG->Info( "Memory: %.2f GB", fRam );
}

RString ArchHooks::GetPreferredLanguage()
{
	CFStringRef app = kCFPreferencesCurrentApplication;
	CFTypeRef t = CFPreferencesCopyAppValue( CFSTR("AppleLanguages"), app );
	RString ret = "en";

	if( t == nil )
		return ret;
	if( CFGetTypeID(t) != CFArrayGetTypeID() )
	{
		CFRelease( t );
		return ret;
	}

	CFArrayRef languages = CFArrayRef( t );
	CFStringRef lang;

	if( CFArrayGetCount(languages) > 0 &&
		(lang = (CFStringRef)CFArrayGetValueAtIndex(languages, 0)) != nil )
	{
		const char *str = CFStringGetCStringPtr( lang, kCFStringEncodingMacRoman );
		if( str )
		{
			ret = RString( str, 2 );
			if (ret == "zh")
			{
				ret = RString(str, 7);
				ret[2] = '-';
			}
		}
		else
			LOG->Warn( "Unable to determine system language. Using English." );
	}

	CFRelease( languages );
	return ret;
}

int64_t ArchHooks::GetSystemTimeInMicroseconds()
{
	static double factor = 0.0;

	if( unlikely(factor == 0.0) )
	{
		mach_timebase_info_data_t timeBase;
		mach_timebase_info( &timeBase );
		factor = timeBase.numer / ( 1000.0 * timeBase.denom );
	}
	return int64_t( mach_absolute_time() * factor );
}

void ArchHooks::MountInitialFilesystems( const RString &sDirOfExecutable )
{
	FILEMAN->Mount("dirro", sDirOfExecutable, "/");

	NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
	if( resourcePath )
	{
		const char* rp = [resourcePath UTF8String];
		FILEMAN->Mount( "dirro", ssprintf("%s/Announcers", rp), "/Announcers" );
		FILEMAN->Mount( "dirro", ssprintf("%s/BGAnimations", rp), "/BGAnimations" );
		FILEMAN->Mount( "dirro", ssprintf("%s/BackgroundEffects", rp), "/BackgroundEffects" );
		FILEMAN->Mount( "dirro", ssprintf("%s/BackgroundTransitions", rp), "/BackgroundTransitions" );
		FILEMAN->Mount( "dirro", ssprintf("%s/CDTitles", rp), "/CDTitles" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Characters", rp), "/Characters" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Courses", rp), "/Courses" );
		FILEMAN->Mount( "dirro", ssprintf("%s/NoteSkins", rp), "/NoteSkins" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Packages", rp), "/Packages" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Songs", rp), "/Songs" );
		FILEMAN->Mount( "dirro", ssprintf("%s/RandomMovies", rp), "/RandomMovies" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Themes", rp), "/Themes" );
		FILEMAN->Mount( "dirro", ssprintf("%s/Data", rp), "/Data" );
	}

	CFURLRef dataUrl = CFBundleCopyResourceURL( CFBundleGetMainBundle(), CFSTR("StepMania"), CFSTR("smzip"), nil );
	if( dataUrl )
	{
		char dir[PATH_MAX];
		CFStringRef dataPath = CFURLCopyFileSystemPath( dataUrl, kCFURLPOSIXPathStyle );
		CFStringGetCString( dataPath, dir, PATH_MAX, kCFStringEncodingUTF8 );

		if( strncmp(sDirOfExecutable.c_str(), dir, sDirOfExecutable.length()) == 0 )
			FILEMAN->Mount( "zip", dir + sDirOfExecutable.length(), "/" );
		CFRelease( dataPath );
		CFRelease( dataUrl );
	}
}

static std::string PathForDirectory( NSSearchPathDirectory directory )
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSURL *url = [fileManager URLForDirectory:directory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
	if (url == nil)
		FAIL_M( "URLForDirectory() failed." );

	return [url fileSystemRepresentation];
}

void ArchHooks::MountUserFilesystems( const RString &sDirOfExecutable )
{
	// tvOS has a sandboxed filesystem — use Documents and Caches directories
	std::string docsDir = PathForDirectory(NSDocumentDirectory);
	FILEMAN->Mount( "dir", docsDir + "/Save", "/Save" );
	FILEMAN->Mount( "dir", docsDir + "/Songs", "/Songs" );
	FILEMAN->Mount( "dir", docsDir + "/Packages", "/Packages" );
	FILEMAN->Mount( "dir", docsDir + "/NoteSkins", "/NoteSkins" );
	FILEMAN->Mount( "dir", docsDir + "/Themes", "/Themes" );
	FILEMAN->Mount( "dir", docsDir + "/Courses", "/Courses" );
	FILEMAN->Mount( "dir", docsDir + "/Downloads", "/Downloads" );

	std::string cachesDir = PathForDirectory(NSCachesDirectory);
	FILEMAN->Mount( "dir", cachesDir + "/Cache", "/Cache" );
	FILEMAN->Mount( "dir", cachesDir + "/Logs", "/Logs" );
	FILEMAN->Mount( "dir", cachesDir + "/Screenshots", "/Screenshots" );
}

float ArchHooks_tvOS::GetDisplayAspectRatio()
{
	UIScreen *screen = [UIScreen mainScreen];
	CGRect bounds = screen.bounds;
	return bounds.size.width / bounds.size.height;
}
