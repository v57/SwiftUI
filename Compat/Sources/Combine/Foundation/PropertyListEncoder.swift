//
//  PropertyListEncoder.swift
//  
//
//  Created by Sergej Jaskiewicz on 10.12.2019.
//

import Foundation

// PropertyListEncoder and PropertyListDecoder are unavailable in 
// swift-corelibs-foundation prior to Swift 5.1.
#if canImport(Darwin) || swift(>=5.1)
extension PropertyListEncoder: TopLevelEncoder {
  public typealias Output = Data
}

extension PropertyListDecoder: TopLevelDecoder {
  public typealias Input = Data
}
#endif
