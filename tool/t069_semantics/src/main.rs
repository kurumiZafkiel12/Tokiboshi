#![allow(dead_code)]
#[path = "../../../rust/src/profile.rs"] mod profile;
#[path = "../../../rust/src/config.rs"] mod config;
#[path = "../../../rust/src/links.rs"] mod links;
use serde_json::{json,Value};
use std::{path::PathBuf,process::Command};
fn main(){
 let dir=PathBuf::from(std::env::var("SEMANTIC_OUT").expect("SEMANTIC_OUT"));std::fs::create_dir_all(&dir).unwrap();
 let core=std::env::var("SING_BOX").expect("real core required");
 let prefix="proxies:\n  - {name: HK, type: socks5, server: 127.0.0.1, port: 1}\nproxy-groups:\n  - {name: Group, type: select, proxies: [HK]}\n";
 let cases:Vec<(&str,String)>=vec![
 ("clash-basic",format!("{prefix}rules:\n  - DOMAIN,blocked.example,REJECT\n  - DOMAIN-SUFFIX,example,Group\n  - MATCH,Group\ndns:\n  nameserver: [1.1.1.1, 8.8.8.8]\n")),
 ("clash-no-resolve",format!("{prefix}rules:\n  - IP-CIDR,203.0.113.0/24,DIRECT,no-resolve\n  - MATCH,HK\n")),
 ("clash-geoip",format!("{prefix}rules:\n  - GEOIP,CN,DIRECT\n  - MATCH,HK\n")),
 ("clash-match-reject",format!("{prefix}rules:\n  - MATCH,REJECT\n")),
 ("clash-provider-yaml",format!("{prefix}rule-providers:\n  sites: {{type: http, behavior: domain, format: yaml, url: 'http://127.0.0.1:19998/sites.yaml'}}\nrules:\n  - RULE-SET,sites,Group\n  - MATCH,Group\n")),
 ("clash-order-after-match",format!("{prefix}rules:\n  - MATCH,HK\n  - DOMAIN,blocked.example,REJECT\n")),
 ("clash-private-precedence",format!("{prefix}rules:\n  - IP-CIDR,127.0.0.0/8,REJECT\n  - MATCH,HK\n")),
 ("native-final-only",json!({"outbounds":[{"type":"socks","tag":"HK","server":"127.0.0.1","server_port":1}],"route":{"final":"HK"}}).to_string()),
 ("native-dns",json!({"outbounds":[{"type":"socks","tag":"HK","server":"127.0.0.1","server_port":1}],"route":{"rules":[{"domain":["route.example"],"outbound":"HK"}],"final":"HK"},"dns":{"servers":[{"type":"udp","tag":"first","server":"1.1.1.1"},{"type":"udp","tag":"second","server":"8.8.8.8"}],"rules":[{"domain":["dns.example"],"server":"second"}],"final":"second","strategy":"ipv4_only"}}).to_string()),
 ];
 let mut results=Vec::new();
 for (name,input) in cases {
  let out=links::parse_subscription(&input).unwrap();
  let p:Option<profile::ParsedProfile>=out.profile_json.as_deref().map(|s|serde_json::from_str(s).unwrap());
  let nodes:Vec<_>=out.nodes.iter().map(|n|config::NodeSpec{name:n.name.clone(),outbound_json:n.outbound_json.clone()}).collect();
  let settings=config::CoreSettings{data_dir:dir.join(name).to_string_lossy().to_string(),..Default::default()};
  let generated=config::build_config_multi(&nodes,&settings,None,p.as_ref());
  std::fs::write(dir.join(format!("{name}.input.txt")),input).unwrap();
  let mut r=json!({"case":name,"profile":p,"profilePresent":out.profile_json.is_some(),"nodeCount":nodes.len()});
  match generated {
   Err(e)=>{r["generationError"]=json!(e);}
   Ok(s)=>{
    let v:Value=serde_json::from_str(&s).unwrap();
    let path=dir.join(format!("{name}.config.json"));std::fs::write(&path,&s).unwrap();
    let check=Command::new(&core).args(["check","-c"]).arg(&path).output().unwrap();
    r["checkExit"]=json!(check.status.code());r["checkStderr"]=json!(String::from_utf8_lossy(&check.stderr));
    r["route"]=v["route"].clone();r["dns"]=v["dns"].clone();
   }
  }
  results.push(r);
 }
 let result=json!({"scope":"original Rust parser/profile/generator modules, real pinned core check; not FRB or Windows acceptance","coreVersion":String::from_utf8_lossy(&Command::new(&core).arg("version").output().unwrap().stdout),"cases":results});
 std::fs::write(dir.join("results.json"),serde_json::to_string_pretty(&result).unwrap()).unwrap();
 println!("{}",serde_json::to_string_pretty(&result).unwrap());
}
