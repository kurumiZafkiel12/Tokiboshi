//! sing-box core process lifecycle.
//!
//! Owns at most one sing-box child process. `start` optionally asks the
//! real binary to `check` the config first, then spawns
//! `sing-box run -c <config>`. All state transitions are explicit so the
//! Flutter UI can render them truthfully.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreState {
    Stopped,
    Running,
}

#[derive(Debug)]
pub struct CoreProcess {
    binary: PathBuf,
    child: Option<Child>,
}

impl CoreProcess {
    pub fn new(binary: impl Into<PathBuf>) -> Self {
        Self { binary: binary.into(), child: None }
    }

    pub fn state(&mut self) -> CoreState {
        match self.child.as_mut() {
            None => CoreState::Stopped,
            Some(child) => match child.try_wait() {
                Ok(Some(_)) => {
                    self.child = None;
                    CoreState::Stopped
                }
                Ok(None) => CoreState::Running,
                Err(_) => {
                    self.child = None;
                    CoreState::Stopped
                }
            },
        }
    }

    /// Run `sing-box check -c <config>`; Ok(()) only when the binary
    /// accepts the configuration.
    pub fn check_config(&self, config_path: &Path) -> Result<(), String> {
        let output = Command::new(&self.binary)
            .arg("check")
            .arg("-c")
            .arg(config_path)
            .output()
            .map_err(|e| format!("cannot run sing-box check: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(format!(
                "sing-box check failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ))
        }
    }

    pub fn start(&mut self, config_path: &Path) -> Result<(), String> {
        if self.state() == CoreState::Running {
            return Err("sing-box is already running".to_string());
        }
        if !config_path.exists() {
            return Err(format!("config not found: {}", config_path.display()));
        }
        let child = Command::new(&self.binary)
            .arg("run")
            .arg("-c")
            .arg(config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("cannot start sing-box: {e}"))?;
        self.child = Some(child);
        Ok(())
    }

    pub fn stop(&mut self) -> Result<(), String> {
        match self.child.take() {
            None => Ok(()),
            Some(mut child) => {
                let _ = child.kill();
                child.wait().map_err(|e| format!("cannot wait for sing-box exit: {e}"))?;
                Ok(())
            }
        }
    }
}

impl Drop for CoreProcess {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A stand-in "sing-box" shell script: `check` succeeds, `run` sleeps.
    fn fake_binary(dir: &Path) -> PathBuf {
        let path = dir.join("fake-sing-box");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "#!/bin/sh").unwrap();
        writeln!(f, "if [ \"$1\" = \"check\" ]; then exit 0; fi").unwrap();
        writeln!(f, "if [ \"$1\" = \"run\" ]; then sleep 30; fi").unwrap();
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    #[test]
    fn lifecycle_with_fake_binary() {
        let dir = std::env::temp_dir().join(format!("tokiboshi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.json");
        std::fs::write(&config, "{}").unwrap();

        let mut core = CoreProcess::new(fake_binary(&dir));
        assert_eq!(core.state(), CoreState::Stopped);
        assert!(core.check_config(&config).is_ok());
        core.start(&config).unwrap();
        assert_eq!(core.state(), CoreState::Running);
        assert!(core.start(&config).is_err(), "double start must fail");
        core.stop().unwrap();
        assert_eq!(core.state(), CoreState::Stopped);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn start_rejects_missing_config() {
        let mut core = CoreProcess::new("/bin/true");
        let missing = Path::new("/nonexistent/tokiboshi-config.json");
        assert!(core.start(missing).is_err());
    }
}
