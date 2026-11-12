//! Reuse a portal certificate only when its exact DER matches a local private-key identity.
use super::*;
use base64::{Engine, prelude::BASE64_STANDARD};
use isideload::{
    dev::certificates::{CertificatesApi, DevelopmentCertificate},
    util::storage::SideloadingStorage,
};
use rsa::{pkcs1::EncodeRsaPublicKey, pkcs8::DecodePrivateKey};
use x509_cert::der::Decode;

#[derive(serde::Deserialize)]
struct LocalIdentity {
    fingerprint: String,
    certificate: String,
    name: String,
}
fn matching<'a>(
    local: &'a [LocalIdentity],
    portal: &'a [DevelopmentCertificate],
) -> Vec<(&'a LocalIdentity, &'a DevelopmentCertificate)> {
    local
        .iter()
        .filter(|l| {
            l.fingerprint.len() == 40 && l.fingerprint.bytes().all(|c| c.is_ascii_hexdigit())
        })
        .filter_map(|l| {
            let der = BASE64_STANDARD.decode(&l.certificate).ok()?;
            let p = portal.iter().find(|p| {
                p.cert_content
                    .as_ref()
                    .is_some_and(|d| d.as_ref() == der.as_slice())
                    && p.expiration_date.is_none_or(|date| {
                        std::time::SystemTime::from(date) > std::time::SystemTime::now()
                    })
            })?;
            Some((l, p))
        })
        .collect()
}
pub(super) fn from_archive(
    bytes: &[u8],
    password: &str,
    portal: &DevelopmentCertificate,
) -> Result<CertificateIdentity, Report> {
    let ks = p12_keystore::KeyStore::from_pkcs12(
        bytes,
        password,
        p12_keystore::Pkcs12ImportPolicy::Strict,
    )?;
    let (_, chain) = ks
        .private_key_chain()
        .ok_or_else(|| report!("本机证书缺少私钥"))?;
    let key = rsa::RsaPrivateKey::from_pkcs8_der(chain.key().as_der())?;
    let certificate = chain
        .certs()
        .first()
        .ok_or_else(|| report!("本机签名身份缺少证书"))?;
    if portal.cert_content.as_ref().map(|d| d.as_ref()) != Some(certificate.as_der()) {
        bail!("本机证书与 Apple 团队记录不匹配");
    }
    let certificate = x509_cert::Certificate::from_der(certificate.as_der())?;
    if certificate
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        != Some(key.to_public_key().to_pkcs1_der()?.as_bytes())
    {
        bail!("本机证书与私钥不匹配");
    }
    Ok(CertificateIdentity {
        private_key: key,
        certificate,
        machine_id: portal.machine_id.clone().unwrap_or_default(),
        machine_name: portal
            .machine_name
            .clone()
            .unwrap_or_else(|| "Existing Mac identity".into()),
    })
}
async fn bridge(command: &str, fingerprint: Option<&str>) -> Result<Zeroizing<Vec<u8>>, Report> {
    let path = std::env::current_exe()?
        .parent()
        .ok_or_else(|| report!("签名助手路径无效"))?
        .join("iappvm-signing-identity");
    let mut child = tokio::process::Command::new(path);
    child.arg(command).kill_on_drop(true);
    if let Some(f) = fingerprint {
        child.arg(f);
    }
    let output = child.output().await?;
    if !output.status.success() {
        bail!("无法读取选中的本机签名身份，请解锁登录钥匙串，并在系统提示中允许此次访问");
    }
    if output.stdout.len() > 1_048_576 {
        bail!("本机签名身份数据过大");
    }
    Ok(Zeroizing::new(output.stdout))
}
pub async fn reuse(
    dev: &mut DeveloperSession,
    team: &DeveloperTeam,
    store: &dyn SideloadingStorage,
) -> Result<Option<CertificateIdentity>, Report> {
    let portal = dev
        .list_ios_certs(team)
        .await
        .context("无法查询现有开发证书")?;
    let bytes = bridge("list", None).await?;
    let local: Vec<LocalIdentity> = serde_json::from_slice(&bytes)?;
    let candidates = matching(&local, &portal);
    if candidates.is_empty() {
        return Ok(None);
    }
    // A prior explicit authorization in this assistant is reused only while the portal still
    // contains that exact certificate. Revoked/different-team identities never match.
    for (local, p) in &candidates {
        if let Some(bytes) =
            store.retrieve_data(&format!("existing-identity/{}", local.fingerprint))?
        {
            let value = plist::Value::from_reader(std::io::Cursor::new(Zeroizing::new(bytes)))?;
            let d = value
                .as_dictionary()
                .ok_or_else(|| report!("已保存的签名身份无效"))?;
            return Ok(Some(from_archive(
                d.get("certificate")
                    .and_then(plist::Value::as_data)
                    .ok_or_else(|| report!("签名身份缺少证书"))?,
                d.get("password")
                    .and_then(plist::Value::as_string)
                    .ok_or_else(|| report!("签名身份无法解锁"))?,
                p,
            )?));
        }
    }
    let response = prompt(
        "reuse_certificate",
        json!({"certificates":candidates.iter().map(|(l,_)|json!({"fingerprint":l.fingerprint,"name":l.name})).collect::<Vec<_>>(),"team":team.team_id}),
    )?;
    let selected = field(&response, "fingerprint")?;
    let (local, p) = candidates
        .into_iter()
        .find(|(l, _)| l.fingerprint == selected)
        .ok_or_else(|| report!("请选择匹配的本机开发证书"))?;
    stage(
        "provision",
        "正在复用现有开发证书；如有钥匙串提示，请在本机允许…",
        0.23,
    );
    let bytes = bridge("export", Some(&local.fingerprint)).await?;
    let value = plist::Value::from_reader(std::io::Cursor::new(&*bytes))?;
    let d = value
        .as_dictionary()
        .ok_or_else(|| report!("本机签名身份格式无效"))?;
    let identity = from_archive(
        d.get("certificate")
            .and_then(plist::Value::as_data)
            .ok_or_else(|| report!("签名身份缺少证书"))?,
        d.get("password")
            .and_then(plist::Value::as_string)
            .ok_or_else(|| report!("签名身份无法解锁"))?,
        p,
    )?;
    store.store_data(&format!("existing-identity/{}", local.fingerprint), &bytes)?;
    Ok(Some(identity))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn portal(der: &[u8]) -> DevelopmentCertificate {
        DevelopmentCertificate {
            name: None,
            certificate_id: None,
            serial_number: None,
            machine_id: None,
            machine_name: None,
            cert_content: Some(der.to_vec().into()),
            certificate_platform: None,
            certificate_type: None,
            status: None,
            status_code: None,
            expiration_date: None,
        }
    }
    #[test]
    fn matching_requires_exact_portal_der_and_valid_local_reference() {
        let locals = vec![LocalIdentity {
            fingerprint: "A".repeat(40),
            certificate: BASE64_STANDARD.encode(b"fixture"),
            name: "fixture".into(),
        }];
        assert_eq!(matching(&locals, &[portal(b"fixture")]).len(), 1);
        assert!(matching(&locals, &[portal(b"other")]).is_empty());
        let mut revoked = portal(b"fixture");
        revoked.expiration_date = Some(std::time::UNIX_EPOCH.into());
        assert!(matching(&locals, &[revoked]).is_empty());
    }
}
