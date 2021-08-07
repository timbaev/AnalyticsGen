import Foundation

final class StencilStringWordModificator: StencilStringModificator {

    // MARK: - Nested Types

    typealias Input = String
    typealias Output = String
    typealias StringModificatorOuput = String

    // MARK: - Instance Properties

    let name = "upperWord"

    // MARK: - Instance Methods

    func modify(string: String, withArguments arguments: [Any?]) throws -> String {
        guard let word = arguments.first as? String else {
            return string
        }

        return string.replacingOccurrences(of: word, with: word.uppercased(), options: .caseInsensitive)
    }
}
