#ifndef UPLOAD_SERVER_TVOS_H
#define UPLOAD_SERVER_TVOS_H

#include <string>

/** Start the embedded HTTP upload server (tvOS only). No-op if already running.
 *  documentsPath must be the app Documents directory (same path used for
 * mounted /Songs, /Themes, etc.). */
void UploadServer_Start(const std::string& documentsPath);

/** Stop the embedded HTTP upload server (tvOS only). */
void UploadServer_Stop();

#endif
