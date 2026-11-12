Source: apple-codesign-quick 0.1.0 from crates.io, repository https://github.com/Dadoum/apple-crates
License: LGPL-2.1-or-later (upstream Cargo metadata).

iAppVM change: `src/bundle.rs::encode_binary_plist` writes XML Info.plist bytes rather than binary. The plist dependency's binary writer can emit exactly 256 objects using one-byte object references; macOS `plutil` and `codesign` reject this main Info.plist. Python plistlib accepts it. In the actual iAppVM payload this caused the upstream signer to return Ok while the OS rejected the app as unsigned / invalid Info.plist. XML avoids the boundary and the signer's Info.plist digest uses those same XML bytes. Resource manifests were already XML upstream. No signing checks are disabled.

Regression: MacInstaller/Backend/src/offline_test.rs signs the complete iAppVM payload with a real local certificate/profile and requires `codesign --verify --deep --strict` success. It does not contact Apple or install anything.

Additional packaging compatibility: standalone dylibs directly inside iOSVMProbe.bundle and iOSVMFrida.bundle use the host signing identifier, matching scripts/sign-device-host.py. Other libraries retain upstream identifier behavior. Entitlements and signature verification remain unchanged.
