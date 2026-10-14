fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();

    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(cbindgen::Config::from_file(format!("{crate_dir}/cbindgen.toml")).unwrap())
        .with_language(cbindgen::Language::C)
        .generate()
        .expect("Unable to generate C bindings")
        .write_to_file(format!("{crate_dir}/target/velikiy_moguchiy_core.h"));
}
