#if DEBUG

    import AppKit
    import Foundation

    /// The `quitevent` step of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for
    /// the grammar): the quit Apple Event the Dock, a logout or a shutdown sends, sent by the app
    /// to itself, and the reply it gets back.
    ///
    ///   quitevent    sends `kCoreEventClass`/`kAEQuitApplication` from a background thread and
    ///                waits for the reply (30 s), then logs
    ///                `BRANCH_ACTION quit event reply: <keyErrorNumber, or "none">` or
    ///                `BRANCH_ACTION quit event send failed: <error>`. The step does not wait for
    ///                the reply: the steps after it run while the quit is held, and a quit that
    ///                goes ahead may end the app first.
    ///
    /// **Targeted at the app's own Apple Event Mach port** (`AEGetRegisteredMachPort()`), never its
    /// pid or `kCurrentProcess`: sent that way the event is handled on the sending thread, where
    /// AppKit's handler answers −128 without asking anyone and `handleQuit`'s
    /// `MainActor.assumeIsolated` traps. Sent to the Mach port it arrives through the main run loop
    /// as the Dock's does (measured, A — the probe-route finding).
    extension DebugLaunchHooks {

        static func sendQuitEvent() {
            Thread.detachNewThread { sendQuitEventAndLogTheReply() }
        }

        /// On its own thread: blocks for the reply.
        nonisolated private static func sendQuitEventAndLogTheReply() {
            var port = AEGetRegisteredMachPort()
            guard
                let target = NSAppleEventDescriptor(
                    descriptorType: DescType(typeMachPort), bytes: &port, length: MemoryLayout.size(ofValue: port))
            else {
                logFromAnyThread("quit event send failed: no descriptor for the app's Mach port")
                return
            }
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            do {
                let reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
                let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)).map { "\($0.int32Value)" }
                logFromAnyThread("quit event reply: \(number ?? "none")")
            } catch {
                logFromAnyThread("quit event send failed: \(error)")
            }
        }

        /// `log`'s line, from a thread that is not the main one.
        nonisolated private static func logFromAnyThread(_ message: String) {
            FileHandle.standardError.write(Data("BRANCH_ACTION \(message)\n".utf8))
        }
    }

#endif
