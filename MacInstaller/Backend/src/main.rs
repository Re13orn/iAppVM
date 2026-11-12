//! Private stdin/stdout JSON-lines protocol. Never put credentials in argv or logs.
mod identity_reuse;
use idevice::{
    IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    house_arrest::HouseArrestClient,
    lockdown::LockdownClient,
    provider::IdeviceProvider,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi,
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{
        application::{Application, SpecialApp},
        builder::{ExtensionsBehavior, MaxCertsBehavior},
        cert_identity::CertificateIdentity,
        sign,
    },
    util::{callbacks::MaxCertsCallbackBox, keyring_storage::KeyringStorage},
};
use rootcause::prelude::*;
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
    time::Duration,
};
use zeroize::Zeroizing;

const SETUP: &str = "/Library/iOSVM-signing-setup.plist";
const STATUS: &str = "/Library/iOSVM-signing-status.json";
const SERVICE: &str = "com.iappvm.installer.signing.v1";
struct PendingSetup {
    udid: String,
    host: String,
    id: String,
    path: String,
}
static PENDING: std::sync::Mutex<Option<PendingSetup>> = std::sync::Mutex::new(None);
async fn cleanup_pending() {
    let pending = PENDING.lock().ok().and_then(|mut p| p.take());
    if let Some(marker) = pending {
        let cleanup = async {
            if let Ok(p) = provider(&marker.udid).await {
                if let Ok(mut afc) = container(&p, &marker.host).await {
                    let _ = afc.remove(&marker.path).await;
                    if let Ok(bytes) = read_small(&mut afc, SETUP).await {
                        if let Ok(v) = plist::Value::from_reader(std::io::Cursor::new(bytes)) {
                            if v.as_dictionary()
                                .and_then(|d| d.get("id"))
                                .and_then(plist::Value::as_string)
                                == Some(marker.id.as_str())
                            {
                                let _ = afc.remove(SETUP).await;
                            }
                        }
                    }
                }
            }
        };
        let _ = tokio::time::timeout(Duration::from_secs(8), cleanup).await;
    }
}

// Traverse contexts only, never report attachments (upstream attaches decrypted account plists).
fn public_error(error: &Report) -> String {
    let summary = format!("{}", error.as_ref().format_current_context_unhooked());
    let mut details = Vec::new();
    for node in error.iter_reports() {
        if let Some(e) = node.downcast_current_context::<isideload::SideloadError>() {
            match e {
                isideload::SideloadError::AuthWithMessage(code, _) => {
                    details.push(format!("Apple 认证错误码：{}", code))
                }
                isideload::SideloadError::DeveloperError(code, _) => {
                    details.push(format!("Apple 开发者服务错误码：{}", code))
                }
                _ => {}
            }
        }
        if let Some(e) = node.downcast_current_context::<reqwest::Error>() {
            let cause = if let Some(status) = e.status() {
                format!("HTTP {}", status.as_u16())
            } else if e.is_timeout() {
                "网络连接超时".into()
            } else if e.is_connect() {
                "无法建立网络连接（包含 DNS/TLS 失败）".into()
            } else if e.is_decode() {
                "服务响应格式无法解析".into()
            } else {
                "网络请求失败".into()
            };
            details.push(cause);
        }
        let text = format!("{}", node.format_current_context_unhooked());
        for (needle, label) in [
            (
                "Failed to get anisette client info",
                "获取认证辅助服务信息失败",
            ),
            ("Failed to request /v3/client_info", "请求认证辅助服务失败"),
            (
                "Failed to parse /v3/client_info",
                "认证辅助服务返回格式无效",
            ),
            ("Failed to fetch URL Bag", "读取 Apple 登录服务地址失败"),
            ("Failed to parse URL Bag", "Apple 登录服务返回内容无法解析"),
            ("URL Bag plist missing", "Apple 登录服务未返回所需地址"),
            ("Failed to connect to anisette", "无法连接认证辅助服务"),
            ("Failed to start provisioning", "认证设备数据初始化失败"),
        ] {
            if text.contains(needle) {
                details.push(label.to_string());
            }
        }
    }
    details.dedup();
    if details.is_empty() {
        summary
    } else {
        format!("{}\n{}", summary, details.join("；"))
    }
}

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{}", value);
    let _ = out.flush();
}
fn stage(id: &str, text: &str, progress: f64) {
    emit(json!({"event":"progress","stage":id,"message":text,"progress":progress}));
}
fn receive() -> Result<Value, Report> {
    let mut line = Zeroizing::new(String::new());
    // read_until with a bounded reader: malformed IPC cannot exhaust memory.
    use std::io::Read;
    let n = io::stdin().lock().take(131073).read_line(&mut line)?;
    if n == 0 {
        bail!("操作已取消");
    }
    if n > 131072 {
        bail!("安装助手收到过大的请求");
    }
    Ok(serde_json::from_str(&line)?)
}
fn prompt(kind: &str, data: Value) -> Result<Value, Report> {
    let id = uuid::Uuid::new_v4().to_string();
    emit(json!({"event":"prompt","id":id,"kind":kind,"data":data}));
    let reply = receive()?;
    if reply.get("id").and_then(Value::as_str) != Some(id.as_str()) {
        bail!("操作会话已改变，请重新开始");
    }
    if reply.get("cancel").and_then(Value::as_bool) == Some(true) {
        bail!("操作已取消");
    }
    Ok(reply)
}
fn field<'a>(v: &'a Value, name: &str) -> Result<&'a str, Report> {
    v.get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| report!("缺少必要输入：{}", name))
}
async fn provider(udid: &str) -> Result<impl IdeviceProvider, Report> {
    let mut mux = UsbmuxdConnection::default()
        .await
        .context("无法连接手机服务，请连接 USB 并信任此电脑")?;
    let device = mux
        .get_devices()
        .await?
        .into_iter()
        .find(|d| d.udid == udid && d.connection_type == Connection::Usb)
        .ok_or_else(|| report!("所选手机已断开，请重新连接 USB"))?;
    Ok(device.to_provider(UsbmuxdAddr::from_env_var()?, "iAppVM Installer"))
}
async fn devices() -> Result<(), Report> {
    let mut mux = UsbmuxdConnection::default().await?;
    let mut result = Vec::new();
    for d in mux
        .get_devices()
        .await?
        .into_iter()
        .filter(|d| d.connection_type == Connection::Usb)
    {
        let p = d.to_provider(UsbmuxdAddr::from_env_var()?, "iAppVM Installer");
        let mut item = json!({"udid":d.udid,"name":"iPhone / iPad","version":"","paired":false});
        if let Ok(mut lock) = LockdownClient::connect(&p).await {
            if let Ok(v) = lock.get_value(Some("DeviceName"), None).await {
                item["name"] = json!(v.as_string().unwrap_or("iPhone / iPad"));
            }
            if let Ok(v) = lock.get_value(Some("ProductVersion"), None).await {
                item["version"] = json!(v.as_string().unwrap_or(""));
            }
            if let Ok(pair) = p.get_pairing_file().await {
                item["paired"] = json!(lock.start_session(&pair).await.is_ok());
            }
        }
        result.push(item);
    }
    emit(json!({"event":"devices","devices":result}));
    Ok(())
}
async fn container(p: &impl IdeviceProvider, bundle: &str) -> Result<AfcClient, Report> {
    Ok(HouseArrestClient::connect(p)
        .await?
        .vend_container(bundle)
        .await?)
}
async fn read_small(afc: &mut AfcClient, path: &str) -> Result<Vec<u8>, Report> {
    let mut file = afc.open(path, AfcFopenMode::RdOnly).await?;
    let bytes = file.read_n(65537).await;
    let close = file.close().await;
    let bytes = bytes?;
    close?;
    if bytes.len() > 65536 {
        bail!("设备状态文件过大");
    }
    Ok(bytes)
}
fn payload_info(path: &Path) -> Result<plist::Dictionary, Report> {
    let value = plist::Value::from_file(path.join("Info.plist"))?;
    let info = value
        .into_dictionary()
        .ok_or_else(|| report!("安装包信息无效"))?;
    let exe = info
        .get("CFBundleExecutable")
        .and_then(plist::Value::as_string)
        .ok_or_else(|| report!("缺少主程序"))?;
    if exe.contains('/') || exe == ".." || !path.join(exe).is_file() {
        bail!("安装包主程序无效");
    }
    if info
        .get("IOSVMInstallerPayloadVersion")
        .and_then(plist::Value::as_unsigned_integer)
        != Some(1)
    {
        bail!("此安装包不是安装助手的专用载荷，请重新下载完整安装助手");
    }
    if !path.join("PlugIns/LiveProcess.appex/Info.plist").is_file() {
        bail!("安装包缺少独立测试窗口扩展");
    }
    let exts = std::fs::read_dir(path.join("PlugIns"))?.collect::<std::io::Result<Vec<_>>>()?;
    if exts.len() != 1 || exts[0].file_name() != "LiveProcess.appex" {
        bail!("安装包包含未支持的扩展");
    }
    Ok(info)
}
fn select_team(teams: &[DeveloperTeam]) -> Result<DeveloperTeam, Report> {
    if teams.len() == 1 {
        return Ok(teams[0].clone());
    }
    if teams.is_empty() {
        bail!("账号没有可用的开发团队，请先在 Apple 开发者网站完成账号启用与协议确认");
    }
    let r = prompt(
        "team",
        json!({"teams":teams.iter().map(|t|json!({"id":t.team_id,"name":t.name})).collect::<Vec<_>>()}),
    )?;
    let id = field(&r, "team")?;
    teams
        .iter()
        .find(|t| t.team_id == id)
        .cloned()
        .ok_or_else(|| report!("选择的开发团队无效"))
}
fn host_identifier(team: &str) -> Result<String, Report> {
    if team.len() != 10
        || !team
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        bail!("开发团队标识格式无效");
    }
    Ok(format!("com.iappvm.container.{}", team))
}
async fn install(req: Value) -> Result<(), Report> {
    let udid = field(&req, "udid")?.to_owned();
    let payload = PathBuf::from(field(&req, "payload")?);
    payload_info(&payload)?;
    let p = provider(&udid).await?;
    let info = isideload::util::device::IdeviceInfo::from_device(&p)
        .await
        .context("请解锁手机并点击信任此电脑后重试")?;
    let email = field(&req, "email")?.trim().to_owned();
    let password = Zeroizing::new(field(&req, "password")?.to_owned());
    let anisette_url = req
        .get("anisette")
        .and_then(Value::as_str)
        .unwrap_or("https://ani.iloader.app")
        .to_owned();
    if !anisette_url.starts_with("https://") {
        bail!("认证辅助服务必须使用 HTTPS");
    }
    // Drop the original JSON containing the password before awaiting any network call.
    drop(req);
    stage("login", "正在登录 Apple 账号…", 0.08);
    let ani = RemoteV3AnisetteProvider::new(
        &anisette_url,
        Box::new(KeyringStorage::new(format!("{}.anisette", SERVICE))),
        "0".into(),
    )?;
    let mut account = AppleAccount::builder(&email)
        .anisette_provider(ani)
        .err_429_retries(Some(1))
        .build()
        .await
        .context("无法初始化 Apple 登录服务")?;
    stage("login", "正在验证 Apple 账号，可能需要双重认证…", 0.1);
    account
        .login(&password, async |params| {
            let r = prompt("two_factor", serde_json::to_value(&params)?)?;
            match r.get("action").and_then(Value::as_str).unwrap_or("code") {
                "sms" => Ok(TwoFactorCallbackResponse::SendSms(
                    r.get("number")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| report!("请选择接收验证码的号码"))?
                        as u32,
                )),
                "devices" => Ok(TwoFactorCallbackResponse::SendToDevices),
                "resend" => Ok(TwoFactorCallbackResponse::ResendCode),
                _ => {
                    let code = field(&r, "code")?.trim().to_owned();
                    if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
                        bail!("请输入六位验证码");
                    }
                    Ok(TwoFactorCallbackResponse::SubmitCode(code))
                }
            }
        })
        .await
        .context("Apple 账号登录失败")?;
    drop(password);
    stage("provision", "正在准备设备和签名身份…", 0.18);
    let mut dev = DeveloperSession::from_account(&mut account).await?;
    let team = select_team(&dev.list_teams().await?)?;
    let host = host_identifier(&team.team_id)?;
    dev.ensure_device_registered(&team, &info.name, &info.udid, None)
        .await?;
    // The storage namespace includes the team to avoid mixing identities between teams.
    let store = KeyringStorage::new(format!("{}.{}", SERVICE, team.team_id));
    let behavior = MaxCertsBehavior::<MaxCertsCallbackBox>::Error;
    let identity = if let Some(existing) = identity_reuse::reuse(&mut dev, &team, &store).await? {
        existing
    } else {
        CertificateIdentity::retrieve("iAppVM Installer",&email,&mut dev,&team,&store,&behavior).await
        .context("现有证书已满，且本机没有可复用的对应私钥。请在原签名电脑运行助手，或管理已有签名证书后重试；助手不会自动撤销证书")?
    };
    let work = tempfile::tempdir()?;
    let staged = work.path().join("iAppVM.app");
    if !std::process::Command::new("/usr/bin/ditto")
        .arg(&payload)
        .arg(&staged)
        .status()?
        .success()
    {
        bail!("无法准备安装包");
    }
    let mut app = Application::new(staged.clone())?;
    let old = app.main_bundle_id()?;
    app.update_bundle_id(&old, &host)?;
    app.bundle.write_info()?;
    for ext in app.bundle.app_extensions_mut() {
        ext.write_info()?;
    }
    stage("provision", "正在生成 iAppVM 和独立窗口描述文件…", 0.28);
    let ids = app
        .register_app_ids(&ExtensionsBehavior::RegisterAll, &mut dev, &team)
        .await?;
    let main = ids
        .iter()
        .find(|a| a.identifier == host)
        .ok_or_else(|| report!("缺少宿主 App ID"))?;
    let main_profile = dev
        .download_team_provisioning_profile(&team, main, None)
        .await?;
    let mut profiles = Vec::new();
    for id in ids.iter().filter(|a| a.identifier != host) {
        let profile = dev
            .download_team_provisioning_profile(&team, id, None)
            .await?;
        // Parsing profile entitlements is provided by the same signing library.
        let parsed =
            apple_codesign_quick::ProvisioningProfile::parse(profile.encoded_profile.as_ref())?;
        profiles.push((
            id.identifier.clone(),
            profile,
            parsed.entitlements().clone(),
        ));
    }
    stage("sign", "正在签名主程序、插件和独立窗口…", 0.42);
    sign::sign(
        &mut app,
        &identity,
        &main_profile,
        &mut profiles,
        &Some(SpecialApp::LiveContainer),
        &team,
        None::<fn(f32) -> std::future::Ready<()>>,
    )
    .await?;
    // Verify the result with the OS verifier before touching the device installation.
    let verify = std::process::Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(&staged)
        .output()?;
    if !verify.status.success() {
        bail!("签名包校验失败，尚未安装到手机");
    }
    stage("install", "正在安装 iAppVM…", 0.62);
    isideload::sideload::install::install_app(&p, &staged, |_| {})
        .await
        .context("安装失败；请检查设备解锁状态、开发者模式和可安装 App 名额")?;
    stage("configure", "正在配置手机端签名…", 0.82);
    let request_id = uuid::Uuid::new_v4().to_string();
    let export_password = Zeroizing::new(uuid::Uuid::new_v4().to_string());
    let archive = Zeroizing::new(identity.as_p12(&export_password).await?);
    let mut setup = plist::Dictionary::new();
    setup.insert("id".into(), request_id.clone().into());
    setup.insert("host".into(), host.clone().into());
    setup.insert("password".into(), export_password.to_string().into());
    setup.insert("certificate".into(), plist::Value::Data(archive.to_vec()));
    setup.insert("verifySigning".into(), true.into());
    let mut bytes = Zeroizing::new(Vec::new());
    plist::to_writer_binary(&mut *bytes, &setup)?;
    drop(setup);
    let mut afc = container(&p, &host)
        .await
        .context("无法访问刚安装的 iAppVM；请解锁手机后重试")?;
    let pending = format!("/Library/iOSVM-signing-{}.pending", request_id);
    *PENDING.lock().map_err(|_| report!("配置状态不可用"))? = Some(PendingSetup {
        udid: udid.clone(),
        host: host.clone(),
        id: request_id.clone(),
        path: pending.clone(),
    });
    let mut file = afc.open(&pending, AfcFopenMode::WrOnly).await?;
    let written = file.write_entire(&bytes).await;
    let closed = file.close().await;
    if written.is_err() || closed.is_err() {
        let _ = afc.remove(&pending).await;
        bail!("手机签名配置传输失败，请重新安装配置");
    }
    if let Err(e) = afc.rename(&pending, SETUP).await {
        let _ = afc.remove(&pending).await;
        return Err(e.into());
    }
    drop(bytes);
    drop(archive);
    drop(export_password);
    emit(
        json!({"event":"open_app","bundle":host,"message":"请在手机信任开发者，并打开或重新打开 iAppVM。完成后会自动确认。"}),
    );
    // Never treat installation success or an earlier status file as configuration success.
    let result = wait_ready(&p, &host, &request_id).await;
    result?;
    *PENDING.lock().map_err(|_| report!("配置状态不可用"))? = None;
    emit(
        json!({"event":"complete","bundle":host,"message":"iAppVM 已安装，手机签名自检通过。现在可以导入 IPA。","guestExecutionVerified":false}),
    );
    Ok(())
}
fn checked_status(v: &Value, id: &str) -> Result<bool, Report> {
    if v.get("id").and_then(Value::as_str) != Some(id) {
        return Ok(false);
    }
    match v.get("state").and_then(Value::as_str) {
        Some("ready") if v.get("signingProbe").and_then(Value::as_str) == Some("passed") => {
            Ok(true)
        }
        Some("error") => bail!(
            "{}",
            v.get("message")
                .and_then(Value::as_str)
                .unwrap_or("手机签名配置失败")
        ),
        Some("ready") => bail!("手机已保存身份，但未通过实际签名自检。请使用最新版本重新配置"),
        _ => Ok(false),
    }
}
async fn wait_ready(p: &impl IdeviceProvider, host: &str, id: &str) -> Result<(), Report> {
    for _ in 0..150 {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if let Ok(mut afc) = container(p, host).await {
            if let Ok(bytes) = read_small(&mut afc, STATUS).await {
                if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
                    if checked_status(&v, id)? {
                        return Ok(());
                    }
                }
            }
        }
    }
    bail!(
        "应用已安装，但尚未收到本次手机签名配置确认。请解锁、信任开发者并打开 iAppVM 后重试；不能将此状态视为配置成功"
    )
}
async fn run() -> Result<(), Report> {
    let mut req = receive()?;
    match req.get("command").and_then(Value::as_str).unwrap_or("") {
        "devices" => devices().await,
        "diagnose_auth" => {
            let url = req
                .get("anisette")
                .and_then(Value::as_str)
                .unwrap_or("https://ani.iloader.app");
            if !url.starts_with("https://") {
                bail!("认证辅助服务必须使用 HTTPS");
            }
            let ani = RemoteV3AnisetteProvider::new(
                url,
                Box::new(KeyringStorage::new(format!("{}.anisette", SERVICE))),
                "0".into(),
            )?;
            // No password, OTP or user account: checks only client info and Apple's service lookup.
            AppleAccount::builder("diagnostic@example.invalid")
                .anisette_provider(ani)
                .build()
                .await
                .context("登录服务连接检查失败")?;
            emit(
                json!({"event":"auth_connectivity","state":"ready","accountAuthenticationTested":false}),
            );
            Ok(())
        }
        "inspect" => {
            let i = payload_info(Path::new(field(&req, "payload")?))?;
            emit(
                json!({"event":"payload","build":i.get("CFBundleVersion").and_then(plist::Value::as_string)}),
            );
            Ok(())
        }
        "status" => {
            let p = provider(field(&req, "udid")?).await?;
            let mut afc = container(&p, field(&req, "bundle")?).await?;
            let v: Value = serde_json::from_slice(&read_small(&mut afc, STATUS).await?)?;
            emit(
                json!({"event":"device_status","state":v.get("state"),"storage":v.get("storage")}),
            );
            Ok(())
        }
        "install" => {
            let owned = req.take();
            install(owned).await
        }
        _ => bail!("不支持的操作"),
    }
}
#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    if isideload::init().is_err() {
        emit(json!({"event":"error","message":"无法初始化签名组件"}));
        std::process::exit(1);
    }
    // No tracing subscriber: upstream HTTP diagnostics can contain authentication material.
    let mut stop = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("signal handler");
    let result = tokio::select! {
        result=tokio::time::timeout(Duration::from_secs(900),run())=>match result {Ok(r)=>r,Err(_)=>Err(report!("操作超时，请检查网络和设备连接后重试"))},
        _=stop.recv()=>Err(report!("操作已停止"))
    };
    cleanup_pending().await;
    if let Err(e) = result {
        emit(json!({"event":"error","message":public_error(&e)}));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_errors_keep_codes_without_attachments_or_server_echo() {
        let error = report!(isideload::SideloadError::AuthWithMessage(
            -80045,
            "server-echo-secret".into()
        ))
        .attach("session-token-secret")
        .context("Apple 账号登录失败");
        let text = public_error(&error.into_dynamic());
        assert!(text.contains("-80045"));
        assert!(text.contains("Apple 账号登录失败"));
        assert!(!text.contains("server-echo-secret"));
        assert!(!text.contains("session-token-secret"));
        let network = report!("Failed to parse URL Bag plist")
            .attach("account-data-secret")
            .context("无法初始化 Apple 登录服务");
        let text = public_error(&network.into_dynamic());
        assert!(text.contains("Apple 登录服务返回内容无法解析"));
        assert!(!text.contains("account-data-secret"));
    }
    #[test]
    fn bundle_id_is_stable_per_team() {
        assert_eq!(
            host_identifier("J2LCHHNG4H").unwrap(),
            "com.iappvm.container.J2LCHHNG4H"
        );
        assert!(host_identifier("../evil").is_err());
    }
    #[test]
    fn status_requires_this_request_and_real_signing_probe() {
        assert!(
            !checked_status(
                &json!({"id":"old","state":"ready","signingProbe":"passed"}),
                "new"
            )
            .unwrap()
        );
        assert!(
            checked_status(
                &json!({"id":"new","state":"ready","signingProbe":"passed"}),
                "new"
            )
            .unwrap()
        );
        assert!(checked_status(&json!({"id":"new","state":"ready"}), "new").is_err());
        assert!(
            checked_status(
                &json!({"id":"new","state":"error","message":"fixture failure"}),
                "new"
            )
            .is_err()
        );
        assert!(!checked_status(&json!({"id":"new","state":"working"}), "new").unwrap());
    }
    #[test]
    fn rejects_non_payload() {
        let t = tempfile::tempdir().unwrap();
        let mut i = plist::Dictionary::new();
        i.insert("CFBundleExecutable".into(), "../file".into());
        plist::to_file_xml(t.path().join("Info.plist"), &i).unwrap();
        assert!(payload_info(t.path()).is_err());
    }
}

#[cfg(test)]
mod offline_test;
