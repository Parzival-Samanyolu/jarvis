import Foundation
@testable import JarvisCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String = "", line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL line \(line): \(msg())") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: Int = #line) {
    if a == b { passes += 1 } else { failures += 1; print("FAIL line \(line): \(a) != \(b) \(msg)") }
}

runSafetyTests()
runSecretTests()
if CommandLine.arguments.contains("--make-voiceprint") {   // test helper: enrol a synthetic voice into $JARVIS_HOME (set it, or this overwrites the real voiceprint)
    guard ProcessInfo.processInfo.environment["JARVIS_HOME"] != nil else { print("set JARVIS_HOME first"); exit(1) }
    let vp = try! Voiceprint()
    let t = "The quick brown fox jumps over the lazy dog while the sun sets slowly behind the mountains in the distance."
    try! vp.enrol(samples: synth(t + " " + t + " " + t, voice: "Daniel"), mic: "Synthetic")
    print("enrolled"); exit(0)
}
runCoreTests()
runLinesTests(); runSplitterTests()
do { try runAssemblerTests() } catch { failures += 1; print("FAIL assembler threw \(error)") }
do { let sem = DispatchSemaphore(value: 0); Task { await runLiveSpeechTests(); sem.signal() }; sem.wait() }
if CommandLine.arguments.contains("--ml") { runMLTests(); runVoiceprintProbe() }

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
