//! End-to-end test for the offline WeType embed_140m provider.
//!
//! Needs the model files locally; set the directory (containing
//! `embed140m.koepack`, `dict.decoder.utf8.txt`, and `test_zh.wav`) via
//!   VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR=/path/to/dir cargo test --features wetype-offline -- --ignored
#![cfg(feature = "wetype-offline")]

use velikiy_moguchiy_asr::wetype::WeTypeOfflineProvider;
use velikiy_moguchiy_asr::{AsrConfig, AsrEvent, AsrProvider};

/// Minimal WAV reader: returns 16-bit PCM samples as little-endian bytes.
fn read_wav_pcm(path: &str) -> Vec<u8> {
    let d = std::fs::read(path).expect("read wav");
    // find "data" chunk
    let mut i = 12;
    while i + 8 <= d.len() {
        let id = &d[i..i + 4];
        let sz = u32::from_le_bytes([d[i + 4], d[i + 5], d[i + 6], d[i + 7]]) as usize;
        if id == b"data" {
            return d[i + 8..(i + 8 + sz).min(d.len())].to_vec();
        }
        i += 8 + sz + (sz & 1);
    }
    panic!("no data chunk in {path}");
}

#[tokio::test]
#[ignore = "needs VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR with the ~135MB embed140m.koepack"]
async fn transcribes_test_zh() {
    let dir = std::env::var("VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR")
        .expect("set VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR to the model directory");
    let pcm = read_wav_pcm(&format!("{dir}/test_zh.wav"));

    let mut asr = WeTypeOfflineProvider::new(&dir);
    asr.connect(&AsrConfig::default()).await.unwrap();
    // feed in ~100ms chunks to exercise buffering
    for chunk in pcm.chunks(3200) {
        asr.send_audio(chunk).await.unwrap();
    }
    asr.finish_input().await.unwrap();

    let mut text = String::new();
    loop {
        match asr.next_event().await.unwrap() {
            AsrEvent::Final(t) => {
                text = t;
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }
    asr.close().await.unwrap();

    println!("transcript = {text:?}");
    assert!(
        text.contains("天气很好"),
        "expected '今天天气很好', got {text:?}"
    );
}

/// Regression: the streaming driver polls `next_event()` in a `select!` while
/// pumping audio. Before `finish_input`, `next_event()` must BLOCK — returning
/// `Closed` on an empty queue made the driver abort with
/// "connection closed unexpectedly by server".
#[tokio::test]
#[ignore = "needs VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR"]
async fn next_event_blocks_until_result() {
    use std::time::Duration;
    let dir = std::env::var("VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR")
        .expect("set VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR");
    let mut asr = WeTypeOfflineProvider::new(&dir);
    asr.connect(&AsrConfig::default()).await.unwrap();

    // first event is Connected
    assert!(matches!(
        asr.next_event().await.unwrap(),
        AsrEvent::Connected
    ));

    // with no audio finished yet, next_event must not resolve (no early Closed)
    let early = tokio::time::timeout(Duration::from_millis(300), asr.next_event()).await;
    assert!(
        early.is_err(),
        "next_event returned before finish_input (would abort the session): {early:?}"
    );

    // now finish → Final then Closed arrive
    asr.finish_input().await.unwrap();
    assert!(matches!(
        asr.next_event().await.unwrap(),
        AsrEvent::Final(_)
    ));
    asr.close().await.unwrap();
}

/// Streaming: pushing audio should produce at least one `Interim` result
/// (live "pill" text) before the final one, rather than only Final at the end.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR"]
async fn streaming_emits_interim() {
    use std::time::Duration;
    let dir = std::env::var("VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR")
        .expect("set VELIKIY_MOGUCHIY_WETYPE_MODEL_DIR");
    let pcm = read_wav_pcm(&format!("{dir}/test_zh.wav"));

    let mut asr = WeTypeOfflineProvider::new(&dir);
    asr.connect(&AsrConfig::default()).await.unwrap();
    for chunk in pcm.chunks(3200) {
        asr.send_audio(chunk).await.unwrap();
    }
    // let the in-flight interim decode finish and emit
    tokio::time::sleep(Duration::from_millis(600)).await;

    let mut interims = 0;
    // drain whatever is queued so far (Connected + any Interim), non-blocking
    while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(20), asr.next_event()).await {
        if let AsrEvent::Interim(t) = ev {
            interims += 1;
            println!("interim: {t:?}");
        }
    }
    assert!(
        interims >= 1,
        "expected at least one Interim during streaming"
    );

    asr.finish_input().await.unwrap();
    let mut final_text = String::new();
    loop {
        match asr.next_event().await.unwrap() {
            AsrEvent::Final(t) => {
                final_text = t;
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }
    assert!(final_text.contains("天气很好"), "final = {final_text:?}");
    asr.close().await.unwrap();
}
