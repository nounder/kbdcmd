import Foundation


class SnippetManager {
    private var snippets: [String: () -> String] = [
        "tdf": {
            {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return df.string(from: Date())
            }()
        },
    ]
    
    func getExpansion(for key: String) -> String? {
        return snippets[key]?()
    }
    
    func hasSnippet(for key: String) -> Bool {
        return snippets.keys.contains(key)
    }
}
