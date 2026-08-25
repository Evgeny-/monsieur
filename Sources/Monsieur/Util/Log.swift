import OSLog

enum Log {
    private static let subsystem = "dev.enikiforov.monsieur"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let llm = Logger(subsystem: subsystem, category: "llm")
    static let insert = Logger(subsystem: subsystem, category: "insert")
}
