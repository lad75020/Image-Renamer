//
//  Item.swift
//  Image Renamer
//
//  Created by Laurent Dubertrand on 29/12/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
