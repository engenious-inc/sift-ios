//
//  GenerateSSHKeys.swift
//
//
//  Created by AP on 9/9/23.
//

import Foundation

public enum GenerateSSHKeys {
    
    public static func generateEd25519KeysPair(outputPath: String? = nil) throws -> (privateKeyPath: String, publicKeyPath: String) {
        let outputPath = outputPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/sift_ed25519").path
        try? FileManager.default.removeItem(atPath: outputPath)
        try? FileManager.default.removeItem(atPath: outputPath + ".pub")
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["ssh-keygen", "-t", "ed25519", "-P", "", "-f", outputPath]
        try task.run()
        task.waitUntilExit()
        return (outputPath, outputPath + ".pub")
    }
}
