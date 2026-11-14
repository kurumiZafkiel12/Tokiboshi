//! Real core startup, port collision, API and local HTTP forwarding smoke test.
use rust_lib_tokiboshi::{api::core, config::{build_config_multi, CoreSettings, NodeSpec}};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

fn request(port: u16, text: &str) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.write_all(text.as_bytes()).unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response
}

#[test]
fn occupied_port_is_reported_and_real_core_forwards_after_reconfiguration() {
    let Ok(binary) = std::env::var("SING_BOX") else {
        eprintln!("SING_BOX unset: real-core startup smoke test not executed");
        return;
    };
    let scratch = std::env::temp_dir().join(format!("tkb-startup-{}", std::process::id()));
    std::fs::create_dir_all(scratch.join("ui")).unwrap();
    std::fs::write(scratch.join("ui/index.html"), "local test panel").unwrap();
    let occupied = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let free = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let api_port = free.local_addr().unwrap().port();
    drop(free);
    let mut settings = CoreSettings {
        mixed_port: occupied.local_addr().unwrap().port(), clash_api_port: api_port,
        data_dir: scratch.to_string_lossy().into(), ..Default::default()
    };
    let nodes = vec![NodeSpec { name: "local".into(), outbound_json:
        r#"{"type":"socks","server":"127.0.0.1","server_port":1}"#.into() }];
    let path = scratch.join("config.json");
    std::fs::write(&path, build_config_multi(&nodes, &settings, None).unwrap()).unwrap();
    let error = core::start_core(binary.clone(), path.to_string_lossy().into()).unwrap_err();
    assert!(error.contains("被占用"), "{error}");
    assert!(!core::core_running());
    // Leave the other listener running; reconfigure our own port only.
    let next = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    settings.mixed_port = next.local_addr().unwrap().port();
    drop(next);
    std::fs::write(&path, build_config_multi(&nodes, &settings, None).unwrap()).unwrap();
    core::start_core(binary, path.to_string_lossy().into()).unwrap();
    struct Stop;
    impl Drop for Stop { fn drop(&mut self) { let _ = core::stop_core(); } }
    let guard = Stop;
    assert!(core::core_running());
    let version = request(api_port, "GET /version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    assert!(version.contains("200 OK") && version.contains("1.14.4"), "{version}");
    let origin = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let origin_port = origin.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let (mut connection, _) = origin.accept().unwrap();
        connection.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut buf = [0; 4096];
        connection.read(&mut buf).unwrap();
        connection.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\ntokiboshi").unwrap();
    });
    let response = request(settings.mixed_port, &format!(
        "GET http://127.0.0.1:{origin_port}/ HTTP/1.1\r\nHost: 127.0.0.1:{origin_port}\r\nConnection: close\r\n\r\n"));
    assert!(response.contains("200 OK") && response.ends_with("tokiboshi"), "{response}");
    server.join().unwrap();
    drop(guard);
    assert!(!core::core_running());
    drop(occupied);
    std::fs::remove_dir_all(scratch).unwrap();
}
