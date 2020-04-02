import Foundation

enum Scripts {
    static func zip(workdirectory: String, zipName: String, files: [String?]) -> String {
        return "cd \(workdirectory)\n" +
                "zip -r -X -q -0 " +
                "\(zipName) " +
                files.compactMap {
                    guard let file = $0 else { return nil }
                    return "'\(file)'"
                }.joined(separator: " ")
    }
    
    static func dumpTests(path: String) -> String {
        return "nm -gU '\(path)' | cut -d' ' -f3 | xargs -s 131072 xcrun swift-demangle | cut -d' ' -f3 | grep -E \"[01-9a-zA-Z_\\.]+\\.test[01-9a-zA-Z_]+\\(\\)$\""
    }
}
