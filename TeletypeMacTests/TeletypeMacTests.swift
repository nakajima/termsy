//
//  TeletypeMacTests.swift
//  TeletypeMacTests
//
//  Created by Pat Nakajima on 5/12/26.
//

import AppKit
@testable import Teletype
import Testing

private let rustCompilerErrorPastePayload = """
error[E0277]: `?` couldn't convert the error: `RefCell<std::option::Option<Vec<Build>>>: Sync` is not satisfied
   --> src/lib/syncer.rs:56:30
    |
 56 |                     .create()?
    |                      --------^ `RefCell<std::option::Option<Vec<Build>>>` cannot be shared between threads safely
    |                      |
    |                      this can't be annotated with `?` because it has type `Result<_, SaveError<App<seekwel::Invalid<NewRecord, AppColumns>>>>`
    |
    = help: within `SaveError<App<seekwel::Invalid<NewRecord, AppColumns>>>`, the trait `Sync` is not implemented for `RefCell<std::option::Option<Vec<Build>>>`
    = note: the question mark operation (`?`) implicitly performs a conversion on the error value using the `From` trait
note: required because it appears within the type `HasMany<Build, 0>`
   --> /home/nakajima/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/seekwel-0.1.16/src/model/association/has_many.rs:22:12
    |
 22 | pub struct HasMany<Child: Model, const ASSOC: u8> {
    |            ^^^^^^^
note: required because it appears within the type `App<seekwel::Invalid<NewRecord, AppColumns>>`
   --> src/models/app.rs:9:12
    |
  9 | pub struct App {
    |            ^^^
note: required because it appears within the type `SaveError<App<seekwel::Invalid<NewRecord, AppColumns>>>`
   --> /home/nakajima/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/seekwel-0.1.16/src/model/validation.rs:179:10
    |
179 | pub enum SaveError<M> {
    |          ^^^^^^^^^
    = note: required for `anyhow::Error` to implement `From<SaveError<App<seekwel::Invalid<NewRecord, AppColumns>>>>`
"""

struct TeletypeMacTests {
	/// Regression test for a freeze observed when pasting a multi-line Rust compiler error
	/// (~1.6 KB). Smaller pastes work; larger pastes hang the terminal - display stops
	/// updating, keystrokes stop reaching the shell.
	///
	/// Diagnosis: `MacGhosttyApp.readClipboard`'s C callback used `DispatchQueue.main.sync`
	/// when invoked from a non-main thread. If ghostty calls that callback from a worker
	/// thread while the main thread is blocked inside `ghostty_surface_binding_action`
	/// (which is plausible for larger paste payloads where ghostty's parser spawns work),
	/// the worker waits for main, main waits for the binding action to return, and we
	/// deadlock. The display Timer can't fire (main blocked) and NSEvent processing stops.
	///
	/// This test exercises that exact pattern: invoke the clipboard read from a worker
	/// thread while main is synchronously busy (in a usleep loop that doesn't drain the
	/// run loop). If the production code uses `DispatchQueue.main.sync`, the worker hangs
	/// forever and the time limit catches it.
	@MainActor
	@Test(.timeLimit(.minutes(1)))
	func clipboardReadFromWorkerThreadDoesNotBlockOnBusyMain() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(rustCompilerErrorPastePayload, forType: .string)

		let result = LockedString()
		let completed = LockedBool()

		DispatchQueue.global(qos: .userInitiated).async {
			let s = MacClipboardBridge.readClipboardStringMirroringProduction()
			result.set(s)
			completed.set(true)
		}

		// Block main synchronously - runloop does not spin. If
		// readClipboardStringMirroringProduction uses DispatchQueue.main.sync, the worker
		// is now waiting for main, which is stuck in this usleep loop. Deadlock.
		// This mirrors the production scenario where ghostty calls readClipboard from a
		// worker thread while main is inside ghostty_surface_binding_action for a paste.
		let deadline = Date().addingTimeInterval(2.0)
		while !completed.get(), Date() < deadline {
			usleep(2000)
		}

		#expect(completed.get(), "worker hung - DispatchQueue.main.sync deadlock against busy main")
		#expect(result.get() == rustCompilerErrorPastePayload)
	}
}

private final class LockedBool: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
	func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LockedString: @unchecked Sendable {
	private let lock = NSLock()
	private var value: String?
	func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
	func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
