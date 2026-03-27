import XCTest
@testable import EscapeMint

final class FormulaParserTests: XCTestCase {

    // MARK: - Plain Numbers

    func testPlainInteger() {
        XCTAssertEqual(parseFormulaValue("100"), 100, accuracy: 0.001)
    }

    func testPlainDecimal() {
        XCTAssertEqual(parseFormulaValue("1000.50"), 1000.50, accuracy: 0.001)
    }

    func testPlainZero() {
        XCTAssertEqual(parseFormulaValue("0"), 0, accuracy: 0.001)
    }

    func testPlainNegative() {
        XCTAssertEqual(parseFormulaValue("-50"), -50, accuracy: 0.001)
    }

    // MARK: - Comma-separated numbers

    func testCommaThousands() {
        XCTAssertEqual(parseFormulaValue("1,000.00"), 1000, accuracy: 0.001)
    }

    func testCommaMillions() {
        XCTAssertEqual(parseFormulaValue("1,234,567.89"), 1234567.89, accuracy: 0.01)
    }

    // MARK: - Formulas with = prefix

    func testFormulaAddition() {
        XCTAssertEqual(parseFormulaValue("=500+459.55"), 959.55, accuracy: 0.001)
    }

    func testFormulaMultiplication() {
        XCTAssertEqual(parseFormulaValue("=1000*2"), 2000, accuracy: 0.001)
    }

    func testFormulaDivision() {
        XCTAssertEqual(parseFormulaValue("=100/4"), 25, accuracy: 0.001)
    }

    func testFormulaSubtraction() {
        XCTAssertEqual(parseFormulaValue("=50-25"), 25, accuracy: 0.001)
    }

    // MARK: - Division by zero

    func testDivisionByZeroReturnsZero() {
        XCTAssertEqual(parseFormulaValue("=100/0"), 0, accuracy: 0.001)
    }

    // MARK: - Negative operands

    func testNegativeFirstOperand() {
        XCTAssertEqual(parseFormulaValue("=-50+10"), -40, accuracy: 0.001)
    }

    func testNegativeResult() {
        XCTAssertEqual(parseFormulaValue("=10-50"), -40, accuracy: 0.001)
    }

    // MARK: - Operator precedence

    func testOperatorPrecedenceMulBeforeAdd() {
        // 2 + 3*4 = 2 + 12 = 14
        XCTAssertEqual(parseFormulaValue("=2+3*4"), 14, accuracy: 0.001)
    }

    func testOperatorPrecedenceDivBeforeSub() {
        // 20 - 10/2 = 20 - 5 = 15
        XCTAssertEqual(parseFormulaValue("=20-10/2"), 15, accuracy: 0.001)
    }

    // MARK: - Empty and invalid input

    func testEmptyStringReturnsZero() {
        XCTAssertEqual(parseFormulaValue(""), 0, accuracy: 0.001)
    }

    func testEqualsOnlyReturnsZero() {
        XCTAssertEqual(parseFormulaValue("="), 0, accuracy: 0.001)
    }

    func testNonNumericStringReturnsZero() {
        XCTAssertEqual(parseFormulaValue("abc"), 0, accuracy: 0.001)
    }

    func testWhitespaceOnlyReturnsZero() {
        XCTAssertEqual(parseFormulaValue("   "), 0, accuracy: 0.001)
    }

    func testLeadingTrailingWhitespaceStripped() {
        XCTAssertEqual(parseFormulaValue("  100  "), 100, accuracy: 0.001)
    }

    // MARK: - isFormula boundary cases

    func testIsFormulaWithEqualsPrefix() {
        XCTAssertTrue(isFormula("=500+100"))
    }

    func testIsFormulaWithEqualsOnly() {
        XCTAssertTrue(isFormula("="))
    }

    func testIsFormulaPlainNumber() {
        XCTAssertFalse(isFormula("100"))
    }

    func testIsFormulaPlainDecimal() {
        XCTAssertFalse(isFormula("1000.50"))
    }

    func testIsFormulaLeadingNegativeIsNotFormula() {
        // "-50" has the minus at position 0; dropFirst() = "50" which has no operator
        XCTAssertFalse(isFormula("-50"))
    }

    func testIsFormulaInlineOperatorIsFormula() {
        // "50+10" has '+' after first char
        XCTAssertTrue(isFormula("50+10"))
    }

    func testIsFormulaEmptyString() {
        XCTAssertFalse(isFormula(""))
    }

    func testIsFormulaWhitespaceOnly() {
        XCTAssertFalse(isFormula("   "))
    }
}
