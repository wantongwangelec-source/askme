import Foundation
import AskmeCore

/// Local learning log in Application Support. Owner-only file permissions; nothing is synced.
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var book = KnowledgeBook()
    private let url: URL?

    init(persistent: Bool = true) {
        guard persistent, let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            url = nil
            return
        }
        url = base.appendingPathComponent("Askme", isDirectory: true).appendingPathComponent("knowledge.json")
        load()
    }

    var dueCount: Int { book.due(at: Date()).count }

    func entry(for term: String) -> KnowledgeEntry? { book.entry(for: term) }

    @discardableResult
    func record(term: String, summary: String, source: String) -> KnowledgeEntry? {
        let entry = book.record(term: term, summary: summary, source: source, at: Date())
        save()
        return entry
    }

    func review(_ key: String, remembered: Bool) {
        book.review(key, remembered: remembered, at: Date())
        save()
    }

    func remove(_ key: String) {
        book.remove(key)
        save()
    }

    func removeAll() {
        book.removeAll()
        save()
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.knowledge.decode(KnowledgeBook.self, from: data) else { return }
        book = decoded
    }

    private func save() {
        guard let url else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder.knowledge.encode(book).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Askme: could not save the learning log (\(error.localizedDescription))")
        }
    }
}

private extension JSONEncoder {
    static var knowledge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var knowledge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
