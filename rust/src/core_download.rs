//! sing-box core acquisition: detect the bundled/managed binary and
//! download the pinned stable release from GitHub when missing.
//!
//! The managed binary lives at `<data_dir>/core/sing-box[.exe]`,
//! separate from any system install, so updates never touch the
//! user's own files.

use std::io::Read;
use std::path::{Path, PathBuf};

use crate::process::CoreProcess;

/// Pinned sing-box stable (latest stable at build time).
pub const CORE_VERSION: &str = "1.14.4";

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
    let (os, arch, ext) = asset_os_arch()?;
    Ok(format!(
        "https://github.com/SagerNet/sing-box/releases/download/v{v}/sing-box-{v}-{os}-{arch}.{ext}",
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
    base == "sing-box" || base == "sing-box.exe" || base == "libcronet.dll" || base == "libcronet.so"
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
