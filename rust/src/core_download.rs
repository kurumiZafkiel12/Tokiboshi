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
pub const RULE_SET_FILES: [(&str, &str); 3] = [
    (
        "geosite-category-ads-all",
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
    ),
    (
        "geosite-cn",
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
    ),
    (
        "geoip-cn",
        "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
    ),
];

/// Best-effort: download any missing or stale (>24h) rule-set files
/// into `<data_dir>/rules/`. Failures are ignored on purpose — the
/// config generator drops rules whose files are absent, and the
/// core must never depend on these downloads to start.
/// Outcome of a rule-set maintenance round, so callers can report
/// accurately instead of claiming readiness (HF053-02).
#[derive(Debug, Clone, Copy)]
pub struct RuleSetSummary {
    pub ready: usize,
    pub total: usize,
    /// Files downloaded (or refreshed) during this round.
    pub updated: usize,
    pub dir_ok: bool,
}

pub fn ensure_rule_sets(data_dir: &Path) -> RuleSetSummary {
    let dir = data_dir.join("rules");
    if std::fs::create_dir_all(&dir).is_err() {
        push_extra_log("[rules] 无法创建规则目录，分流/拦截规则不可用".into());
        return RuleSetSummary { ready: 0, total: RULE_SET_FILES.len(), updated: 0, dir_ok: false };
    }
    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(60))
        .build();
    let mut ready = 0usize;
    let mut updated = 0usize;
    for (tag, url) in RULE_SET_FILES {
        let dest = dir.join(format!("{tag}.srs"));
        let fresh = std::fs::metadata(&dest)
            .and_then(|m| m.modified())
            .map(|t| t.elapsed().map(|e| e.as_secs() < 24 * 3600).unwrap_or(false))
            .unwrap_or(false);
        if fresh {
            ready += 1;
            continue;
        }
        push_extra_log(format!("[rules] 下载 {tag} …"));
        let Ok(response) = agent.get(url).call() else {
            push_extra_log(format!(
                "[rules] {tag} 下载失败（直连 GitHub；缺失时对应分流规则不会生效）"
            ));
            continue;
        };
        let mut bytes = Vec::new();
        use std::io::Read;
        if response
            .into_reader()
            .take(64 * 1024 * 1024)
            .read_to_end(&mut bytes)
            .is_err()
            || bytes.len() < 16
        {
            push_extra_log(format!("[rules] {tag} 下载内容无效"));
            continue;
        }
        let tmp = dir.join(format!("{tag}.srs.tmp"));
        // Full commit chain: write the downloaded bytes to tmp, THEN
        // rename onto the real file (HV004-01: the write step was
        // accidentally dropped in the previous fix, renaming a
        // non-existent tmp and failing every rule).
        if let Err(e) = std::fs::write(&tmp, &bytes) {
            push_extra_log(format!("[rules] {tag} 临时文件写入失败：{e}"));
            continue;
        }
        // The rename can fail when the target file is held/locked.
        // Only a committed file counts as ready — the previous valid
        // file is kept and the failure is reported (HF053-02).
        match std::fs::rename(&tmp, &dest) {
            Ok(()) => {
                ready += 1;
                updated += 1;
                push_extra_log(format!("[rules] {tag} 已更新"));
            }
            Err(e) => {
                push_extra_log(format!(
                    "[rules] {tag} 提交失败：{e}；保留现有有效文件"
                ));
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }
    let total = RULE_SET_FILES.len();
    if ready == total {
        push_extra_log(format!("[rules] 规则集 {ready}/{total} 就绪"));
    } else {
        push_extra_log(format!(
            "[rules] 规则集 {ready}/{total} 可用（{} 个缺失，对应分流规则不生效）",
            total - ready
        ));
    }
    RuleSetSummary { ready, total, updated, dir_ok: true }
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
