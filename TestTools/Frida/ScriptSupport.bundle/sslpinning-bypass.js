// iAppVM Script Market: SSL Pinning Bypass
//
// Forces TLS validation to succeed at every layer an iOS app commonly
// uses, so an HTTPS proxy (Charles / Burp / mitmproxy) sees cleartext.
//
// Layer 1  BoringSSL  ssl_verify_peer_cert -> ssl_verify_ok
//          (URLSession / Alamofire / AFNetworking all terminate here)
// Layer 2  Security.framework  SecTrustEvaluateWithError / SecTrustEvaluate
// Layer 3  AFNetworking  AFSecurityPolicy -evaluateServerTrust:forDomain:
// Layer 4  NSURLSession challenge delegates  auto-answered with default handling
//
// Known limits: WKWebView traffic (separate process) and Flutter apps
// (statically linked BoringSSL, symbols stripped) are not covered.

const log = (msg) => console.log("[SSL-Bypass] " + msg);

// ---------- Layer 1: BoringSSL ----------
(function () {
    let addr = Module.findExportByName("libboringssl.dylib", "ssl_verify_peer_cert");
    if (!addr) {
        const mod = Process.findModuleByName("libboringssl.dylib");
        if (mod) {
            // Not always exported; the symbol table still has it.
            for (const sym of mod.enumerateSymbols()) {
                if (sym.name === "ssl_verify_peer_cert") { addr = sym.address; break; }
            }
        }
    }
    if (addr) {
        // enum ssl_verify_result_t { ssl_verify_ok = 0, ssl_verify_invalid = 1, ... }
        Interceptor.replace(addr, new NativeCallback(function (ssl, outAlert) {
            return 0; // ssl_verify_ok
        }, "int", ["pointer", "pointer"]));
        log("L1 BoringSSL ssl_verify_peer_cert -> ssl_verify_ok");
    } else {
        log("L1 skipped: libboringssl.dylib not present");
    }
})();

// ---------- Layer 2: Security.framework ----------
(function () {
    const evErr = Module.findExportByName(null, "SecTrustEvaluateWithError");
    if (evErr) {
        Interceptor.replace(evErr, new NativeCallback(function (trust, error) {
            if (!error.isNull()) error.writePointer(NULL);
            return 1; // trusted
        }, "bool", ["pointer", "pointer"]));
        log("L2 SecTrustEvaluateWithError -> true");
    }
    const ev = Module.findExportByName(null, "SecTrustEvaluate");
    if (ev) {
        Interceptor.replace(ev, new NativeCallback(function (trust, result) {
            if (!result.isNull()) result.writeU32(1); // kSecTrustResultProceed
            return 0; // errSecSuccess
        }, "int", ["pointer", "pointer"]));
        log("L2 SecTrustEvaluate -> kSecTrustResultProceed");
    }
})();

// ---------- Layer 3: AFNetworking ----------
(function () {
    if (!ObjC.available) return;
    const cls = ObjC.classes.AFSecurityPolicy;
    if (!cls) { log("L3 skipped: AFSecurityPolicy absent"); return; }
    const evaluate = cls["- evaluateServerTrust:forDomain:"];
    if (!evaluate) return;
    Interceptor.replace(evaluate.implementation, new NativeCallback(function () {
        return 1; // YES, covers all pin modes
    }, "bool", ["pointer", "pointer", "pointer", "pointer"]));
    log("L3 AFSecurityPolicy evaluateServerTrust -> YES");
})();

// ---------- Layer 4: NSURLSession challenge delegates ----------
(function () {
    if (!ObjC.available) return;
    const replaced = new Set(); // one implementation may back many subclasses
    let hooked = 0;

    function replaceHandler(impl, invoke) {
        const key = impl.toString();
        if (replaced.has(key)) return;
        replaced.add(key);
        try {
            Interceptor.replace(impl, invoke);
            hooked++;
        } catch (e) { /* abstract classes / metaclass edge cases */ }
    }

    // Session-level: -(void)URLSession:didReceiveChallenge:completionHandler:
    for (const className of Object.keys(ObjC.classes)) {
        let cls;
        try { cls = ObjC.classes[className]; } catch (e) { continue; }
        if (!cls) continue;
        try {
            const session = cls["URLSession:didReceiveChallenge:completionHandler:"];
            if (session && session.implementation) {
                replaceHandler(session.implementation, new NativeCallback(function (self, _cmd, s, challenge, handler) {
                    try {
                        new ObjC.Block(handler)(s, challenge, 0 /* NSURLSessionAuthChallengeUseCredential */, NULL);
                    } catch (e) { console.log("[SSL-Bypass] session challenge failed: " + e); }
                }, "void", ["pointer", "pointer", "pointer", "pointer", "pointer"]));
            }
        } catch (e) { }
        try {
            // Task-level: -(void)URLSession:task:didReceiveChallenge:completionHandler:
            const task = cls["URLSession:task:didReceiveChallenge:completionHandler:"];
            if (task && task.implementation) {
                replaceHandler(task.implementation, new NativeCallback(function (self, _cmd, s, t, challenge, handler) {
                    try {
                        new ObjC.Block(handler)(s, challenge, 0, NULL);
                    } catch (e) { console.log("[SSL-Bypass] task challenge failed: " + e); }
                }, "void", ["pointer", "pointer", "pointer", "pointer", "pointer", "pointer"]));
            }
        } catch (e) { }
    }
    log("L4 challenge delegates hooked: " + hooked);
})();