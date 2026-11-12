/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Inspired by Nyxian HWHook (emexlab, 2025-2026), pinned at
 * 350dd8dbeb796bc0ff5bc91ef770f1a2994432e7. See ../README.md.
 * Uses its Mach-exception/hardware-breakpoint approach; owns no executable pages.
 * This implementation adds explicit errors, slot checks, existing-debug-state
 * rejection, exception-port restoration, and a joined server lifetime.
 */
#include "iOSVMHWHook.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/exc.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

#if !defined(__arm64__) || defined(__arm64e__)
#error This experimental SDK is validated only for arm64, not arm64e or simulators.
#endif

struct IOSVMHWContext {
    thread_t target;
    pthread_t server;
    mach_port_t port;
    mach_msg_type_number_t oldCount;
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    arm_debug_state64_t previous, enabled;
    IOSVMHWHook hooks[16];
    size_t count;
    bool debugChanged;
    _Atomic int command; // 1 enter, 2 enable, 3 disable, 4 exit
    _Atomic int result;
};
static _Thread_local IOSVMHWContext *current;

size_t IOSVMHWCapacity(void) {
    unsigned count = 0; size_t size = sizeof(count);
    if (sysctlbyname("hw.optional.breakpoint", &count, &size, NULL, 0) != 0) count = 1;
    return count > 16 ? 16 : count;
}
static void restorePorts(IOSVMHWContext *ctx) {
    // First clear ours, including when the saved configuration contains no port.
    thread_set_exception_ports(ctx->target, EXC_MASK_BREAKPOINT, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    for (mach_msg_type_number_t i = 0; i < ctx->oldCount; i++)
        thread_set_exception_ports(ctx->target, ctx->masks[i], ctx->ports[i], ctx->behaviors[i], ctx->flavors[i]);
}
static void dispose(IOSVMHWContext *ctx) {
    if (ctx->port) mach_port_destruct(mach_task_self(), ctx->port, -1, 0);
    for (mach_msg_type_number_t i = 0; i < ctx->oldCount; i++)
        if (ctx->ports[i]) mach_port_deallocate(mach_task_self(), ctx->ports[i]);
    if (ctx->target) mach_port_deallocate(mach_task_self(), ctx->target);
    free(ctx);
}

static void *serve(void *opaque) {
    IOSVMHWContext *ctx = opaque;
    for (;;) {
        union { __Request__exception_raise_t request; char buffer[2048]; } incoming;
        memset(&incoming, 0, sizeof(incoming));
        mach_msg_return_t mr = mach_msg(&incoming.request.Head, MACH_RCV_MSG, 0, sizeof(incoming), ctx->port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (mr != MACH_MSG_SUCCESS) return NULL;
        __Request__exception_raise_t *request = &incoming.request;
        kern_return_t handled = KERN_FAILURE;
        bool stop = false;
        arm_thread_state64_t state;
        arm_exception_state64_t exception;
        mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT, exceptionCount = ARM_EXCEPTION_STATE64_COUNT;
        if (request->Head.msgh_id == 2401 && request->exception == EXC_BREAKPOINT &&
            thread_get_state(request->thread.name, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS &&
            thread_get_state(request->thread.name, ARM_EXCEPTION_STATE64, (thread_state_t)&exception, &exceptionCount) == KERN_SUCCESS) {
            unsigned ec = (exception.__esr >> 26) & 0x3f;
            if (ec == 0x3c && (exception.__esr & 0xffff) == 1337) {
                int command = atomic_load(&ctx->command), result = 0;
                if (command == 1) {
                    mach_msg_type_number_t debugCount = ARM_DEBUG_STATE64_COUNT;
                    if (thread_get_state(request->thread.name, ARM_DEBUG_STATE64, (thread_state_t)&ctx->previous, &debugCount) != KERN_SUCCESS) result = EPERM;
                    else {
                        for (size_t i = 0; i < 16; i++)
                            if ((ctx->previous.__bcr[i] & 1) || (ctx->previous.__wcr[i] & 1)) result = EBUSY;
                        ctx->enabled = ctx->previous;
                        for (size_t i = 0; i < ctx->count; i++) {
                            ctx->enabled.__bvr[i] = (uintptr_t)ctx->hooks[i].target;
                            ctx->enabled.__bcr[i] = (0xfu << 5) | (2u << 1) | 1u;
                        }
                    }
                }
                if (!result && (command != 4 || ctx->debugChanged)) {
                    arm_debug_state64_t *debug = (command == 1 || command == 2) ? &ctx->enabled : &ctx->previous;
                    if (thread_set_state(request->thread.name, ARM_DEBUG_STATE64, (thread_state_t)debug, ARM_DEBUG_STATE64_COUNT) != KERN_SUCCESS) result = EPERM;
                    else ctx->debugChanged = command == 1 || command == 2;
                }
                state.__pc += 4;
                handled = thread_set_state(request->thread.name, ARM_THREAD_STATE64, (thread_state_t)&state, stateCount);
                atomic_store(&ctx->result, result);
                stop = command == 4 && result == 0;
            } else if (ec == 0x30 || ec == 0x31) {
                for (size_t i = 0; i < ctx->count; i++) if (state.__pc == (uintptr_t)ctx->hooks[i].target) {
                    state.__pc = (uintptr_t)ctx->hooks[i].replacement;
                    handled = thread_set_state(request->thread.name, ARM_THREAD_STATE64, (thread_state_t)&state, stateCount);
                    break;
                }
            }
        }
        __Reply__exception_raise_t reply = {0};
        reply.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request->Head.msgh_bits), 0);
        reply.Head.msgh_remote_port = request->Head.msgh_remote_port;
        reply.Head.msgh_id = request->Head.msgh_id + 100;
        reply.Head.msgh_size = sizeof(reply);
        reply.NDR = NDR_record;
        reply.RetCode = handled;
        mr = mach_msg(&reply.Head, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        // The reply right has been consumed by mach_msg; dispose descriptor rights.
        request->Head.msgh_remote_port = MACH_PORT_NULL;
        mach_msg_destroy(&request->Head);
        if (stop || mr != MACH_MSG_SUCCESS) return NULL;
    }
}
static int control(IOSVMHWContext *ctx, int command) {
    atomic_store(&ctx->command, command);
    atomic_store(&ctx->result, EIO);
    __asm__ volatile("brk #1337" ::: "memory");
    return atomic_load(&ctx->result);
}
int IOSVMHWEnter(const IOSVMHWHook *hooks, size_t count, IOSVMHWContext **out) {
    if (!out) return EINVAL;
    *out = NULL;
    if (current) return EBUSY;
    if (!hooks || !count) return EINVAL;
    if (count > IOSVMHWCapacity()) return ENOSPC;
    for (size_t i = 0; i < count; i++) {
        if (!hooks[i].target || !hooks[i].replacement || hooks[i].target == hooks[i].replacement ||
            ((uintptr_t)hooks[i].target & 3) || ((uintptr_t)hooks[i].replacement & 3)) return EINVAL;
        for (size_t j = 0; j < i; j++) if (hooks[j].target == hooks[i].target) return EINVAL;
    }
    IOSVMHWContext *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return ENOMEM;
    memcpy(ctx->hooks, hooks, count * sizeof(*hooks)); ctx->count = count;
    ctx->target = mach_thread_self(); ctx->oldCount = EXC_TYPES_COUNT;
    kern_return_t kr = thread_get_exception_ports(ctx->target, EXC_MASK_BREAKPOINT, ctx->masks, &ctx->oldCount, ctx->ports, ctx->behaviors, ctx->flavors);
    if (kr != KERN_SUCCESS) { ctx->oldCount = 0; dispose(ctx); return EPERM; }
    for (mach_msg_type_number_t i = 0; i < ctx->oldCount; i++)
        if (ctx->ports[i]) { dispose(ctx); return EBUSY; }
    mach_port_options_t options = {.flags = MPO_INSERT_SEND_RIGHT};
    kr = mach_port_construct(mach_task_self(), &options, 0, &ctx->port);
    if (kr != KERN_SUCCESS) { dispose(ctx); return EPERM; }
    kr = thread_set_exception_ports(ctx->target, EXC_MASK_BREAKPOINT, ctx->port, EXCEPTION_DEFAULT, ARM_THREAD_STATE64);
    if (kr != KERN_SUCCESS) { dispose(ctx); return EPERM; }
    int result = pthread_create(&ctx->server, NULL, serve, ctx);
    if (result) { restorePorts(ctx); dispose(ctx); return result; }
    current = ctx;
    result = control(ctx, 1);
    if (result) { IOSVMHWExit(ctx); return result; }
    *out = ctx;
    return 0;
}
int IOSVMHWSetEnabled(IOSVMHWContext *ctx, bool enabled) {
    if (!ctx || current != ctx) return EINVAL;
    return control(ctx, enabled ? 2 : 3);
}
int IOSVMHWExit(IOSVMHWContext *ctx) {
    if (!ctx || current != ctx) return EINVAL;
    int result = control(ctx, 4);
    if (result) return result; // Keep the server/context alive so restoration can be retried.
    // Once the server replied, wait until it no longer references this context.
    pthread_join(ctx->server, NULL);
    restorePorts(ctx); current = NULL; dispose(ctx);
    return result;
}
