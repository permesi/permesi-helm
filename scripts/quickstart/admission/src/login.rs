//! Run the client side of one disposable test login over the parent's private pipes.
//! The parent performs the verified HTTPS requests and retains the resulting session.
use super::{STANDARD, Suite, field};
use base64::Engine as _;
use opaque_ke::{ClientLogin, ClientLoginFinishParameters, CredentialResponse, Identifiers};
use rand_core::OsRng;
use serde_json::Value;
use std::io::{self, BufRead as _, Write as _};

pub fn proof(email: &str) -> Result<(), String> {
    let password = b"quickstart-disposable-registration-password";
    let client = ClientLogin::<Suite>::start(&mut OsRng, password).map_err(|_| "OPAQUE login start failed")?;
    println!("{}", STANDARD.encode(client.message.serialize()));
    io::stdout().flush().map_err(|_| "client pipe closed")?;
    let mut response = String::new();
    io::stdin().lock().read_line(&mut response).map_err(|_| "server pipe closed")?;
    let fields: Value = serde_json::from_str(&response).map_err(|_| "invalid server response")?;
    let bytes = STANDARD.decode(field(&fields, "credential_response")?).map_err(|_| "invalid response encoding")?;
    let message = CredentialResponse::<Suite>::deserialize(&bytes).map_err(|_| "invalid OPAQUE response")?;
    let identifiers = Identifiers { client: Some(email.as_bytes()), server: Some(b"api.localhost") };
    let ksf = argon2::Argon2::default();
    let params = ClientLoginFinishParameters::new(None, identifiers, Some(&ksf));
    let result = client.state.finish(&mut OsRng, password, message, params).map_err(|_| "OPAQUE login failed")?;
    println!("{}", STANDARD.encode(result.message.serialize()));
    Ok(())
}
