#include <stddef.h>
#include <time.h>
#include <wchar.h>
#include <unistd.h>
#include <pthread.h>

// Build Tracy implementation through a local shim so we can control
// include order under this project's Xcode configuration.
#include "../../libs/tracy/public/TracyClient.cpp"
