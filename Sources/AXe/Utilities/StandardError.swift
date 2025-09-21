import Foundation

// Stream that writes TextOutputStream data to stderr without extending FileHandle
struct StandardErrorStream: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

var standardError = StandardErrorStream()