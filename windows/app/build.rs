//! Windows resources: the program icon, the tray icon for recording, the
//! manifest and version info. Both icons are made from the Mac app's icon, so
//! the artwork has one source.

use std::io::Cursor;
use std::path::{Path, PathBuf};

const APP_ICON: &str = "../../mac/MacApp/VelikiyMoguchiy/Assets.xcassets/AppIcon.appiconset";
/// Source PNG and the pixel size it has.
const FRAMES: &[(&str, u32)] = &[
    ("icon_16x16.png", 16),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_256x256.png", 256),
];
/// The recording icon is only shown in the tray, at small sizes.
const RECORDING_SIZES: &[u32] = &[16, 32, 64];

fn main() {
    println!("cargo:rerun-if-changed=resources");
    println!("cargo:rerun-if-changed={APP_ICON}");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let source = manifest_dir.join(APP_ICON);

    let frames: Vec<(u32, Vec<u8>)> = FRAMES
        .iter()
        .map(|(name, size)| (*size, read(&source.join(name))))
        .collect();
    std::fs::write(out.join("app.ico"), ico(&frames)).unwrap();

    let recording: Vec<(u32, Vec<u8>)> = frames
        .iter()
        .filter(|(size, _)| RECORDING_SIZES.contains(size))
        .map(|(size, png)| (*size, with_red_dot(png)))
        .collect();
    std::fs::write(out.join("recording.ico"), ico(&recording)).unwrap();

    let rc = std::fs::read_to_string(manifest_dir.join("resources/app.rc")).unwrap();
    let rc = rc
        .replace("\"app.ico\"", &rc_path(&out.join("app.ico")))
        .replace("\"recording.ico\"", &rc_path(&out.join("recording.ico")))
        .replace(
            "\"app.manifest\"",
            &rc_path(&manifest_dir.join("resources/app.manifest")),
        );
    let rc_file = out.join("app.rc");
    std::fs::write(&rc_file, rc).unwrap();
    embed_resource::compile(&rc_file, embed_resource::NONE)
        .manifest_required()
        .expect("compiling the Windows resources");
}

fn read(path: &Path) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn rc_path(path: &Path) -> String {
    format!("\"{}\"", path.display().to_string().replace('\\', "\\\\"))
}

/// An .ico container of PNG frames (supported since Windows Vista).
fn ico(frames: &[(u32, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&(frames.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * frames.len() as u32;
    for (size, png) in frames {
        let dim = if *size >= 256 { 0 } else { *size as u8 };
        out.extend_from_slice(&[dim, dim, 0, 0]);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&(png.len() as u32).to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        offset += png.len() as u32;
    }
    for (_, png) in frames {
        out.extend_from_slice(png);
    }
    out
}

/// The icon with a red recording dot in the lower right corner.
fn with_red_dot(png_bytes: &[u8]) -> Vec<u8> {
    let mut decoder = png::Decoder::new(Cursor::new(png_bytes));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().unwrap();
    let mut buf = vec![0; reader.output_buffer_size().unwrap()];
    let info = reader.next_frame(&mut buf).unwrap();
    let (w, h) = (info.width, info.height);
    let mut rgba = match info.color_type {
        png::ColorType::Rgba => buf[..info.buffer_size()].to_vec(),
        png::ColorType::Rgb => buf[..info.buffer_size()]
            .chunks_exact(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        other => panic!("unexpected icon colour type {other:?}"),
    };

    let s = w.min(h) as f32;
    let r = (s * 0.24).max(3.5);
    let (cx, cy) = (w as f32 - r - s / 32.0, h as f32 - r - s / 32.0);
    for y in 0..h {
        for x in 0..w {
            let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let (color, coverage) = if d <= r - 0.5 {
                ([0xE5, 0x48, 0x4D], 1.0)
            } else if d <= r + 0.5 {
                ([0xE5, 0x48, 0x4D], r + 0.5 - d)
            } else if d <= r + 1.5 && s >= 32.0 {
                ([0xFF, 0xFF, 0xFF], (r + 1.5 - d).min(1.0))
            } else {
                continue;
            };
            let i = ((y * w + x) * 4) as usize;
            for c in 0..3 {
                let under = rgba[i + c] as f32;
                rgba[i + c] = (under + (color[c] as f32 - under) * coverage).round() as u8;
            }
            rgba[i + 3] = rgba[i + 3].max((coverage * 255.0) as u8);
        }
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().unwrap();
    writer.write_image_data(&rgba).unwrap();
    writer.finish().unwrap();
    out
}
