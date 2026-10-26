//! Real quickstart smoke: Genesis token -> OPAQUE signup start/finish.
//! Usage: quickstart-admission CA_FILE [--expect-rejected]
//! Env: QS_API_PORT (8443), QS_GENESIS_PORT (9443), QS_ORIGIN
//! (http://localhost:8080). curl performs TLS/hostname checking. Tokens and
//! protocol transcripts stay in memory/stdin, never argv, files or diagnostics.
use base64::{Engine, engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD}};
use opaque_ke::{CipherSuite, ClientRegistration, ClientRegistrationFinishParameters,
    Identifiers, RegistrationResponse, key_exchange::tripledh::TripleDh};
use rand_core::OsRng;
use serde_json::{Value, json};
use std::{env, io::Write, process::{Command, Stdio}};

struct Suite;
impl CipherSuite for Suite {
    type OprfCs = opaque_ke::Ristretto255;
    type KeyExchange = TripleDh<opaque_ke::Ristretto255, sha2::Sha512>;
    type Ksf = argon2::Argon2<'static>;
}

struct Http { ca: String, origin: String, api_port: String, genesis_port: String }
impl Http {
    fn request(&self, genesis: bool, path: &str, body: Option<&Value>, token: Option<&str>) -> Result<(u16, String), String> {
        let (host, port) = if genesis { ("genesis.localhost", &self.genesis_port) } else { ("api.localhost", &self.api_port) };
        let mut cmd = Command::new("curl");
        cmd.args(["--silent", "--show-error", "--noproxy", "*", "--max-time", "30", "--cacert", &self.ca,
            "--resolve", &format!("{host}:{port}:127.0.0.1"), "--write-out", "\n%{http_code}",
            "--url", &format!("https://{host}:{port}{path}"), "--config", "-"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut config = format!("header = \"Origin: {}\"\n", self.origin);
        if let Some(token) = token {
            if token.contains(['\r', '\n', '"', '\\']) { return Err("Unsafe token encoding".into()); }
            config.push_str(&format!("header = \"X-Permesi-Zero-Token: {token}\"\n"));
        }
        if let Some(body) = body {
            config.push_str("header = \"Content-Type: application/json\"\n");
            // curl config quoting, not shell interpolation.
            config.push_str(&format!("data = {}\n", serde_json::to_string(&body.to_string()).unwrap()));
        }
        let mut child = cmd.spawn().map_err(|_| "Cannot start curl")?;
        child.stdin.take().unwrap().write_all(config.as_bytes()).map_err(|_| "curl stdin failed")?;
        let output = child.wait_with_output().map_err(|_| "curl failed")?;
        if !output.status.success() { return Err(format!("Trusted HTTPS request failed (curl exit {:?})", output.status.code())); }
        let out = String::from_utf8(output.stdout).map_err(|_| "HTTP response not UTF-8")?;
        let (body, status) = out.rsplit_once('\n').ok_or("Missing HTTP status")?;
        Ok((status.parse().map_err(|_| "Invalid HTTP status")?, body.to_owned()))
    }
}
fn field<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> { v[key].as_str().ok_or_else(|| format!("Missing response field {key}")) }
fn expect(status: u16, want: u16, stage: &str) -> Result<(), String> {
    if status != want { return Err(format!("{stage}: HTTP {status}, expected {want}")); } Ok(())
}
fn error_message(body: &str) -> String {
    serde_json::from_str::<Value>(body).ok()
        .and_then(|v| v["error"]["message"].as_str().map(str::to_owned))
        .unwrap_or_else(|| body.to_owned())
}
fn run() -> Result<(), String> {
    let ca = env::args().nth(1).ok_or("Usage: quickstart-admission CA_FILE [--expect-rejected]")?;
    let http = Http { ca, origin: env::var("QS_ORIGIN").unwrap_or_else(|_| "http://localhost:8080".into()),
        api_port: env::var("QS_API_PORT").unwrap_or_else(|_| "8443".into()),
        genesis_port: env::var("QS_GENESIS_PORT").unwrap_or_else(|_| "9443".into()) };
    let (status, body) = http.request(true, "/token?client_id=00000000-0000-0000-0000-000000000000", None, None)?;
    expect(status, 200, "Genesis token issuance")?;
    let token: Value = serde_json::from_str(&body).map_err(|_| "Invalid Genesis JSON")?;
    let token = field(&token, "token")?;
    let password = b"quickstart-disposable-registration-password";
    let registration = ClientRegistration::<Suite>::start(&mut OsRng, password).map_err(|_| "OPAQUE start failed")?;
    let mut nonce = [0u8; 12]; rand_core::RngCore::fill_bytes(&mut OsRng, &mut nonce);
    let email = format!("qs-{}@example.test", nonce.iter().map(|b| format!("{b:02x}")).collect::<String>());
    let body = json!({"email":email,"registration_request":STANDARD.encode(registration.message.serialize())});
    let path = "/v1/auth/opaque/signup/start";
    if env::args().any(|a| a == "--expect-rejected") {
        let (status, reply) = http.request(false, path, Some(&body), Some(token))?;
        expect(status, 400, "Wrong issuer/audience token")?;
        if error_message(&reply) != "Invalid token" { return Err("Wrong-profile response was not an admission rejection".into()); }
        println!("PASS: correctly signed wrong issuer/audience token rejected by Permesi admission (400 Invalid token)");
        return Ok(());
    }
    // Flip a signature bit on the real token, retaining its valid envelope,
    // claims and footer. A malformed placeholder is not tamper verification.
    let mut parts: Vec<_> = token.split('.').map(str::to_owned).collect();
    let encoded = parts.get(2).ok_or("Invalid PASETO envelope")?;
    let mut signed = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| "Invalid PASETO encoding")?;
    *signed.last_mut().ok_or("Empty PASETO signature")? ^= 1;
    parts[2] = URL_SAFE_NO_PAD.encode(signed);
    let tampered = parts.join(".");
    for (candidate, expected, label) in [(None, "Missing zero token", "missing"), (Some(tampered.as_str()), "Invalid token", "signature-tampered")] {
        let (status, reply) = http.request(false, path, Some(&body), candidate)?;
        expect(status, 400, label)?;
        if error_message(&reply) != expected { return Err(format!("{label}: not an admission-layer rejection")); }
        println!("PASS: {label} zero token rejected at admission (400 {expected})");
    }
    let (status, reply) = http.request(false, path, Some(&body), Some(token))?;
    expect(status, 200, "OPAQUE signup start with real Genesis token")?;
    let response: Value = serde_json::from_str(&reply).map_err(|_| "Invalid registration JSON")?;
    let bytes = STANDARD.decode(field(&response, "registration_response")?).map_err(|_| "Invalid registration base64")?;
    let response = RegistrationResponse::<Suite>::deserialize(&bytes).map_err(|_| "Invalid OPAQUE registration response")?;
    println!("PASS: real Genesis zero token accepted by Permesi; signup/start 200 with decodable OPAQUE response");
    let ksf = argon2::Argon2::default();
    let params = ClientRegistrationFinishParameters::new(Identifiers { client: Some(email.as_bytes()), server: Some(b"api.localhost") }, Some(&ksf));
    let finish = registration.state.finish(&mut OsRng, password, response, params).map_err(|_| "OPAQUE finish failed")?;
    let body = json!({"email":email,"registration_record":STANDARD.encode(finish.message.serialize())});
    let (status, _) = http.request(false, "/v1/auth/opaque/signup/finish", Some(&body), Some(token))?;
    expect(status, 201, "OPAQUE signup finish")?;
    // Public test email is the only persisted identifier; no password/token/proof output.
    println!("PASS: real OPAQUE signup/finish 201; pending-account email={email}");
    Ok(())
}
fn main() { if let Err(err) = run() { eprintln!("FAIL: {err}"); std::process::exit(1); } }
