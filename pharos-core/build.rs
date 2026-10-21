use std::env;
use std::path::PathBuf;

fn main() {
    link_duckdb();

    // A build script that prints any rerun-if-changed (link_duckdb does)
    // reruns ONLY for the paths it names, so the header's inputs are named
    // here; without them a new FFI function never reaches pharos_core.h.
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let out_dir = PathBuf::from(&crate_dir).join("include");
    std::fs::create_dir_all(&out_dir).ok();

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(cbindgen::Config::from_file("cbindgen.toml").unwrap())
        .generate()
        .expect("Unable to generate C bindings")
        .write_to_file(out_dir.join("pharos_core.h"));
}

/// Link the extension libraries `scripts/build-duckdb.sh` built for this
/// target. libduckdb-sys links `libduckdb_static.a` itself (DUCKDB_LIB_DIR +
/// DUCKDB_STATIC, from `.cargo/config.toml` or the environment); everything
/// else in the folder — the extensions, the extension loader, DuckDB's own
/// third-party code and the vcpkg libraries — is linked here. All of it is
/// bundled into libpharos_core.a, so Xcode links one archive.
fn link_duckdb() {
    let target = env::var("TARGET").unwrap();
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lib_dir = match env::var("DUCKDB_LIB_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => crate_dir.join("target/duckdb").join(&target).join("lib"),
    };
    println!("cargo:rerun-if-env-changed=DUCKDB_LIB_DIR");
    println!("cargo:rerun-if-changed={}", lib_dir.join("../stamp").display());
    let entries = match std::fs::read_dir(&lib_dir) {
        Ok(e) => e,
        Err(_) => panic!(
            "No DuckDB libraries in {}. Run scripts/build-duckdb.sh {} first.",
            lib_dir.display(),
            if target.starts_with("x86_64") { "x86_64" } else { "arm64" }
        ),
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let file = e.file_name().to_string_lossy().to_string();
            let name = file.strip_prefix("lib")?.strip_suffix(".a")?.to_string();
            (name != "duckdb_static").then_some(name)
        })
        .collect();
    names.sort();
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    for name in names {
        println!("cargo:rustc-link-lib=static={}", name);
    }
    // System libraries the C++ code needs (the app links the same ones in
    // project.yml): DuckDB is C++; minizip-ng (excel) uses macOS's zlib and
    // Apple's compression library.
    for lib in ["c++", "z", "compression"] {
        println!("cargo:rustc-link-lib=dylib={}", lib);
    }
}
