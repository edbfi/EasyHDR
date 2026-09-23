# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

EasyHDR is a Windows-only Slint desktop app (library crate `easyhdr` in `src/lib.rs`, binary in
`src/main.rs`) that turns display HDR on while configured Win32/UWP apps run. The shipped target is
`x86_64-pc-windows-msvc`. Concurrency is std threads, `std::sync::mpsc` channels and `parking_lot`
locks. There is no async runtime: `reqwest` uses its `blocking` feature. Don't add tokio.

## Commands

These match CI (`.github/workflows/ci.yml`, `windows-2025`). Always pass `--locked`.

```bash
cargo fmt --all -- --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo build --release --locked
cargo test --locked --lib --release
cargo test --locked --test integration_tests --release -- --test-threads=1
cargo test --locked --doc --release
```

- CI runs each of these `tests/` files on its own with `--test-threads=1`: `integration_tests`,
  `version_detection_tests`, `memory_usage_test`, `startup_time_test`, `cpu_usage_test`,
  `icon_cache_tests`. Don't expect CI to catch failures in `uwp_process_detection_tests` (it needs
  a desktop that can launch Calculator), `cpu_profiling_test` or `dhat_profiling_test`
  (`profiling.yml` runs those two).
- To run one test case:
  `cargo test --locked --lib config::models::tests::test_backward_compatible_deserialization -- --exact`
  or `cargo test --locked --test integration_tests test_config_persistence_integration -- --exact --test-threads=1`.
- On macOS or Linux, plain `cargo clippy` or `cargo test` compiles only the `#[cfg(not(windows))]`
  stubs, so the real code goes unchecked. To lint the Windows code, run
  `cargo xwin clippy --locked --target x86_64-pc-windows-msvc --all-targets --all-features -- -D warnings`.
  This is what `prek.toml` runs on non-Windows hosts, and it needs cargo-xwin installed.
- The required Miri job (`.github/workflows/miri.yml`, Linux, pinned nightly) runs
  `cargo miri test --locked --lib error -- --test-threads=1`. `error` is a substring filter, so it
  matches every lib test whose path contains "error": all of `error::tests` and the
  `hdr::controller::tests::test_error_handling_*` tests. Keep those tests free of FFI and other
  operations Miri doesn't support, or leave "error" out of new test names.

## Platform stubs and lints

- Code behind `#[cfg(windows)]` needs a `#[cfg(not(windows))]` counterpart with the same signature.
  Without it, the Linux Miri job and non-Windows dev builds fail. The code uses two forms: twin
  functions with `_`-prefixed parameters (`src/gui/gui_controller.rs`), or one
  function with an inner `#[cfg(windows)] { .. }` block and an inner `#[cfg(not(windows))] { .. }`
  block (`src/hdr/controller.rs`, `src/monitor/process_monitor.rs`).
- Clippy runs with `-D warnings`, and `Cargo.toml` enables `pedantic`, `missing_docs`, `unsafe_code`
  and `unwrap_used`. So every `pub` item needs a doc comment. To silence a lint, write
  `#[expect(<lint>, reason = "...")]`, not `#[allow]`. An `expect` that never fires is itself a
  warning, so a lint that fires on only one platform needs `cfg_attr`. From
  `src/monitor/process_monitor.rs`:

```rust
#[cfg_attr(
    windows,
    expect(
        unsafe_code,
        reason = "Windows FFI for process enumeration via CreateToolhelp32Snapshot and Process32FirstW/NextW"
    )
)]
```

- Test modules opt out of `unwrap_used` with `#[expect(clippy::unwrap_used)]` on `mod tests`.

## Config compatibility (`src/config/models.rs`)

Users' existing `%APPDATA%\EasyHDR\config.json` files must keep loading. If parsing fails,
`ConfigManager::load` falls back to defaults, and the next save overwrites the user's apps.

- New `UserPreferences` fields need `#[serde(default)]` (or a named default function). Without it,
  older files fail to parse.
- `Serialize for MonitoredApp` is written by hand. A new field on `Win32App` or `UwpApp` must also
  be added to its `serialize_struct` calls, or the field is silently never written. The `Legacy`
  struct in the same file handles old entries that have no `app_type`.
- `Deserialize for AppConfig` is written by hand. A new top-level field needs a variant in its
  `Field` enum, an entry in `FIELDS` and a visitor arm. Otherwise the saved key fails the next
  load, because `Field` has no `#[serde(other)]` catch-all.

## Runtime invariants

- Add, remove and enable monitored apps only through `AppController::add_application`,
  `remove_application` and `toggle_app_enabled`. They save the config, refresh the `ProcessMonitor`
  watch list and push `AppState` to the GUI. Writing to `config.monitored_apps` directly never
  reaches the monitor.
- The settings dialog (`GuiController::save_settings`) changes `config.preferences` fields in place.
  This keeps `last_update_check_time` and `cached_latest_version`. Don't replace the whole struct
  from UI values: `AppController::update_preferences` replaces it and would wipe that update
  metadata.
- Only the Slint event-loop thread may touch `MainWindow`. Background threads send state through
  the `AppState` channel. `GuiController::run` forwards it to `ui_cmd_rx`, and a 50 ms
  `slint::Timer` drains that on the UI thread.
- Unit tests that touch config, icon-cache or log paths must wrap the test in
  `crate::test_utils::{AppdataGuard, create_test_dir}`. Otherwise they write to the real
  `%APPDATA%\EasyHDR`, or to `./EasyHDR` when `APPDATA` is unset. Integration tests can't reach
  `test_utils`; pass a `TempDir` to `IconCache::new` instead, as `tests/icon_cache_tests.rs` does.
- The CI smoke test (`.github/scripts/smoke-windows.ps1`) waits for a window titled `EasyHDR`
  (`ui/main.slint`) and for the log line `Starting GUI event loop` (`src/main.rs`) in
  `EasyHDR/app.log`. Renaming either one fails CI.

## Adding a user preference

Follow the pattern of commit `cbe6cfb` (`auto_open_release_page`):

1. `src/config/models.rs`: add the field to `UserPreferences` with `#[serde(default)]`, then set it
   in `impl Default for UserPreferences` and in the test struct literal.
2. Update the remaining `UserPreferences { .. }` literals. Find them with
   `grep -rn 'start_minimized_to_tray:' src tests benches`: `src/controller/app_controller.rs`
   tests, `tests/dhat_profiling_test.rs`, `benches/config.rs`, `benches/process_monitor_bench.rs`.
3. `ui/main.slint`: add an `in-out property` on `SettingsDialogContent` and a matching
   `settings-*` property on `MainWindow`, plus the `<=>` binding and a `StyledCheckBox`. Add the
   argument to every `save-settings(` occurrence (`grep -n 'save-settings(' ui/main.slint`): two
   callback declarations, the Save button call and the `MainWindow` forwarding handler.
4. `src/gui/gui_controller.rs`: call `set_settings_<name>` in `GuiController::new`, add the closure
   parameter in `on_save_settings`, add the parameter to both `save_settings` versions (Windows
   and stub), and assign the field in place.

## Dependencies and security

- `slint` (`[dependencies]`) and `slint-build` (`[build-dependencies]`) must be the same version.
  Renovate updates them as one group (`renovate.json`).
- To ignore a RustSec advisory, add it with a rationale comment to both `deny.toml` and
  `.cargo/audit.toml`. `security.yml` runs both `cargo deny` and `cargo audit`.
- `fuzz/` is a separate crate (nightly, cargo-fuzz) that uses the library's public API. No CI job
  builds it; run it with the commands in `README.md` under "Fuzzing".

## Git and PRs

- `prek.toml` blocks commits to `main` (`no-commit-to-branch`), so work on a branch.
- The CI hygiene job runs prek's built-in hooks across all files, including trailing whitespace,
  end-of-file and LF line endings.
- PRs need a Conventional Commit title and a `Signed-off-by` trailer that matches the author.
  `CI.md` covers the merge and Renovate policy; read it before changing workflows or dependency
  automation.

## Reference rules

- `.agents/rules/rust-1_98-core.md` holds generic Rust 1.98 guidance. It assumes tokio, axum, sqlx
  and nextest, none of which this repo uses; where it conflicts with this file, follow this file.
  Read it before writing substantial new Rust code.
