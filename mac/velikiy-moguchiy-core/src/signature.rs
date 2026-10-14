//! Ed25519 signatures of downloaded model releases.

use base64::Engine;

/// Whether `signature_b64` is a valid Ed25519 signature of `message` by
/// `public_key_b64` (both standard base64: a raw 32-byte key, a 64-byte
/// signature). Malformed input is an error, a wrong signature is `Ok(false)`.
pub fn verify_ed25519(public_key_b64: &str, message: &[u8], signature_b64: &str) -> Result<bool, String> {
    let engine = base64::engine::general_purpose::STANDARD;
    let key = engine
        .decode(public_key_b64.trim())
        .map_err(|e| format!("public key: {e}"))?;
    let signature = engine
        .decode(signature_b64.trim())
        .map_err(|e| format!("signature: {e}"))?;
    if key.len() != 32 || signature.len() != 64 {
        return Err("public key must be 32 bytes and signature 64".into());
    }
    let key = ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key);
    Ok(key.verify(message, &signature).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn keypair() -> Ed25519KeyPair {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
    }

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn accepts_the_signers_signature_only() {
        let signer = keypair();
        let other = keypair();
        let public = b64(signer.public_key().as_ref());
        let message = b"velikiy-moguchiy/lips-release/v1\nlips-0.2\nabc  file.pt\n";
        let signature = b64(signer.sign(message).as_ref());

        assert_eq!(verify_ed25519(&public, message, &signature), Ok(true));
        assert_eq!(verify_ed25519(&public, b"another message", &signature), Ok(false));
        let forged = b64(other.sign(message).as_ref());
        assert_eq!(verify_ed25519(&public, message, &forged), Ok(false));
    }

    #[test]
    fn rejects_malformed_input() {
        assert!(verify_ed25519("not base64!", b"m", &b64(&[0; 64])).is_err());
        assert!(verify_ed25519(&b64(&[0; 31]), b"m", &b64(&[0; 64])).is_err());
        assert!(verify_ed25519(&b64(&[0; 32]), b"m", &b64(&[0; 63])).is_err());
    }
}
