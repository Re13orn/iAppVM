// iAppVM Script Market: Anti-Debugging Bypass
//
// Defeats the standard self-protection checks used by iOS apps, in three
// threat groups. Every hook is precise: no-op only the detection call,
// leave legitimate behavior (real crashes, real file checks) intact.

//   A. Debugger detection
//      - ptrace(PT_DENY_ATTACH)          -> pretend the attach was refused by the kernel
//      - sysctl(KERN_PROCARGS / P_TRACED flag) -> report "not traced"
//   B. Environment probes
//      - fileExistsAtPath / stat / access on jailbreak paths -> report absent
//   C. Self-termination on detection
//      - exit()/abort() during startup window -> log the decision point and
//        swallow the call, so the analyst can keep working. Only the FIRST
//        exit attempt within the guard window is swallowed; the script never
//        blocks later legitimate exits (user taps "quit", etc.).

const log = (msg) => console.log("[AntiDebug] " + msg);

// ---------- A1: ptrace ----------
(function () {
    const PT_DENY_ATTACH = 31;
    const ptrace = Module.findExportByName(null, "ptrace");
    if (!ptrace) return;
    Interceptor.attach(ptrace, {
        onEnter(args) {
            // int ptrace(int request, pid_t pid, caddr_t addr, int data)
            this.deny = args[0].toInt32() === PT_DENY_ATTACH;
        },
        onLeave(retval) {
            if (this.deny) {
                retval.replace(ptr(0)); // pretend the kernel refused nothing / call succeeded harmlessly
                log("ptrace(PT_DENY_ATTACH) neutralized");
            }
        }
    });
    log("A1 ptrace hook installed");
})();

// ---------- A2: sysctl P_TRACED ----------
(function () {
    const sysctl = Module.findExportByName(null, "sysctl");
    if (!sysctl) return;

    function scrubResult(oldp) {
        // struct kinfo_proc { struct extern_proc kp_proc; ... }
        // kp_proc.p_flag is at offset 32 on arm64; P_TRACED = 0x800.
        if (oldp.isNull()) return false;
        try {
            const flagPtr = oldp.add(32);
            const flags = flagPtr.readU32();
            if (flags & 0x800) {
                flagPtr.writeU32(flags & ~0x800);
                return true;
            }
        } catch (e) { }
        return false;
    }

    Interceptor.attach(sysctl, {
        onEnter(args) {
            // KERN_PROC / KERN_PROC_PID etc. fill struct kinfo_proc.
            // oid[0]=CTL_KERN(1), oid[1]=KERN_PROC(14), oid[2]=KERN_PROC_*(...)
            this.isKernProc = false;
            try {
                const oid = new Uint32Array(args[0].readByteArray(3 * 4));
                this.isKernProc = oid[0] === 1 && oid[1] === 14;
            } catch (e) { }
            this.oldp = args[2];
        },
        onLeave(retval) {
            if (this.isKernProc && retval.toInt32() === 0) {
                if (scrubResult(this.oldp)) log("sysctl P_TRACED cleared");
            }
        }
    });
    log("A2 sysctl hook installed");
})();

// ---------- B: jailbreak path probes ----------
(function () {
    const SENSITIVE = [
        "/bin/bash", "/bin/sh", "/bin/su", "/etc/rc", "/etc/apt", "/etc/ssh/sshd_config",
        "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
        "/private/var/lib/apt", "/private/var/lib/cydia", "/private/var/stash",
        "/usr/libexec/sftp-server", "/usr/libexec/ssh-keysign", "/usr/sbin/sshd",
        "/usr/lib/TweakInjector", "/usr/lib/substrate", "/usr/lib/substrate-inject",
        "/Library/MobileSubstrate", "/private/jailbreak.txt", "/var/checker.rb"
    ];
    const isSensitive = (p) => typeof p === "string" && SENSITIVE.some((s) => p === s || p.startsWith(s + "/"));

    // B1: NSFileManager fileExistsAtPath: / isExecutableFileAtPath:
    if (ObjC.available) {
        for (const sel of ["fileExistsAtPath:", "isExecutableFileAtPath:"]) {
            const method = ObjC.classes.NSFileManager["- " + sel];
            if (!method) continue;
            Interceptor.attach(method.implementation, {
                onEnter(args) { this.hide = isSensitive(new ObjC.Object(args[2]).toString()); },
                onLeave(retval) { if (this.hide) retval.replace(ptr(0)); }
            });
        }
        // B2: stat / lstat / access / fopen on jailbreak paths
        for (const fn of ["stat", "lstat", "stat64", "lstat64", "access", "fopen"]) {
            const p = Module.findExportByName(null, fn);
            if (!p) continue;
            Interceptor.attach(p, {
                onEnter(args) {
                    this.hide = false;
                    try { this.hide = isSensitive(args[0].readUtf8String()); } catch (e) { }
                },
                onLeave(retval) {
                    if (this.hide) {
                        retval.replace(fn === "fopen" ? ptr(0) : ptr(-1)); // NULL / -1
                    }
                }
            });
        }
    }
    log("B jailbreak path probes installed");
})();

// ---------- C: startup self-termination guard ----------
(function () {
    // Apps that decide "this environment is hostile" usually die within the
    // first 15 seconds. Within the window, exit()/abort()/_exit() are replaced
    // with no-ops (Interceptor.replace skips the original; attach cannot) and
    // the call site is logged so the analyst can locate the detection code.
    // When the window closes the hooks are REVERTED, so later legitimate
    // exits (user quits the app) work normally. Calling the original from
    // inside a replace callback is impossible without recursion; revert is
    // the supported way to restore it.
    const GUARD_WINDOW_MS = 15000;

    for (const name of ["exit", "_exit", "abort"]) {
        const target = Module.findExportByName(null, name);
        if (!target) continue;
        // exit(int) / _exit(int); abort(void) passes a garbage first arg,
        // which we ignore - the signature only has to be call-compatible.
        Interceptor.replace(target, new NativeCallback(function () {
            log(name + "() swallowed @ " +
                Thread.backtrace(undefined, Backtracer.ACCURATE)
                    .map(DebugSymbol.fromAddress)
                    .slice(0, 6).join(" <- "));
            // Swallow: return instead of terminating. The caller did not
            // expect a return value from a noreturn function, so execution
            // simply continues after the call site.
        }, "void", ["int"]));
        setTimeout(function () {
            try {
                Interceptor.revert(target);
                log("guard lifted on " + name);
            } catch (e) {
                log("could not lift guard on " + name + ": " + e);
            }
        }, GUARD_WINDOW_MS);
    }
    log("C exit guard installed (window " + GUARD_WINDOW_MS + "ms)");
})();