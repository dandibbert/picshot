import Foundation
import Security

// Packaging-time readback only. This does not execute the inspected helper.
guard CommandLine.arguments.count == 3 else { exit(64) }
let path = URL(fileURLWithPath: CommandLine.arguments[1])
let identifier = CommandLine.arguments[2]
var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { exit(65) }
var information: CFDictionary?
guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [String: Any],
      values[kSecCodeInfoIdentifier as String] as? String == identifier,
      let plist = values[kSecCodeInfoPList as String] as? [String: Any],
      plist["CFBundleIdentifier"] as? String == identifier,
      let output = try? JSONSerialization.data(withJSONObject: plist, options: [.sortedKeys]) else { exit(66) }
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data([10]))
