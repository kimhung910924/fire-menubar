import AppKit

/// 시각이 찍힌 진단 로그. HANDOFF 0절 — "누른 뒤 무슨 일이 일어나는지 시각과 함께" 기록한다.
///
/// 평소에는 꺼져 있다. `diag.pressTrace`가 켜고, 결과는 `Application Support/Fire/trace.txt`.
/// 로그는 측정 기준점(`mark()`)부터의 경과 초로 찍는다 — 절대 시각은 상관관계를 읽기 어렵다.
@MainActor
enum Trace {

    static var enabled = false

    private static var startedAt = Date()

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fire", isDirectory: true)
            .appendingPathComponent("trace.txt")
    }

    /// 측정 시작. 기준점을 다시 잡고 파일을 비운다.
    static func begin(_ label: String) {
        enabled = true
        startedAt = Date()
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "=== \(Date()) \(label)\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func end() {
        log("trace", "끝")
        enabled = false
    }

    static func log(_ tag: String, _ message: @autoclosure () -> String = "") {
        guard enabled else { return }
        let t = Date().timeIntervalSince(startedAt)
        let line = String(format: "%8.3f  ", t)
            + tag.padding(toLength: max(14, tag.count), withPad: " ", startingAt: 0)
            + " " + message() + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
