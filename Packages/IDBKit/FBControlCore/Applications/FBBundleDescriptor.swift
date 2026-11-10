/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

@objc(FBBundleDescriptor)
public final class FBBundleDescriptor: NSObject, NSCopying, Sendable {

  @objc public let name: String
  @objc public let identifier: String
  @objc public let path: String
  @objc public let binary: FBBinaryDescriptor?

  // MARK: Initializers

  @objc
  public init(name: String, identifier: String, path: String, binary: FBBinaryDescriptor?) {
    self.name = name
    self.identifier = identifier
    self.path = path
    self.binary = binary
    super.init()
  }

  @objc(bundleFromPath:error:)
  public class func bundle(fromPath path: String) throws -> FBBundleDescriptor {
    return try bundleFromPath(path, fallbackIdentifier: false)
  }

  @objc(bundleWithFallbackIdentifierFromPath:error:)
  public class func bundleWithFallbackIdentifier(fromPath path: String) throws -> FBBundleDescriptor {
    return try bundleFromPath(path, fallbackIdentifier: true)
  }

  // MARK: NSCopying

  public func copy(with zone: NSZone? = nil) -> Any {
    return self
  }

  // MARK: NSObject

  public override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? FBBundleDescriptor, other.isMember(of: type(of: self)) else {
      return false
    }
    return other.name == name
      && other.path == path
      && other.identifier == identifier
      && (other.binary?.isEqual(binary) ?? (binary == nil))
  }

  public override var hash: Int {
    name.hash | path.hash | identifier.hash | (binary?.hash ?? 0)
  }

  public override var description: String {
    "Name: \(name) | ID: \(identifier)"
  }

  // MARK: Private

  private class func binaryForBundle(_ bundle: Bundle) throws -> FBBinaryDescriptor {
    guard let binaryPath = bundle.executablePath else {
      throw FBControlCoreError.describe("Could not obtain binary path for bundle \(bundle.bundlePath)").build()
    }
    return try FBBinaryDescriptor.binary(withPath: binaryPath)
  }

  private class func bundleNameForBundle(_ bundle: Bundle) -> String {
    return (bundle.infoDictionary?["CFBundleName"] as? String)
      ?? (bundle.infoDictionary?["CFBundleExecutable"] as? String)
      ?? ((bundle.bundlePath as NSString).deletingPathExtension as NSString).lastPathComponent
  }

  private class func bundleFromPath(_ path: String, fallbackIdentifier: Bool) throws -> FBBundleDescriptor {
    guard let bundle = Bundle(path: path) else {
      throw FBControlCoreError.describe("Failed to load bundle at path \(path)").build()
    }
    let bundleName = bundleNameForBundle(bundle)
    var identifier = bundle.bundleIdentifier
    if identifier == nil {
      if !fallbackIdentifier {
        throw FBControlCoreError.describe("Could not obtain Bundle ID for bundle '\((path as NSString).lastPathComponent)' at \(path)").build()
      }
      identifier = bundleName
    }
    let binary = try binaryForBundle(bundle)
    return FBBundleDescriptor(name: bundleName, identifier: identifier!, path: path, binary: binary)
  }
}
