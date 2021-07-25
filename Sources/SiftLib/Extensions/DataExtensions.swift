//
//  File.swift
//  
//
//  Created by AP on 7/25/21.
//

import Foundation

extension Data {
    
    func string(encoding: String.Encoding) -> String? {
        String(data: self, encoding: encoding)
    }
}
