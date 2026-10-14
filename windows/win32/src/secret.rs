//! DPAPI: data only the current Windows user on this computer can decrypt.

use windows::core::PCWSTR;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};

/// Ties the ciphertext to this program: another program of the same user
/// cannot decrypt it without knowing this value.
const ENTROPY: &[u8] = b"velikiy-moguchiy/dashscope-keys/v1";

fn blob(data: &[u8]) -> CRYPT_INTEGER_BLOB {
    CRYPT_INTEGER_BLOB {
        cbData: data.len() as u32,
        pbData: data.as_ptr() as *mut u8,
    }
}

/// Copies the output blob and frees the memory DPAPI allocated for it.
unsafe fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
    let data = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(Some(HLOCAL(out.pbData as *mut _)));
    }
    data
}

pub fn protect(plain: &[u8]) -> Result<Vec<u8>, String> {
    let input = blob(plain);
    let entropy = blob(ENTROPY);
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptProtectData(
            &input,
            PCWSTR::null(),
            Some(&entropy),
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        )
        .map_err(|e| e.to_string())?;
        Ok(take(out))
    }
}

pub fn unprotect(sealed: &[u8]) -> Result<Vec<u8>, String> {
    let input = blob(sealed);
    let entropy = blob(ENTROPY);
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptUnprotectData(
            &input,
            None,
            Some(&entropy),
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        )
        .map_err(|e| e.to_string())?;
        Ok(take(out))
    }
}
