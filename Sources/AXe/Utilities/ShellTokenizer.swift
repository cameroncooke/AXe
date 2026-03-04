import Foundation

struct ShellTokenizer {
    enum TokenizerError: LocalizedError {
        case unterminatedSingleQuote
        case unterminatedDoubleQuote
        case danglingEscape

        var errorDescription: String? {
            switch self {
            case .unterminatedSingleQuote:
                return "Unterminated single quote in batch step."
            case .unterminatedDoubleQuote:
                return "Unterminated double quote in batch step."
            case .danglingEscape:
                return "Dangling escape sequence in batch step."
            }
        }
    }

    static func tokenize(_ line: String) throws -> [String] {
        enum State {
            case normal
            case singleQuote
            case doubleQuote
        }

        var tokens: [String] = []
        var current = ""
        var state: State = .normal
        var escaping = false
        var sawTokenBoundary = false

        func flushCurrentToken() {
            if !current.isEmpty || sawTokenBoundary {
                tokens.append(current)
            }
            current = ""
            sawTokenBoundary = false
        }

        var previousCharacter: Character?
        outer: for char in line {
            switch state {
            case .normal:
                if escaping {
                    current.append(char)
                    escaping = false
                    sawTokenBoundary = true
                    previousCharacter = char
                    continue
                }

                if char == "\\" {
                    escaping = true
                    previousCharacter = char
                    continue
                }

                if char == "'" {
                    state = .singleQuote
                    sawTokenBoundary = true
                    previousCharacter = char
                    continue
                }

                if char == "\"" {
                    state = .doubleQuote
                    sawTokenBoundary = true
                    previousCharacter = char
                    continue
                }

                if char == "#" {
                    let isCommentStart = previousCharacter == nil || previousCharacter?.isWhitespace == true
                    if isCommentStart {
                        break outer
                    }
                    current.append(char)
                    sawTokenBoundary = true
                    previousCharacter = char
                    continue
                }

                if char.isWhitespace {
                    if !current.isEmpty || sawTokenBoundary {
                        flushCurrentToken()
                    }
                    previousCharacter = char
                    continue
                }

                current.append(char)
                sawTokenBoundary = true

            case .singleQuote:
                if char == "'" {
                    state = .normal
                } else {
                    current.append(char)
                }
                sawTokenBoundary = true

            case .doubleQuote:
                if escaping {
                    current.append(char)
                    escaping = false
                    sawTokenBoundary = true
                    previousCharacter = char
                    continue
                }

                if char == "\\" {
                    escaping = true
                    previousCharacter = char
                    continue
                }

                if char == "\"" {
                    state = .normal
                } else {
                    current.append(char)
                }
                sawTokenBoundary = true
            }

            previousCharacter = char
        }

        if escaping {
            throw TokenizerError.danglingEscape
        }

        switch state {
        case .singleQuote:
            throw TokenizerError.unterminatedSingleQuote
        case .doubleQuote:
            throw TokenizerError.unterminatedDoubleQuote
        case .normal:
            break
        }

        if !current.isEmpty || sawTokenBoundary {
            flushCurrentToken()
        }

        return tokens
    }
}

