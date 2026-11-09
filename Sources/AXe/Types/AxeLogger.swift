import Foundation
import FBControlCore

final class AxeLogger: FBCompositeLogger {
    override init(loggers: [FBControlCoreLogger]) {
        super.init(loggers: loggers)
    }
    
    convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let systemLogger = FBControlCoreLoggerFactory.systemLoggerWriting(
            toStderr: writeToStdErr,
            withDebugLogging: debugLogging
        )
        self.init(loggers: [systemLogger])
    }
    
    override convenience init() {
        self.init(debugLogging: false, writeToStdErr: false)
    }
}
