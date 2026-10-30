import Foundation

extension UserDefaults {
    /// Decodes the value saved under `key`. When stored data exists but cannot be decoded (for example
    /// after a format change), it is copied to a backup key before returning `nil`, so the caller's next
    /// save cannot silently destroy the user's only copy.
    public func decodePreservingUnreadable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            backUpUnreadable(data, forKey: key)
            return nil
        }
    }

    public static func unreadableBackupKey(for key: String, index: Int = 0) -> String {
        index == 0 ? "\(key).unreadableBackup" : "\(key).unreadableBackup.\(index)"
    }

    private func backUpUnreadable(_ data: Data, forKey key: String) {
        var index = 0
        while let existing = self.data(forKey: Self.unreadableBackupKey(for: key, index: index)) {
            if existing == data { return }
            index += 1
        }
        set(data, forKey: Self.unreadableBackupKey(for: key, index: index))
    }
}
