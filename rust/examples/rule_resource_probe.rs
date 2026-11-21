use rust_lib_tokiboshi::api::core::update_rule_resource;
use std::{fs, path::Path};
fn main() {
    let dir = &std::env::var("RULE_AUDIT_DIR").unwrap();
    let core = &std::env::var("SING_BOX").unwrap();
    let update = |tag: &str, url: &str| update_rule_resource(dir.into(), tag.into(), url.into(), core.into());
    let assets: serde_json::Value = serde_json::from_str(include_str!("../../assets/rule-resources.json")).unwrap();
    for item in assets.as_array().unwrap() {
        let tag = item["tag"].as_str().unwrap();
        update(tag, "").unwrap_or_else(|e| panic!("{tag}: {e}"));
        let path = Path::new(dir).join("rules").join(format!("{tag}.srs"));
        println!("{tag} valid ({} bytes)", fs::metadata(path).unwrap().len());
    }
    let path = Path::new(dir).join("rules/geosite-cn.srs");
    let old = fs::read(&path).unwrap();
    assert!(update("geosite-cn", "http://fixture.example/rules").is_err());
    assert!(update("geosite-cn", "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/no-such-tokiboshi-test-rules.srs").is_err());
    assert_eq!(fs::read(&path).unwrap(), old);
    update("geosite-cn", "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs").unwrap();
    assert!(fs::metadata(&path).unwrap().len() > 8);
    update("geosite-cn", "").unwrap();
    assert_eq!(fs::read(&path).unwrap(), old);
    assert!(fs::read_dir(path.parent().unwrap()).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    println!("Existing file kept after HTTPS rejection and server error; source switch and return to default passed.");
}
