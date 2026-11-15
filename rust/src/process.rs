//! sing-box core process lifecycle, with supervision.
//!
//! Owns at most one sing-box child process. `start` optionally asks
//! the real binary to `check` the config first, then spawns
//! `sing-box run -c <config>` with stdout/stderr captured into a
//! bounded log buffer. A monitor thread watches the child: an
//! unexpected exit is restarted (up to `MAX_RESTARTS` times), a
//! requested stop is not.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const MAX_RESTARTS: u32 = 3;
const LOG_CAP: usize = 500;
const MONITOR_TICK: Duration = Duration::from_millis(700);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreState {
    Stopped,
    Running,
}

#[derive(Debug, Default)]
struct Shared {
    child: Mutex<Option<Child>>,
    /// Windows Job Object handle (isize HANDLE). The job has
    /// KILL_ON_JOB_CLOSE, so the core can never outlive this process:
    /// if the GUI crashes or is killed, the OS closes the handle and
    /// the kernel dies with it instead of orphan-holding port 7890.
    #[cfg(windows)]
    job: Mutex<Option<isize>>,
    logs: Mutex<VecDeque<String>>,
    stop_requested: AtomicBool,
    restart_count: AtomicU32,
    last_exit: Mutex<Option<String>>,
}

/// Minimal kernel32 Job Object FFI. Declared locally instead of via
/// a crate so the ABI-critical definitions live in this file and no
/// external dependency version can move them under us.
#[cfg(windows)]
mod job {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;

    pub type JobHandle = isize;
    type Raw = *mut core::ffi::c_void;

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attrs: *const core::ffi::c_void, name: *const u16) -> Raw;
        fn SetInformationJobObject(job: Raw, class: u32, info: *const core::ffi::c_void, len: u32) -> i32;
        fn AssignProcessToJobObject(job: Raw, process: Raw) -> i32;
        fn CloseHandle(handle: Raw) -> i32;
    }

    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: u32 = 9;

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct BasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        ui_restrictions_class: u32,
        io_priority: u32,
    }

    #[repr(C)]
    struct ExtendedLimitInformation {
        basic: BasicLimitInformation,
        io: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    /// Create a kill-on-close job and move `child` into it. The job
    /// has exactly one handle (ours); when this process dies or we
    /// close the handle, every process inside the job is terminated.
    pub fn assign(child: &Child) -> Result<JobHandle, String> {
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err("CreateJobObjectW failed".to_string());
            }
            let info = ExtendedLimitInformation {
                basic: BasicLimitInformation {
                    limit_flags: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
                    ..Default::default()
                },
                io: IoCounters::default(),
                process_memory_limit: 0,
                job_memory_limit: 0,
                peak_process_memory_used: 0,
                peak_job_memory_used: 0,
            };
            if SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<ExtendedLimitInformation>() as u32,
            ) == 0
            {
                CloseHandle(job);
                return Err("SetInformationJobObject failed".to_string());
            }
            if AssignProcessToJobObject(job, child.as_raw_handle() as Raw) == 0 {
                CloseHandle(job);
                return Err("AssignProcessToJobObject failed".to_string());
            }
            Ok(job as JobHandle)
        }
    }

    /// Close the job handle; with KILL_ON_JOB_CLOSE this terminates
    /// any process still inside the job.
    pub fn close(handle: JobHandle) {
        unsafe {
            CloseHandle(handle as Raw);
        }
    }
}

/// Close the current Job Object handle. With KILL_ON_JOB_CLOSE this
/// kills any process still inside the job; callers either already
/// waited for the child or the child exited on its own.
#[cfg(windows)]
fn job_close(shared: &Shared) {
    if let Ok(mut slot) = shared.job.lock() {
        if let Some(handle) = slot.take() {
            job::close(handle);
        }
    }
}

#[cfg(not(windows))]
fn job_close(_shared: &Shared) {}

fn plain_log(line: &str) -> String {
    let mut chars = line.chars().peekable();
    let mut out = String::new();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for code in chars.by_ref() { if ('@'..='~').contains(&code) { break; } }
        } else { out.push(c); }
    }
    out
}

fn push_log(shared: &Shared, line: String) {
    let line = plain_log(&line);
    if let Ok(mut logs) = shared.logs.lock() {
        if logs.len() >= LOG_CAP {
            logs.pop_front();
        }
        logs.push_back(line);
    }
}

/// Build a command for the core binary. On Windows the GUI has no
/// console of its own, so a console-subsystem child would pop up a
/// visible black console window (hosted by Windows Terminal) that
/// stays on screen for the core's whole lifetime — CREATE_NO_WINDOW
/// keeps it fully hidden. Its stdout/stderr are piped and captured
/// either way.
fn core_command(binary: &Path) -> Command {
    // `mut` is only exercised by the Windows branch below.
    #[allow(unused_mut)]
    let mut cmd = Command::new(binary);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

fn spawn_child(
    binary: &Path,
    config_path: &Path,
    shared: &Arc<Shared>,
) -> Result<Child, String> {
    let mut child = core_command(binary)
        .arg("run")
        .arg("-c")
        .arg(config_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start sing-box: {e}"))?;
    #[cfg(windows)]
    {
        // A previous handle can only still exist here on the restart
        // path, where the old child already exited — closing it is
        // safe and cannot kill anything.
        if let Ok(mut slot) = shared.job.lock() {
            if let Some(old) = slot.take() {
                job::close(old);
            }
        }
        match job::assign(&child) {
            Ok(handle) => {
                if let Ok(mut slot) = shared.job.lock() {
                    *slot = Some(handle);
                }
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        }
    }
    for stream in [
        child.stdout.take().map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
        child.stderr.take().map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
    ] {
        if let Some(stream) = stream {
            let shared = Arc::clone(shared);
            std::thread::spawn(move || {
                let reader = BufReader::new(stream);
                for line in reader.lines() {
                    match line {
                        // Never log full config or subscription
                        // content; sing-box's own log lines are
                        // operational output and safe to keep.
                        Ok(l) => push_log(&shared, l),
                        Err(_) => break,
                    }
                }
            });
        }
    }
    Ok(child)
}

#[derive(Debug)]
pub struct CoreProcess {
    binary: PathBuf,
    shared: Arc<Shared>,
}

impl CoreProcess {
    pub fn new(binary: impl Into<PathBuf>) -> Self {
        Self {
            binary: binary.into(),
            shared: Arc::new(Shared::default()),
        }
    }

    pub fn state(&self) -> CoreState {
        let mut slot = match self.shared.child.lock() {
            Ok(s) => s,
            Err(_) => return CoreState::Stopped,
        };
        match slot.as_mut() {
            None => CoreState::Stopped,
            Some(child) => match child.try_wait() {
                Ok(None) => CoreState::Running,
                _ => CoreState::Stopped
            },
        }
    }

    pub fn restart_count(&self) -> u32 {
        self.shared.restart_count.load(Ordering::SeqCst)
    }

    pub fn last_exit(&self) -> Option<String> {
        self.shared.last_exit.lock().ok().and_then(|g| g.clone())
    }

    pub fn logs(&self) -> Vec<String> {
        self.shared
            .logs
            .lock()
            .map(|g| g.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Run `sing-box check -c <config>`; Ok(()) only when the binary
    /// accepts the configuration.
    pub fn check_config(&self, config_path: &Path) -> Result<(), String> {
        let output = core_command(&self.binary)
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

    /// `sing-box version`, first line (e.g. "sing-box version 1.14.4").
    pub fn version(&self) -> Result<String, String> {
        let output = core_command(&self.binary)
            .arg("version")
            .output()
            .map_err(|e| format!("cannot run sing-box version: {e}"))?;
        if !output.status.success() {
            return Err("sing-box version failed".to_string());
        }
        let text = String::from_utf8_lossy(&output.stdout);
        text.lines()
            .next()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .ok_or_else(|| "empty version output".to_string())
    }

    pub fn start(&mut self, config_path: &Path) -> Result<(), String> {
        if self.state() == CoreState::Running {
            return Err("sing-box is already running".to_string());
        }
        if !config_path.exists() {
            return Err(format!("config not found: {}", config_path.display()));
        }
        self.shared.stop_requested.store(false, Ordering::SeqCst);
        self.shared.restart_count.store(0, Ordering::SeqCst);
        if let Ok(mut le) = self.shared.last_exit.lock() {
            *le = None;
        }
        let child = spawn_child(&self.binary, config_path, &self.shared)?;
        if let Ok(mut slot) = self.shared.child.lock() {
            *slot = Some(child);
        }
        // Monitor: restart on unexpected exit, up to MAX_RESTARTS.
        let shared = Arc::clone(&self.shared);
        let binary = self.binary.clone();
        let config = config_path.to_path_buf();
        std::thread::spawn(move || loop {
            std::thread::sleep(MONITOR_TICK);
            if shared.stop_requested.load(Ordering::SeqCst) {
                break;
            }
            let exited = {
                let mut slot = match shared.child.lock() {
                    Ok(s) => s,
                    Err(_) => break,
                };
                match slot.as_mut() {
                    None => break,
                    Some(child) => match child.try_wait() {
                        Ok(Some(status)) => {
                            *slot = None;
                            Some(status)
                        }
                        Ok(None) => None,
                        Err(_) => {
                            *slot = None;
                            break;
                        }
                    },
                }
            };
            let Some(status) = exited else { continue };
            if shared.stop_requested.load(Ordering::SeqCst) {
                break;
            }
            let count = shared.restart_count.load(Ordering::SeqCst);
            if count >= MAX_RESTARTS {
                let msg = format!("sing-box exited ({status}) and restart limit reached");
                if let Ok(mut le) = shared.last_exit.lock() {
                    *le = Some(msg.clone());
                }
                push_log(&shared, format!("[core] {msg}"));
                break;
            }
            shared.restart_count.store(count + 1, Ordering::SeqCst);
            push_log(
                &shared,
                format!(
                    "[core] sing-box exited unexpectedly ({status}); restarting ({}/{MAX_RESTARTS})",
                    count + 1
                ),
            );
            match spawn_child(&binary, &config, &shared) {
                Ok(child) => {
                    if let Ok(mut slot) = shared.child.lock() {
                        *slot = Some(child);
                    }
                }
                Err(e) => {
                    if let Ok(mut le) = shared.last_exit.lock() {
                        *le = Some(format!("restart failed: {e}"));
                    }
                    break;
                }
            }
        });
        Ok(())
    }

    pub fn stop(&mut self) -> Result<(), String> {
        self.shared.stop_requested.store(true, Ordering::SeqCst);
        let child = self
            .shared
            .child
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        match child {
            None => Ok(()),
            Some(mut child) => {
                let _ = child.kill();
                child
                    .wait()
                    .map_err(|e| format!("cannot wait for sing-box exit: {e}"))?;
                job_close(&self.shared);
                Ok(())
            }
        }
    }
}

impl Drop for CoreProcess {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A stand-in "sing-box": `check` exits 0, `run` prints a log
    /// line and stays alive.
    #[cfg(windows)]
    fn fake_binary(dir: &Path) -> PathBuf {
        let path = dir.join("fake-sing-box.cmd");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "@echo off").unwrap();
        writeln!(f, "if \"%1\"==\"check\" exit /b 0").unwrap();
        writeln!(f, "if \"%1\"==\"version\" echo sing-box version 0.0.0-fake").unwrap();
        writeln!(f, "if \"%1\"==\"run\" echo fake-core-started & ping -n 31 127.0.0.1 >nul").unwrap();
        path
    }

    #[cfg(not(windows))]
    fn fake_binary(dir: &Path) -> PathBuf {
        let path = dir.join("fake-sing-box");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "#!/bin/sh").unwrap();
        writeln!(f, "if [ \"$1\" = \"check\" ]; then exit 0; fi").unwrap();
        writeln!(f, "if [ \"$1\" = \"version\" ]; then echo 'sing-box version 0.0.0-fake'; exit 0; fi").unwrap();
        writeln!(f, "if [ \"$1\" = \"run\" ]; then echo fake-core-started; sleep 30; fi").unwrap();
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    /// A stand-in that crashes immediately on `run`.
    #[cfg(windows)]
    fn crashing_binary(dir: &Path) -> PathBuf {
        let path = dir.join("crash-sing-box.cmd");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "@echo off").unwrap();
        writeln!(f, "if \"%1\"==\"run\" exit /b 3").unwrap();
        writeln!(f, "exit /b 0").unwrap();
        path
    }

    #[cfg(not(windows))]
    fn crashing_binary(dir: &Path) -> PathBuf {
        let path = dir.join("crash-sing-box");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "#!/bin/sh").unwrap();
        writeln!(f, "if [ \"$1\" = \"run\" ]; then exit 3; fi").unwrap();
        writeln!(f, "exit 0").unwrap();
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    fn test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("tokiboshi-test-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn lifecycle_with_fake_binary() {
        let dir = test_dir("life");
        let config = dir.join("config.json");
        std::fs::write(&config, "{}").unwrap();

        let mut core = CoreProcess::new(fake_binary(&dir));
        assert_eq!(core.state(), CoreState::Stopped);
        assert!(core.check_config(&config).is_ok());
        assert_eq!(core.version().unwrap(), "sing-box version 0.0.0-fake");
        core.start(&config).unwrap();
        assert_eq!(core.state(), CoreState::Running);
        assert!(core.start(&config).is_err(), "double start must fail");
        // Log capture: the fake prints one line at startup.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !core.logs().iter().any(|l| l.contains("fake-core-started")) {
            assert!(std::time::Instant::now() < deadline, "log line never captured");
            std::thread::sleep(Duration::from_millis(100));
        }
        core.stop().unwrap();
        assert_eq!(core.state(), CoreState::Stopped);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn crash_is_restarted_up_to_the_limit_then_reported() {
        let dir = test_dir("crash");
        let config = dir.join("config.json");
        std::fs::write(&config, "{}").unwrap();

        let mut core = CoreProcess::new(crashing_binary(&dir));
        core.start(&config).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            let _ = core.state();
            if core.restart_count() >= MAX_RESTARTS && core.last_exit().is_some() {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "supervisor did not exhaust restarts in time: count={} exit={:?}",
                core.restart_count(),
                core.last_exit()
            );
            std::thread::sleep(Duration::from_millis(200));
        }
        assert_eq!(core.state(), CoreState::Stopped);
        assert!(core
            .logs()
            .iter()
            .any(|l| l.contains("exited unexpectedly")));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn terminal_colors_are_removed_from_visible_logs() {
        assert_eq!(plain_log("\u{1b}[36mINFO\u{1b}[0m ready"), "INFO ready");
    }

    #[test]
    fn start_rejects_missing_config() {
        let mut core = CoreProcess::new("/bin/true");
        let missing = Path::new("/nonexistent/tokiboshi-config.json");
        assert!(core.start(missing).is_err());
    }
}
