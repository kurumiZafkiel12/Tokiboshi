//! Real pinned-core check for the newly supported routing and classical rules.
use rust_lib_tokiboshi::config::{build_config_multi,CoreSettings,NodeSpec};
use rust_lib_tokiboshi::profile::{parse_clash_profile,convert_provider};
use serde_json::json;
#[test]
fn classical_ports_lan_and_process_rules_pass_real_core_check(){
 let Ok(binary)=std::env::var("SING_BOX") else {eprintln!("SING_BOX not configured; native check not executed");return;};
 let mut profile=parse_clash_profile("rule-providers:\n  applications: {type: http, behavior: classical, url: 'https://fixture.example/rules.yaml'}\nrules:\n - RULE-SET,applications,DIRECT\n - DST-PORT,80/443/8000-8010,DIRECT\n - SRC-PORT,53,DIRECT\n - GEOIP,LAN,DIRECT\n - MATCH,fixture\n").unwrap().unwrap();
 assert!(profile.unsupported.is_empty(),"{:?}",profile.unsupported);
 let rules=convert_provider("payload:\n - PROCESS-NAME,example.exe\n - DOMAIN-SUFFIX,example.test\n - DST-PORT,443\n - NETWORK,UDP\n - IP-CIDR,192.0.2.0/24,no-resolve\n","classical","yaml").unwrap();
 profile.rule_sets=vec![json!({"type":"inline","tag":"applications","rules":rules})];
 let nodes=[NodeSpec{name:"fixture".into(),outbound_json:json!({"type":"socks","server":"127.0.0.1","server_port":1}).to_string()}];
 let config=build_config_multi(&nodes,&CoreSettings{block_ads:false,bypass_cn:false,..Default::default()},Some("fixture"),Some(&profile)).unwrap();
 let path=std::env::temp_dir().join(format!("tokiboshi-profile-import-{}.json",std::process::id()));std::fs::write(&path,config).unwrap();
 let result=std::process::Command::new(binary).args(["check","-c"]).arg(&path).output().unwrap();let _=std::fs::remove_file(&path);
 assert!(result.status.success(),"{}",String::from_utf8_lossy(&result.stderr));
}
