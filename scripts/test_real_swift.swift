import Foundation

let sourceCode = try! String(contentsOfFile: "mobile_gateway_ios/SmartGlassGateway/Services/G2ProtocolEncoder.swift")
// We can't easily compile just one file if it has dependencies, but G2ProtocolEncoder only uses Foundation.
// Let's copy it and add a print statement.
