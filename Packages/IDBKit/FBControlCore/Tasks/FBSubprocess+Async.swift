/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

// MARK: - Public API
//
// This is written as a standalone function because Swift does not allow
// extension methods on generic Objective-C classes to access the class's
// generic parameters. `FBProcessBuilder<StdInType, StdOutType, StdErrType>` is
// such a class.

/// Builds and starts the process described by `builder` and returns the
/// spawned `FBSubprocess`.
///
/// Async wrapper around `-[FBProcessBuilder start]`.
public func awaitStart<StdIn, StdOut, StdErr>(
  of builder: FBProcessBuilder<StdIn, StdOut, StdErr>
) async throws -> FBSubprocess<StdIn, StdOut, StdErr> {
  try await bridgeFBFuture(builder.start())
}
