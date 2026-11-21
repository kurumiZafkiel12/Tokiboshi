//! sing-box core acquisition: detect the bundled/managed binary and
//! download the pinned stable release from GitHub when missing.
//!
//! The managed binary lives at `<data_dir>/core/sing-box[.exe]`,
//! separate from any system install, so updates never touch the
//! user's own files.

use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use crate::process::CoreProcess;

/// Diagnostic lines from background work with no dedicated UI
/// (rule-set downloads). Surfaced through `core_logs` so the Logs
/// page shows why 分流/拦截 rules are missing (HF053-02).
static EXTRA_LOGS: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());

fn push_extra_log(line: String) {
    if let Ok(mut slot) = EXTRA_LOGS.lock() {
        if slot.len() >= 200 {
            slot.pop_front();
        }
        slot.push_back(line);
    }
}

/// Publish a diagnostic line into the shared log buffer (used by
/// callers outside this module, e.g. post-maintenance hints).
pub fn log_extra(line: String) {
    push_extra_log(line);
}

pub fn extra_logs() -> Vec<String> {
    match EXTRA_LOGS.lock() {
        Ok(slot) => slot.iter().cloned().collect(),
        Err(_) => Vec::new(),
    }
}

/// Pinned sing-box stable (latest stable at build time).
pub const CORE_VERSION: &str = "1.14.4";

/// Official sha-256 of the pinned release archives, per platform,
/// taken from the GitHub release API at pin time (same source the
/// packaging CI verifies against). The runtime download is checked
/// here before anything is extracted; an asset without a pinned
/// digest is refused rather than installed unchecked.
pub const OFFICIAL_DIGESTS: &[(&str, &str)] = &[
    (
        "sing-box-1.14.4-windows-amd64.zip",
        "99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df",
    ),
    (
        "sing-box-1.14.4-windows-arm64.zip",
        "8cd0a4d0cd8cd480be5731ac31f17038969a42d12add9feb6e031fd43d85bbae",
    ),
    (
        "sing-box-1.14.4-linux-amd64.tar.gz",
        "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968",
    ),
    (
        "sing-box-1.14.4-linux-arm64.tar.gz",
        "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26",
    ),
    (
        "sing-box-1.14.4-darwin-amd64.tar.gz",
        "eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25",
    ),
    (
        "sing-box-1.14.4-darwin-arm64.tar.gz",
        "0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838",
    ),
];

pub fn binary_name() -> &'static str {
    if cfg!(windows) {
        "sing-box.exe"
    } else {
        "sing-box"
    }
}

pub fn core_binary_path(data_dir: &Path) -> PathBuf {
    data_dir.join("core").join(binary_name())
}

fn asset_name() -> Result<String, String> {
    let (os, arch, ext) = asset_os_arch()?;
    Ok(format!("sing-box-{CORE_VERSION}-{os}-{arch}.{ext}"))
}

fn expected_digest(asset: &str) -> Option<&'static str> {
    OFFICIAL_DIGESTS
        .iter()
        .find(|(name, _)| *name == asset)
        .map(|(_, digest)| *digest)
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn verify_digest(bytes: &[u8], expected: &str) -> Result<(), String> {
    let actual = sha256_hex(bytes);
    if actual != expected.to_lowercase() {
        return Err(format!(
            "sing-box download checksum mismatch: expected {expected}, got {actual}"
        ));
    }
    Ok(())
}

fn asset_os_arch() -> Result<(&'static str, &'static str, &'static str), String> {
    let os = match std::env::consts::OS {
        "windows" => "windows",
        "linux" => "linux",
        "macos" => "darwin",
        other => return Err(format!("unsupported OS for core download: {other}")),
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => return Err(format!("unsupported arch for core download: {other}")),
    };
    let ext = if os == "windows" { "zip" } else { "tar.gz" };
    Ok((os, arch, ext))
}

pub fn asset_url() -> Result<String, String> {
    let asset = asset_name()?;
    Ok(format!(
        "https://github.com/SagerNet/sing-box/releases/download/v{v}/{asset}",
        v = CORE_VERSION
    ))
}

/// Version of the managed binary, when present and runnable.
pub fn installed_version(data_dir: &Path) -> Option<String> {
    let path = core_binary_path(data_dir);
    if !path.exists() {
        return None;
    }
    CoreProcess::new(path).version().ok()
}

pub fn is_up_to_date(data_dir: &Path) -> bool {
    installed_version(data_dir)
        .map(|v| v.contains(CORE_VERSION))
        .unwrap_or(false)
}

/// Download the pinned release and install the binary (plus the
/// optional libcronet companion on Windows). Returns the version
/// string reported by the installed binary.
pub fn download_and_install(data_dir: &Path) -> Result<String, String> {
    let url = asset_url()?;
    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(300))
        .build();
    let response = agent
        .get(&url)
        .call()
        .map_err(|e| format!("core download failed: {e}"))?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(200 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("core download read failed: {e}"))?;
    if bytes.len() < 1_000_000 {
        return Err(format!(
            "core download too small ({} bytes), likely an error page",
            bytes.len()
        ));
    }
    // Supply-chain gate: refuse to install anything that does not
    // match the official digest pinned for this platform.
    let asset = asset_name()?;
    let expected = expected_digest(&asset).ok_or_else(|| {
        format!("no official sha-256 pinned for {asset}; refusing unverified core")
    })?;
    verify_digest(&bytes, expected)?;

    let core_dir = data_dir.join("core");
    std::fs::create_dir_all(&core_dir)
        .map_err(|e| format!("cannot create core dir: {e}"))?;
    let dest = core_binary_path(data_dir);

    if url.ends_with(".zip") {
        extract_from_zip(&bytes, &core_dir)?;
    } else {
        extract_from_tar_gz(&bytes, &core_dir)?;
    }
    if !dest.exists() {
        return Err("sing-box binary not found inside the release archive".to_string());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("cannot chmod sing-box: {e}"))?;
    }
    CoreProcess::new(dest.clone()).version()
}

fn wanted_file(name: &str) -> bool {
    let base = name.rsplit('/').next().unwrap_or(name);
    base == "sing-box"
        || base == "sing-box.exe"
        || base == "libcronet.dll"
        || base == "libcronet.so"
        || base == "wintun.dll"
}

fn extract_from_zip(bytes: &[u8], core_dir: &Path) -> Result<(), String> {
    let reader = std::io::Cursor::new(bytes);
    let mut archive =
        zip::ZipArchive::new(reader).map_err(|e| format!("bad zip archive: {e}"))?;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("bad zip entry: {e}"))?;
        let name = entry.name().to_string();
        if entry.is_dir() || !wanted_file(&name) {
            continue;
        }
        let base = name.rsplit('/').next().unwrap_or(&name).to_string();
        let mut out = Vec::new();
        entry
            .read_to_end(&mut out)
            .map_err(|e| format!("zip entry read failed: {e}"))?;
        std::fs::write(core_dir.join(base), out)
            .map_err(|e| format!("cannot write core file: {e}"))?;
    }
    Ok(())
}

fn extract_from_tar_gz(bytes: &[u8], core_dir: &Path) -> Result<(), String> {
    let gz = flate2::read::GzDecoder::new(std::io::Cursor::new(bytes));
    let mut archive = tar::Archive::new(gz);
    let entries = archive
        .entries()
        .map_err(|e| format!("bad tar archive: {e}"))?;
    for entry in entries {
        let mut entry = entry.map_err(|e| format!("bad tar entry: {e}"))?;
        let path = entry.path().map_err(|e| format!("bad tar path: {e}"))?;
        let name = path.to_string_lossy().to_string();
        if !wanted_file(&name) {
            continue;
        }
        let base = name.rsplit('/').next().unwrap_or(&name).to_string();
        let mut out = Vec::new();
        entry
            .read_to_end(&mut out)
            .map_err(|e| format!("tar entry read failed: {e}"))?;
        std::fs::write(core_dir.join(base), out)
            .map_err(|e| format!("cannot write core file: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_url_is_pinned_and_platform_shaped() {
        let url = asset_url().unwrap();
        assert!(url.contains(CORE_VERSION), "{url}");
        assert!(url.starts_with("https://github.com/SagerNet/sing-box/releases/download/"));
    }

    #[test]
    fn digest_verification_rejects_swapped_archive() {
        assert!(verify_digest(b"not-the-core", OFFICIAL_DIGESTS[0].1).is_err());
        // Known SHA-256 of "abc" — the helper must hash deterministically.
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn every_supported_platform_has_a_pinned_digest() {
        // The download path fails closed when the platform's asset has
        // no digest; keep the platforms we build/ship covered.
        for asset in ["sing-box-1.14.4-windows-amd64.zip", "sing-box-1.14.4-linux-amd64.tar.gz"] {
            assert!(expected_digest(asset).is_some(), "{asset} missing digest");
        }
    }

    #[test]
    fn zashboard_download_is_version_pinned_with_digest() {
        assert!(
            crate::config::ZASHBOARD_DOWNLOAD_URL.contains("/releases/download/v"),
            "{}",
            crate::config::ZASHBOARD_DOWNLOAD_URL
        );
        assert!(!crate::config::ZASHBOARD_DOWNLOAD_URL.contains("/latest/"));
        assert_eq!(crate::config::ZASHBOARD_SHA256.len(), 64);
    }

    #[test]
    fn binary_path_lives_under_core_dir() {
        let p = core_binary_path(Path::new("/data"));
        assert!(p.ends_with(binary_name()));
        assert!(p.to_string_lossy().contains("core"));
    }

    #[test]
    fn missing_binary_reports_no_version() {
        let dir = std::env::temp_dir().join("tokiboshi-no-core-here");
        assert_eq!(installed_version(&dir), None);
        assert!(!is_up_to_date(&dir));
    }

    #[test]
    fn extracts_binary_from_zip_bytes() {
        // Build a tiny zip shaped like the real release archive.
        let mut buf = Vec::new();
        {
            let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts = zip::write::SimpleFileOptions::default();
            zw.start_file(format!("sing-box-{CORE_VERSION}-windows-amd64/sing-box.exe"), opts)
                .unwrap();
            use std::io::Write;
            zw.write_all(b"fake-binary").unwrap();
            zw.start_file("sing-box-1.14.4-windows-amd64/readme.txt", opts).unwrap();
            zw.write_all(b"ignore me").unwrap();
            zw.finish().unwrap();
        }
        let dir = std::env::temp_dir()
            .join(format!("tokiboshi-zip-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        extract_from_zip(&buf, &dir).unwrap();
        assert_eq!(
            std::fs::read(dir.join("sing-box.exe")).unwrap(),
            b"fake-binary"
        );
        assert!(!dir.join("readme.txt").exists());
        std::fs::remove_dir_all(&dir).ok();
    }
}

/// Rule-set files the generated config references as LOCAL files
/// (tag, download URL). sing-box used to fetch these itself during
/// startup through the selected node; a slow node then killed the
/// core before it listened. The app now keeps them on disk instead.
#[derive(serde::Deserialize)]
struct RuleResource {
    tag: String,
    group: String,
    url: String,
}

fn rule_resources() -> Vec<RuleResource> {
    serde_json::from_str(include_str!("../../assets/rule-resources.json"))
        .expect("built-in rule catalog")
}

// The bootstrap and explicit refresh share the same commit path.
static RULE_WRITE: Mutex<()> = Mutex::new(());

pub fn refresh_rule_resource(
    data_dir: &Path, tag: &str, url: &str, binary: Option<&Path>,
    only_missing: bool,
) -> Result<bool, String> {
    let resource = rule_resources().into_iter().find(|r| r.tag == tag)
        .ok_or_else(|| "未知规则集".to_string())?;
    let url = if url.trim().is_empty() { &resource.url } else { url.trim() };
    let mut url = url::Url::parse(url).map_err(|_| "规则集地址无效")?;
    validate_rule_url(&url)?;
    {
        let _guard = RULE_WRITE.lock().map_err(|_| "规则集写入锁异常")?;
        if only_missing && data_dir.join("rules").join(format!("{tag}.srs")).is_file() {
            return Ok(false);
        }
    }
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(std::time::Duration::from_secs(20)).build();
    let mut redirects = 0;
    let response = loop {
        let response = agent.get(url.as_str()).call().map_err(|_| "规则集下载失败")?;
        if response.status() == 200 { break response; }
        if !matches!(response.status(), 301 | 302 | 303 | 307 | 308) || redirects >= 4 {
            return Err("规则集源没有返回可用文件".into());
        }
        let next = response.header("Location").ok_or("规则集重定向不含地址")?;
        url = url.join(next).map_err(|_| "规则集重定向地址无效")?;
        validate_rule_url(&url)?;
        redirects += 1;
    };
    const MAX: usize = 16 * 1024 * 1024;
    let mut bytes = Vec::new();
    response.into_reader().take(MAX as u64 + 1)
        .read_to_end(&mut bytes).map_err(|_| "无法完整读取规则集")?;
    commit_rule_resource(data_dir, tag, &bytes, binary, only_missing)
}

fn validate_rule_url(url: &url::Url) -> Result<(), String> {
    if url.scheme() != "https" || !url.has_host() || !url.username().is_empty()
        || url.password().is_some() || url.fragment().is_some() {
        return Err("规则集地址必须使用 HTTPS，不能含账号或片段".into());
    }
    Ok(())
}

fn commit_rule_resource(
    data_dir: &Path, tag: &str, bytes: &[u8], binary: Option<&Path>, only_missing: bool,
) -> Result<bool, String> {
    if bytes.len() < 8 || bytes.len() > 16 * 1024 * 1024 || !bytes.starts_with(b"SRS") {
        return Err("无效或过大的 .srs 文件".into());
    }
    let _guard = RULE_WRITE.lock().map_err(|_| "规则集写入锁异常")?;
    let dir = data_dir.join("rules");
    std::fs::create_dir_all(&dir).map_err(|_| "无法创建规则集目录")?;
    let dest = dir.join(format!("{tag}.srs"));
    if only_missing && dest.is_file() { return Ok(false); }
    let tmp = dir.join(format!("{tag}.srs.tmp"));
    let decoded = dir.join(format!("{tag}.verify.tmp"));
    let result = (|| {
        use std::io::Write;
        let mut file = std::fs::File::create(&tmp).map_err(|_| "无法创建规则集临时文件")?;
        file.write_all(bytes).and_then(|_| file.sync_all())
            .map_err(|_| "无法完整写入规则集")?;
        drop(file);
        if let Some(binary) = binary {
            let mut command = std::process::Command::new(binary);
            command.args(["rule-set", "decompile"]).arg(&tmp).arg("-o").arg(&decoded)
                .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x08000000);
            }
            let mut child = command.spawn().map_err(|_| "无法验证规则集：内核不可用")?;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
            loop {
                match child.try_wait() {
                    Ok(Some(status)) if status.success() => break,
                    Ok(Some(_)) => return Err("内核拒绝了规则集内容"),
                    Ok(None) if std::time::Instant::now() < deadline =>
                        std::thread::sleep(std::time::Duration::from_millis(25)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err("规则集验证超时或进程异常");
                    }
                }
            }
        }
        std::fs::rename(&tmp, &dest).map_err(|_| "规则集提交失败，原文件保留")?;
        Ok(true)
    })();
    let _ = std::fs::remove_file(&tmp);
    let _ = std::fs::remove_file(&decoded);
    result.map_err(str::to_owned)
}

#[cfg(test)]
mod rule_resource_tests {
    use super::*;

    #[test]
    fn invalid_or_rejected_srs_never_replaces_existing_file() {
        let directory = std::env::temp_dir().join(format!("tokiboshi-rules-{}", std::process::id()));
        let rules = directory.join("rules");
        std::fs::create_dir_all(&rules).unwrap();
        let asset = rules.join("geosite-cn.srs");
        std::fs::write(&asset, b"previous").unwrap();
        assert!(commit_rule_resource(&directory, "geosite-cn", b"invalid", None, false).is_err());
        if let Some(core) = std::env::var_os("SING_BOX") {
            assert!(commit_rule_resource(&directory, "geosite-cn", b"SRS-invalid-fixture",
                Some(Path::new(&core)), false).is_err());
        }
        assert_eq!(std::fs::read(&asset).unwrap(), b"previous");
        assert!(!rules.join("geosite-cn.srs.tmp").exists());
        assert!(!rules.join("geosite-cn.verify.tmp").exists());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn configured_and_redirected_sources_require_https() {
        for invalid in ["http://example.test/file", "https://user:secret@example.test",
            "https://example.test/#fragment"] {
            assert!(validate_rule_url(&url::Url::parse(invalid).unwrap()).is_err());
        }
        assert!(validate_rule_url(&url::Url::parse("https://example.test/rules.srs").unwrap()).is_ok());
    }
}

/// Outcome of a rule-set maintenance round, so callers can report
/// accurately instead of claiming readiness (HF053-02).
#[derive(Debug, Clone, Copy)]
pub struct RuleSetSummary {
    pub ready: usize,
    pub total: usize,
    /// Files downloaded (or refreshed) during this round.
    pub updated: usize,
    pub dir_ok: bool,
    /// Download failed or content invalid — no usable old file.
    pub missing: usize,
    /// Download succeeded but the commit (rename) was rejected — the
    /// previous valid file is kept. Distinct from [missing] in the
    /// summary wording (CV005-01).
    pub commit_failed: usize,
}

pub fn ensure_rule_sets(data_dir: &Path, urls: &std::collections::HashMap<String, String>) -> RuleSetSummary {
    let dir = data_dir.join("rules");
    let dir_ok = std::fs::create_dir_all(&dir).is_ok();
    let mut result = RuleSetSummary { ready: 0, total: 0, updated: 0, dir_ok,
        missing: 0, commit_failed: 0 };
    for item in rule_resources().into_iter().filter(|r| r.group == "核心") {
        result.total += 1;
        let path = dir.join(format!("{}.srs", item.tag));
        if !path.is_file() && dir_ok {
            let url = urls.get(&item.tag).map(String::as_str).unwrap_or_default();
            match refresh_rule_resource(data_dir, &item.tag, url, None, true) {
                Ok(true) => {
                    result.updated += 1;
                    push_extra_log(format!("[rules] {} 已下载", item.tag));
                }
                Ok(false) => {}
                Err(error) => {
                    if error.contains("提交失败") { result.commit_failed += 1; }
                    push_extra_log(format!("[rules] {} {error}", item.tag));
                }
            }
        }
        if path.is_file() { result.ready += 1; } else { result.missing += 1; }
    }
    push_extra_log(format!("[rules] 规则集 {}/{} 就绪；{} 缺失，{} 提交失败",
        result.ready, result.total, result.missing, result.commit_failed));
    result
}

/// Never let sing-box download its dashboard synchronously before binding the
/// control port. Serve a local waiting page and populate the UI independently.
pub fn prepare_dashboard(dir: &Path) -> Result<(), String> {
    const WAITING: &str = "<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=10><title>Tokiboshi</title><p>面板正在准备，请稍候。代理连接不受影响；下载完成后此页自动刷新。</p><!-- tokiboshi-dashboard-pending -->";
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create panel directory: {e}"))?;
    let index = dir.join("index.html");
    if index.exists() && !std::fs::read_to_string(&index).unwrap_or_default().contains("tokiboshi-dashboard-pending") {
        return Ok(());
    }
    std::fs::write(&index, WAITING).map_err(|e| format!("cannot prepare local panel: {e}"))?;
    static DOWNLOADING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if DOWNLOADING.swap(true, std::sync::atomic::Ordering::SeqCst) { return Ok(()); }
    let dir = dir.to_path_buf();
    std::thread::spawn(move || {
        let result = (|| -> Result<(), String> {
            let agent = ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(45)).build();
            let response = agent.get(crate::config::ZASHBOARD_DOWNLOAD_URL).call().map_err(|e| e.to_string())?;
            let mut bytes = Vec::new();
            response.into_reader().take(32 * 1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
            if bytes.len() > 32 * 1024 * 1024 { return Err("dashboard archive too large".into()); }
            let actual = sha256_hex(&bytes);
            if actual != crate::config::ZASHBOARD_SHA256 {
                return Err(format!(
                    "dashboard archive checksum mismatch: expected {}, got {actual}",
                    crate::config::ZASHBOARD_SHA256
                ));
            }
            let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|e| e.to_string())?;
            let mut index_bytes = None;
            let mut total = 0u64;
            for i in 0..zip.len() {
                let entry = zip.by_index(i).map_err(|e| e.to_string())?;
                if entry.is_dir() { continue; }
                let path = entry.enclosed_name().ok_or("unsafe dashboard path")?;
                // Official gh-pages archives have one containing directory.
                let relative: PathBuf = path.components().skip(1).collect();
                if relative.as_os_str().is_empty() { continue; }
                total = total.saturating_add(entry.size());
                if total > 128 * 1024 * 1024 { return Err("expanded dashboard too large".into()); }
                let mut content = Vec::new();
                entry.take(128 * 1024 * 1024 + 1).read_to_end(&mut content).map_err(|e| e.to_string())?;
                if relative == Path::new("index.html") { index_bytes = Some(content); continue; }
                let dest = dir.join(relative);
                if let Some(parent) = dest.parent() { std::fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
                std::fs::write(dest, content).map_err(|e| e.to_string())?;
            }
            // Publish the real entry point only after every referenced asset.
            std::fs::write(dir.join("index.html"), index_bytes.ok_or("dashboard has no index")?).map_err(|e| e.to_string())
        })();
        if result.is_err() {
            let _ = std::fs::write(dir.join("index.html"), "<!doctype html><meta charset=utf-8><title>Tokiboshi</title><p>面板下载失败，代理连接不受影响。请检查网络后重新启动内核以重试。</p><!-- tokiboshi-dashboard-pending -->");
        }
        DOWNLOADING.store(false, std::sync::atomic::Ordering::SeqCst);
    });
    Ok(())
}
