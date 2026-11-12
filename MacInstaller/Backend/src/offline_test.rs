//! Explicitly invoked with a private temporary setup. Never logs or persists the private key.
use super::*;
use rsa::pkcs8::DecodePrivateKey;
use x509_cert::der::Decode;

fn profile(path: &str) -> isideload::dev::app_ids::Profile {
    let bytes = std::fs::read(path).unwrap();
    let parsed = apple_codesign_quick::ProvisioningProfile::parse(&bytes).unwrap();
    isideload::dev::app_ids::Profile {
        encoded_profile: bytes.into(),
        filename: "fixture.mobileprovision".into(),
        provisioning_profile_id: "fixture".into(),
        name: "offline test".into(),
        status: "active".into(),
        r#type: "iOS".into(),
        distribution_method: "development".into(),
        pro_pro_platorm: None,
        uuid: "fixture".into(),
        date_expire: parsed.plist()["ExpirationDate"].as_date().unwrap(),
        managing_app: None,
        app_id_id: "fixture".into(),
        is_template_profile: false,
        is_team_profile: None,
        is_free_provisioning_profile: None,
    }
}
#[tokio::test]
#[ignore = "requires explicitly supplied local identity; never logs in to Apple or modifies a device"]
async fn real_profile_signs_complete_payload() {
    let config = plist::Value::from_file(
        std::env::var("IAPPVM_OFFLINE_SETUP").expect("private fixture path"),
    )
    .unwrap();
    let d = config.as_dictionary().unwrap();
    let keystore = p12_keystore::KeyStore::from_pkcs12(
        d["certificate"].as_data().unwrap(),
        d["password"].as_string().unwrap(),
        p12_keystore::Pkcs12ImportPolicy::Strict,
    )
    .unwrap();
    let (_, chain) = keystore.private_key_chain().unwrap();
    let identity = CertificateIdentity {
        machine_id: "offline".into(),
        machine_name: "offline".into(),
        private_key: rsa::RsaPrivateKey::from_pkcs8_der(chain.key().as_der()).unwrap(),
        certificate: x509_cert::Certificate::from_der(chain.certs()[0].as_der()).unwrap(),
    };
    let portal = isideload::dev::certificates::DevelopmentCertificate {
        name: None,
        certificate_id: None,
        serial_number: None,
        machine_id: None,
        machine_name: None,
        cert_content: Some(chain.certs()[0].as_der().to_vec().into()),
        certificate_platform: None,
        certificate_type: None,
        status: None,
        status_code: None,
        expiration_date: None,
    };
    let reused = crate::identity_reuse::from_archive(
        d["certificate"].as_data().unwrap(),
        d["password"].as_string().unwrap(),
        &portal,
    )
    .unwrap();
    assert_eq!(reused.get_serial_number(), identity.get_serial_number());
    let mut wrong_portal = portal.clone();
    wrong_portal.cert_content = Some(b"different".to_vec().into());
    assert!(
        crate::identity_reuse::from_archive(
            d["certificate"].as_data().unwrap(),
            d["password"].as_string().unwrap(),
            &wrong_portal
        )
        .is_err()
    );
    // Exercise the archive format used for automatic phone provisioning as well.
    let archive = identity.as_p12("roundtrip-fixture").await.unwrap();
    let roundtrip = p12_keystore::KeyStore::from_pkcs12(
        &archive,
        "roundtrip-fixture",
        p12_keystore::Pkcs12ImportPolicy::Strict,
    )
    .unwrap();
    assert!(roundtrip.private_key_chain().is_some());
    let main = profile(&std::env::var("IAPPVM_OFFLINE_HOST_PROFILE").unwrap());
    let ext = profile(&std::env::var("IAPPVM_OFFLINE_EXTENSION_PROFILE").unwrap());
    let parsed =
        apple_codesign_quick::ProvisioningProfile::parse(main.encoded_profile.as_ref()).unwrap();
    let ext_parsed =
        apple_codesign_quick::ProvisioningProfile::parse(ext.encoded_profile.as_ref()).unwrap();
    let team = DeveloperTeam {
        name: None,
        team_id: parsed.team_id().into(),
        r#type: None,
        status: None,
    };
    let host = d["host"].as_string().unwrap();
    let work = tempfile::tempdir().unwrap();
    let staged = work.path().join("iAppVM.app");
    assert!(
        std::process::Command::new("/usr/bin/ditto")
            .arg(std::env::var("IAPPVM_OFFLINE_PAYLOAD").unwrap())
            .arg(&staged)
            .status()
            .unwrap()
            .success()
    );
    let mut app = Application::new(staged.clone()).unwrap();
    let old = app.main_bundle_id().unwrap();
    app.update_bundle_id(&old, host).unwrap();
    app.bundle.write_info().unwrap();
    for e in app.bundle.app_extensions_mut() {
        e.write_info().unwrap();
    }
    let mut profiles = vec![(
        format!("{}.LiveProcess", host),
        ext,
        ext_parsed.entitlements().clone(),
    )];
    sign::sign(
        &mut app,
        &identity,
        &main,
        &mut profiles,
        &Some(SpecialApp::LiveContainer),
        &team,
        None::<fn(f32) -> std::future::Ready<()>>,
    )
    .await
    .unwrap();
    if let Ok(destination) = std::env::var("IAPPVM_OFFLINE_SIGNED_OUTPUT") {
        assert!(
            std::process::Command::new("/usr/bin/ditto")
                .arg(&staged)
                .arg(destination)
                .status()
                .unwrap()
                .success()
        );
    }
    let result = std::process::Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(&staged)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "OS signature verifier rejected offline result: {}",
        String::from_utf8_lossy(&result.stderr)
    );
}
