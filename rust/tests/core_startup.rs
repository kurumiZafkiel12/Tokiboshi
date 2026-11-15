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
    if scratch.exists() { std::fs::remove_dir_all(&scratch).unwrap(); }
    std::fs::create_dir_all(&scratch).unwrap();
    // An HTTP endpoint that accepts TCP but never sends response headers.
    // Without preparing a local UI, sing-box waits here before binding its API.
    let blocked_panel = TcpListener::bind(("127.0.0.1", 0)).unwrap();
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
    std::fs::write(&path, build_config_multi(&nodes, &settings, None, None).unwrap()).unwrap();
    let error = core::start_core(binary.clone(), path.to_string_lossy().into()).unwrap_err();
    assert!(error.contains("被占用"), "{error}");
    assert!(!core::core_running());
    // Leave the other listener running; reconfigure our own port only.
    let next = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    settings.mixed_port = next.local_addr().unwrap().port();
    drop(next);
    std::fs::write(&path, build_config_multi(&nodes, &settings, None, None).unwrap()).unwrap();
    let mut config: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    config["experimental"]["clash_api"]["external_ui_download_url"] = serde_json::json!(format!(
        "http://127.0.0.1:{}/never-respond.zip", blocked_panel.local_addr().unwrap().port()));
    std::fs::write(&path, config.to_string()).unwrap();
    let started = std::time::Instant::now();
    core::start_core(binary, path.to_string_lossy().into()).unwrap();
    assert!(started.elapsed() < Duration::from_secs(3), "startup waited for optional panel download");
    let panel = request(api_port, "GET /ui/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    assert!(panel.contains("200 OK"), "{panel}");
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
    // Prove the configured detour is used: both local SOCKS relays must see
    // the next hop, and the origin must receive the HTTP request through them.
    let origin = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let origin_port = origin.local_addr().unwrap().port();
    let origin_thread = std::thread::spawn(move || {
        let (mut stream, _) = origin.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut buf = [0; 4096];
        stream.read(&mut buf).unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nchain").unwrap();
    });
    let exit_listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let exit_port = exit_listener.local_addr().unwrap().port();
    let exit_thread = socks_relay(exit_listener, origin_port);
    let entry_listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let entry_port = entry_listener.local_addr().unwrap().port();
    let entry_thread = socks_relay(entry_listener, exit_port);
    let free_mixed = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let free_api = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    settings.mixed_port = free_mixed.local_addr().unwrap().port();
    settings.clash_api_port = free_api.local_addr().unwrap().port();
    drop((free_mixed, free_api));
    let nodes = vec![
        NodeSpec { name: "proxy".into(), outbound_json: format!(
            r#"{{"type":"socks","server":"127.0.0.1","server_port":{entry_port}}}"#) },
        NodeSpec { name: "exit".into(), outbound_json: format!(
            r#"{{"type":"socks","server":"127.0.0.1","server_port":{exit_port},"detour":"proxy"}}"#) },
    ];
    let mut config: serde_json::Value = serde_json::from_str(
        &build_config_multi(&nodes, &settings, Some("exit")).unwrap()).unwrap();
    // Keep the generated chain, but disable probes and private-address bypass
    // so this local-only request is required to traverse both SOCKS servers.
    config["outbounds"].as_array_mut().unwrap().retain(|ob| ob["tag"] != "auto");
    config["outbounds"][0]["outbounds"] = serde_json::json!(["exit"]);
    config["route"]["rules"] = serde_json::json!([]);
    std::fs::write(&path, config.to_string()).unwrap();
    core::start_core(std::env::var("SING_BOX").unwrap(), path.to_string_lossy().into()).unwrap();
    let chain_guard = Stop;
    let response = request(settings.mixed_port, &format!(
        "GET http://127.0.0.1:{origin_port}/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
    assert!(response.ends_with("chain"), "{response}");
    origin_thread.join().unwrap();
    entry_thread.join().unwrap();
    exit_thread.join().unwrap();
    drop(chain_guard);
    // Windows can briefly hold files of a freshly exited process
    // (e.g. Defender scanning cache.db), making remove_dir_all fail
    // with DirectoryNotEmpty. Cleanup is best-effort for the runner.
    for _ in 0..10 {
        match std::fs::remove_dir_all(&scratch) {
            Ok(()) => break,
            Err(_) => std::thread::sleep(Duration::from_millis(300)),
        }
    }
}


fn socks_relay(listener: TcpListener, expected_port: u16) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let (mut client, _) = listener.accept().unwrap();
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut greeting = [0; 2];
        client.read_exact(&mut greeting).unwrap();
        assert_eq!(greeting[0], 5);
        let mut methods = vec![0; greeting[1] as usize];
        client.read_exact(&mut methods).unwrap();
        assert!(methods.contains(&0));
        client.write_all(&[5, 0]).unwrap();
        let mut header = [0; 4];
        client.read_exact(&mut header).unwrap();
        assert_eq!(header, [5, 1, 0, 1]);
        let mut target = [0; 6];
        client.read_exact(&mut target).unwrap();
        assert_eq!(&target[..4], &[127, 0, 0, 1]);
        assert_eq!(u16::from_be_bytes([target[4], target[5]]), expected_port);
        let mut upstream = TcpStream::connect(("127.0.0.1", expected_port)).unwrap();
        upstream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        client.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).unwrap();
        let mut upstream_read = upstream.try_clone().unwrap();
        let mut client_write = client.try_clone().unwrap();
        let response = std::thread::spawn(move || {
            std::io::copy(&mut upstream_read, &mut client_write).unwrap();
            client_write.shutdown(std::net::Shutdown::Write).unwrap();
        });
        std::io::copy(&mut client, &mut upstream).unwrap();
        upstream.shutdown(std::net::Shutdown::Write).unwrap();
        response.join().unwrap();
    })
}
