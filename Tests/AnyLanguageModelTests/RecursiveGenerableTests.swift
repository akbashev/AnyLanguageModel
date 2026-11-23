import Foundation
import Testing

@testable import AnyLanguageModel

/// A type that holds itself has a schema: where it holds itself, the schema refers to its definition.
@Suite("Recursive Generable types")
struct RecursiveGenerableTests {
    @Generable
    struct Folder {
        var name: String
        var folders: [Folder]
    }

    @Generable
    enum Piece {
        case text(words: String)
        case row(items: [Piece])
    }

    @Generable
    struct Author {
        var name: String
        var books: [Book]
    }

    @Generable
    struct Book {
        var title: String
        var authors: [Author]
    }

    @Generable
    struct Shelf {
        var folders: [Folder]
        var more: [Folder]
    }

    @Test func aTypeHoldingItselfRefersToItsDefinition() throws {
        let schema = Folder.generationSchema
        let name = String(reflecting: Folder.self)
        #expect(schema.root == .ref(name))
        guard case .object(let object) = schema.defs[name] else {
            Issue.record("No definition of \(name)")
            return
        }
        guard case .array(let folders) = object.properties["folders"] else {
            Issue.record("`folders` isn't an array")
            return
        }
        #expect(folders.items == .ref(name))
        #expect(schema.defs.count == 1)
    }

    @Test func anEnumerationHoldingItselfRefersToItsDefinition() throws {
        let schema = Piece.generationSchema
        let name = String(reflecting: Piece.self)
        #expect(schema.root == .ref(name))
        guard case .object(let row) = schema.defs["\(name).DiscriminatedRow"] else {
            Issue.record("No definition of the row case in \(schema.defs.keys.sorted())")
            return
        }
        guard case .array(let items) = row.properties["items"] else {
            Issue.record("`items` isn't an array")
            return
        }
        #expect(items.items == .ref(name))
        // Each case is defined once, by its own name.
        #expect(Set(schema.defs.keys) == [name, "\(name).DiscriminatedText", "\(name).DiscriminatedRow"])
    }

    @Test func typesHoldingEachOtherReferToTheirDefinitions() throws {
        let author = String(reflecting: Author.self)
        let book = String(reflecting: Book.self)
        for schema in [Author.generationSchema, Book.generationSchema] {
            #expect(Set(schema.defs.keys) == [author, book])
            guard case .object(let authorObject) = schema.defs[author],
                case .array(let books) = authorObject.properties["books"],
                case .object(let bookObject) = schema.defs[book],
                case .array(let authors) = bookObject.properties["authors"]
            else {
                Issue.record("Definitions aren't whole: \(schema)")
                return
            }
            #expect(books.items == .ref(book))
            #expect(authors.items == .ref(author))
        }
    }

    @Test func aTypeHeldTwiceIsDefinedOnce() throws {
        let schema = Shelf.generationSchema
        #expect(Set(schema.defs.keys) == [String(reflecting: Shelf.self), String(reflecting: Folder.self)])
    }

    @Test func itsSchemaIsEncodedWithItsDefinitionsAndReadBack() throws {
        let schema = Folder.generationSchema
        let data = try JSONEncoder().encode(schema)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("$defs"))
        #expect(try JSONDecoder().decode(GenerationSchema.self, from: data) == schema)
        // As a tool's parameters, it's its definition with the definitions beside it.
        let parameters = try (schema.withResolvedRoot() ?? schema).jsonValue(constantsAsEnums: true)
        guard case .object(let object) = parameters, case .object(let defs)? = object["$defs"] else {
            Issue.record("No definitions in \(parameters)")
            return
        }
        #expect(defs.count == 1)
        // Inlined, it would never end, which is said.
        #expect(throws: GenerationSchema.InliningError.recursiveReference(String(reflecting: Folder.self))) {
            try schema.inlinedJSONSchema()
        }
    }

    @Test func contentAsDeepAsItGoesMakesTheType() throws {
        let content = try GeneratedContent(
            json: #"{"name": "a", "folders": [{"name": "b", "folders": [{"name": "c", "folders": []}]}]}"#
        )
        let folder = try Folder(content)
        #expect(folder.folders.first?.folders.first?.name == "c")
        let piece = try Piece(
            try GeneratedContent(
                json: #"{"type": "row", "items": [{"type": "text", "words": "Hi"}, {"type": "row", "items": []}]}"#
            )
        )
        guard case .row(let items) = piece, case .text(let words) = items.first else {
            Issue.record("Not a row of a text: \(piece)")
            return
        }
        #expect(words == "Hi")
    }
}
