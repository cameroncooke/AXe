import Foundation

struct KeyEvent {
    let keyCode: Int
    let shift: Bool
    var option: Bool = false
}

extension KeyEvent {
    var stringForKeyCode: String {
        switch (keyCode, shift) {
            case (4, false): return "a"
            case (5, false): return "b"
            case (6, false): return "c"
            case (7, false): return "d"
            case (8, false): return "e"
            case (9, false): return "f"
            case (10, false): return "g"
            case (11, false): return "h"
            case (12, false): return "i"
            case (13, false): return "j"
            case (14, false): return "k"
            case (15, false): return "l"
            case (16, false): return "m"
            case (17, false): return "n"
            case (18, false): return "o"
            case (19, false): return "p"
            case (20, false): return "q"
            case (21, false): return "r"
            case (22, false): return "s"
            case (23, false): return "t"
            case (24, false): return "u"
            case (25, false): return "v"
            case (26, false): return "w"
            case (27, false): return "x"
            case (28, false): return "y"
            case (29, false): return "z"
            case (4, true): return "A"
            case (5, true): return "B"
            case (6, true): return "C"
            case (7, true): return "D"
            case (8, true): return "E"
            case (9, true): return "F"
            case (10, true): return "G"
            case (11, true): return "H"
            case (12, true): return "I"
            case (13, true): return "J"
            case (14, true): return "K"
            case (15, true): return "L"
            case (16, true): return "M"
            case (17, true): return "N"
            case (18, true): return "O"
            case (19, true): return "P"
            case (20, true): return "Q"
            case (21, true): return "R"
            case (22, true): return "S"
            case (23, true): return "T"
            case (24, true): return "U"
            case (25, true): return "V"
            case (26, true): return "W"
            case (27, true): return "X"
            case (28, true): return "Y"
            case (29, true): return "Z"
            case (30, false): return "1"
            case (31, false): return "2"
            case (32, false): return "3"
            case (33, false): return "4"
            case (34, false): return "5"
            case (35, false): return "6"
            case (36, false): return "7"
            case (37, false): return "8"
            case (38, false): return "9"
            case (39, false): return "0"
            case (40, false): return "\n"
            case (51, false): return ";"
            case (46, false): return "="
            case (54, false): return ","
            case (45, false): return "-"
            case (55, false): return "."
            case (56, false): return "/"
            case (53, false): return "`"
            case (47, false): return "["
            case (49, false): return "\\"
            case (48, false): return "]"
            case (52, false): return "'"
            case (44, false): return " "
            case (30, true): return "!"
            case (31, true): return "@"
            case (32, true): return "#"
            case (33, true): return "$"
            case (34, true): return "%"
            case (35, true): return "^"
            case (36, true): return "&"
            case (37, true): return "*"
            case (38, true): return "("
            case (39, true): return ")"
            case (45, true): return "_"
            case (46, true): return "+"
            case (47, true): return "{"
            case (48, true): return "}"
            case (51, true): return ":"
            case (52, true): return "\""
            case (49, true): return "|"
            case (54, true): return "<"
            case (55, true): return ">"
            case (56, true): return "?"
            case (53, true): return "~"
            default: return ""
        }
    }
    
    static func keyCodeForString(_ string: String) -> KeyEvent {
        guard let character = string.first, string.count == 1 else { return KeyEvent(keyCode: 0, shift: false) }
        
        switch String(character) {
            case "a": return KeyEvent(keyCode: 4, shift: false)
            case "b": return KeyEvent(keyCode: 5, shift: false)
            case "c": return KeyEvent(keyCode: 6, shift: false)
            case "d": return KeyEvent(keyCode: 7, shift: false)
            case "e": return KeyEvent(keyCode: 8, shift: false)
            case "f": return KeyEvent(keyCode: 9, shift: false)
            case "g": return KeyEvent(keyCode: 10, shift: false)
            case "h": return KeyEvent(keyCode: 11, shift: false)
            case "i": return KeyEvent(keyCode: 12, shift: false)
            case "j": return KeyEvent(keyCode: 13, shift: false)
            case "k": return KeyEvent(keyCode: 14, shift: false)
            case "l": return KeyEvent(keyCode: 15, shift: false)
            case "m": return KeyEvent(keyCode: 16, shift: false)
            case "n": return KeyEvent(keyCode: 17, shift: false)
            case "o": return KeyEvent(keyCode: 18, shift: false)
            case "p": return KeyEvent(keyCode: 19, shift: false)
            case "q": return KeyEvent(keyCode: 20, shift: false)
            case "r": return KeyEvent(keyCode: 21, shift: false)
            case "s": return KeyEvent(keyCode: 22, shift: false)
            case "t": return KeyEvent(keyCode: 23, shift: false)
            case "u": return KeyEvent(keyCode: 24, shift: false)
            case "v": return KeyEvent(keyCode: 25, shift: false)
            case "w": return KeyEvent(keyCode: 26, shift: false)
            case "x": return KeyEvent(keyCode: 27, shift: false)
            case "y": return KeyEvent(keyCode: 28, shift: false)
            case "z": return KeyEvent(keyCode: 29, shift: false)
            case "A": return KeyEvent(keyCode: 4, shift: true)
            case "B": return KeyEvent(keyCode: 5, shift: true)
            case "C": return KeyEvent(keyCode: 6, shift: true)
            case "D": return KeyEvent(keyCode: 7, shift: true)
            case "E": return KeyEvent(keyCode: 8, shift: true)
            case "F": return KeyEvent(keyCode: 9, shift: true)
            case "G": return KeyEvent(keyCode: 10, shift: true)
            case "H": return KeyEvent(keyCode: 11, shift: true)
            case "I": return KeyEvent(keyCode: 12, shift: true)
            case "J": return KeyEvent(keyCode: 13, shift: true)
            case "K": return KeyEvent(keyCode: 14, shift: true)
            case "L": return KeyEvent(keyCode: 15, shift: true)
            case "M": return KeyEvent(keyCode: 16, shift: true)
            case "N": return KeyEvent(keyCode: 17, shift: true)
            case "O": return KeyEvent(keyCode: 18, shift: true)
            case "P": return KeyEvent(keyCode: 19, shift: true)
            case "Q": return KeyEvent(keyCode: 20, shift: true)
            case "R": return KeyEvent(keyCode: 21, shift: true)
            case "S": return KeyEvent(keyCode: 22, shift: true)
            case "T": return KeyEvent(keyCode: 23, shift: true)
            case "U": return KeyEvent(keyCode: 24, shift: true)
            case "V": return KeyEvent(keyCode: 25, shift: true)
            case "W": return KeyEvent(keyCode: 26, shift: true)
            case "X": return KeyEvent(keyCode: 27, shift: true)
            case "Y": return KeyEvent(keyCode: 28, shift: true)
            case "Z": return KeyEvent(keyCode: 29, shift: true)
            case "1": return KeyEvent(keyCode: 30, shift: false)
            case "2": return KeyEvent(keyCode: 31, shift: false)
            case "3": return KeyEvent(keyCode: 32, shift: false)
            case "4": return KeyEvent(keyCode: 33, shift: false)
            case "5": return KeyEvent(keyCode: 34, shift: false)
            case "6": return KeyEvent(keyCode: 35, shift: false)
            case "7": return KeyEvent(keyCode: 36, shift: false)
            case "8": return KeyEvent(keyCode: 37, shift: false)
            case "9": return KeyEvent(keyCode: 38, shift: false)
            case "0": return KeyEvent(keyCode: 39, shift: false)
            case "\n": return KeyEvent(keyCode: 40, shift: false)
            case ";": return KeyEvent(keyCode: 51, shift: false)
            case "=": return KeyEvent(keyCode: 46, shift: false)
            case ",": return KeyEvent(keyCode: 54, shift: false)
            case "-": return KeyEvent(keyCode: 45, shift: false)
            case ".": return KeyEvent(keyCode: 55, shift: false)
            case "/": return KeyEvent(keyCode: 56, shift: false)
            case "`": return KeyEvent(keyCode: 53, shift: false)
            case "[": return KeyEvent(keyCode: 47, shift: false)
            case "\\": return KeyEvent(keyCode: 49, shift: false)
            case "]": return KeyEvent(keyCode: 48, shift: false)
            case "'": return KeyEvent(keyCode: 52, shift: false)
            case " ": return KeyEvent(keyCode: 44, shift: false)
            case "!": return KeyEvent(keyCode: 30, shift: true)
            case "@": return KeyEvent(keyCode: 31, shift: true)
            case "#": return KeyEvent(keyCode: 32, shift: true)
            case "$": return KeyEvent(keyCode: 33, shift: true)
            case "%": return KeyEvent(keyCode: 34, shift: true)
            case "^": return KeyEvent(keyCode: 35, shift: true)
            case "&": return KeyEvent(keyCode: 36, shift: true)
            case "*": return KeyEvent(keyCode: 37, shift: true)
            case "(": return KeyEvent(keyCode: 38, shift: true)
            case ")": return KeyEvent(keyCode: 39, shift: true)
            case "_": return KeyEvent(keyCode: 45, shift: true)
            case "+": return KeyEvent(keyCode: 46, shift: true)
            case "{": return KeyEvent(keyCode: 47, shift: true)
            case "}": return KeyEvent(keyCode: 48, shift: true)
            case ":": return KeyEvent(keyCode: 51, shift: true)
            case "\"": return KeyEvent(keyCode: 52, shift: true)
            case "|": return KeyEvent(keyCode: 49, shift: true)
            case "<": return KeyEvent(keyCode: 54, shift: true)
            case ">": return KeyEvent(keyCode: 55, shift: true)
            case "?": return KeyEvent(keyCode: 56, shift: true)
            case "~": return KeyEvent(keyCode: 53, shift: true)
            default: return KeyEvent(keyCode: 0, shift: false)
        }
    }
}