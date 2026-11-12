// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct IOSVMHWContext IOSVMHWContext;
typedef struct { void *target; void *replacement; } IOSVMHWHook;
// All operations affect only the calling thread. 0 means success, otherwise errno.
size_t IOSVMHWCapacity(void);
int IOSVMHWEnter(const IOSVMHWHook *hooks, size_t count, IOSVMHWContext **context);
int IOSVMHWSetEnabled(IOSVMHWContext *context, bool enabled);
int IOSVMHWExit(IOSVMHWContext *context);
#ifdef __cplusplus
}
#endif
