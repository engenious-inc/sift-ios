import Foundation

struct XCResultTool {
    enum FormatType: String {
        case raw = "raw"
        case json = "json"
    }
    
    enum ExportType: String {
        case file = "file"
        case directory = "directory"
    }
    
    let shell: ShellExecutor
    let xcresulttool = "xcrun xcresulttool "
    
    @discardableResult
    func export(id: String, outputPath: String, xcresultPath: String, type: ExportType) throws -> String {
        
        let fullCommand = xcresulttool + "export " +
                                      "--id \(id) " +
                                      "--output-path \(outputPath) " +
                                      "--path \(xcresultPath) " +
                                      "--type \(type.rawValue) "
        return try shell.run(fullCommand).output
    }
    
    @discardableResult
    func get(format: FormatType, id: String? = nil, xcresultPath: String) throws -> String {
        let unwrapedId = id != nil ? "--id \(id!) " : ""
        let fullCommand = xcresulttool + "get " +
                                      "--format \(format.rawValue) " +
                                      unwrapedId +
                                      "--path '\(xcresultPath)'"
        return try shell.run(fullCommand).output
    }
    
    @discardableResult
    func graph(id: String, xcresultPath: String) throws -> String {
        let fullCommand = xcresulttool + "graph " +
                                      "--id \(id) " +
                                      "--path \(xcresultPath)"
        return try shell.run(fullCommand).output
    }
    
    @discardableResult
    func merge(inputPaths: [String], outputPath: String) throws -> String {
        if inputPaths.isEmpty {
            throw NSError(domain: "No tests results", code: 1, userInfo: nil)
        }
        let fullCommand = xcresulttool + "merge " +
                                      inputPaths.map{"\"\($0)\""}.joined(separator: " ") +
                                      " --output-path \(outputPath)"
        return try shell.run(fullCommand).output
    }
}
