import Foundation

private let formulaOperators: Set<Character> = ["+", "-", "*", "/"]

/// Check if the input string contains a formula (has operators, not just a plain number).
func isFormula(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("=") { return true }
    return trimmed.dropFirst().contains(where: { formulaOperators.contains($0) })
}

/// Parse a formula string (e.g., "=500.97+459.55" -> 960.52) or plain number.
/// Supports +, -, *, / with proper operator precedence.
/// Works with or without "=" prefix for mobile-friendly input.
func parseFormulaValue(_ input: String) -> Double {
    let trimmed = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
    guard !trimmed.isEmpty else { return 0 }

    let expr: String
    if trimmed.hasPrefix("=") {
        expr = String(trimmed.dropFirst()).replacingOccurrences(of: " ", with: "")
    } else {
        let hasOperators = trimmed.dropFirst().contains(where: { formulaOperators.contains($0) })
        if !hasOperators {
            return Double(trimmed) ?? 0
        }
        expr = trimmed.replacingOccurrences(of: " ", with: "")
    }

    guard !expr.isEmpty else { return 0 }

    var pos = expr.startIndex

    func parseNumber() -> Double {
        if pos < expr.endIndex && expr[pos] == "+" { pos = expr.index(after: pos) }
        let start = pos
        if pos < expr.endIndex && expr[pos] == "-" { pos = expr.index(after: pos) }
        while pos < expr.endIndex && (expr[pos].isNumber || expr[pos] == ".") {
            pos = expr.index(after: pos)
        }
        return Double(expr[start..<pos]) ?? 0
    }

    func parseTerm() -> Double {
        var result = parseNumber()
        while pos < expr.endIndex && (expr[pos] == "*" || expr[pos] == "/") {
            let op = expr[pos]
            pos = expr.index(after: pos)
            let right = parseNumber()
            result = op == "*" ? result * right : (right != 0 ? result / right : 0)
        }
        return result
    }

    func parseExpr() -> Double {
        var result = parseTerm()
        while pos < expr.endIndex && (expr[pos] == "+" || expr[pos] == "-") {
            let op = expr[pos]
            pos = expr.index(after: pos)
            let right = parseTerm()
            result = op == "+" ? result + right : result - right
        }
        return result
    }

    let result = parseExpr()
    return result.isFinite ? result : 0
}
