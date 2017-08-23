import Core
import Foundation

/// Serializes parsed Leaf ASTs into view bytes.
public final class Serializer {
    let ast: [Syntax]
    var context: Context
    let renderer: Renderer

    /// Creates a new Serializer.
    public init(ast: [Syntax], renderer: Renderer,  context: Context) {
        self.ast = ast
        self.context = context
        self.renderer = renderer
    }

    /// Serializes the AST into Bytes.
    func serialize() throws -> Future<Data> {
        var parts: [Future<DispatchData>] = []

        for syntax in ast {
            let promise = Promise(DispatchData.self)
            switch syntax.kind {
            case .raw(let data):
                promise.complete(data)
            case .tag(let name, let parameters, let body, let chained):
                try renderTag(name: name, parameters: parameters, body: body, chained: chained, source: syntax.source).then { context in
                    do {
                        guard let context = context else {
                            promise.complete(.empty)
                            return
                        }

                        guard let string = context.string else {
                            throw SerializerError.unexpectedSyntax(syntax)
                        }
                        guard let data = string.data(using: .utf8) else {
                            throw "could not convert string to data"
                        }
                        promise.complete(data.dispatchData)
                    } catch {
                        promise.complete(error)
                    }
                }
            default:
                throw SerializerError.unexpectedSyntax(syntax)
            }
            parts.append(promise.future)
        }
        
        let promise = Promise(Data.self)
        parts.resolved.then { data in
            var serialized = DispatchData.empty
            for chunk in data {
                serialized.append(chunk)
            }
            promise.complete(Data(serialized))
        }
        return promise.future
    }

    // MARK: private

    // renders a tag using the supplied context
    private func renderTag(name: String, parameters: [Syntax], body: [Syntax]?, chained: Syntax?, source: Source) throws -> Future<Context?> {
        guard let tag = renderer.tags[name] else {
            throw SerializerError.unknownTag(name: name, source: source)
        }

        var inputFutures: [Future<Context>] = []

        for parameter in parameters {
            let promise = Promise(Context.self)
            try resolveSyntax(parameter).then { input in
                promise.complete(input ?? .null)
            }
            inputFutures.append(promise.future)
        }

        let promise = Promise(Context?.self)

        inputFutures.resolved.then { inputs in
            do {
                let parsed = ParsedTag(name: name, parameters: inputs, body: body, source: source)
                try tag.render(
                    parsed: parsed,
                    context: &self.context,
                    renderer: self.renderer
                ).then { data in
                    do {
                        if let data = data {
                            promise.complete(data)
                        } else if let chained = chained {
                            switch chained.kind {
                            case .tag(let name, let params, let body, let c):
                                try self.renderTag(name: name, parameters: params, body: body, chained: c, source: chained.source).then { data in
                                    promise.complete(data)
                                }
                            default:
                                throw SerializerError.unexpectedSyntax(chained)
                            }
                        } else {
                            promise.complete(nil)
                        }
                    } catch {
                        promise.complete(error)
                    }
                }
            } catch {
                promise.complete(error)
            }
        }

        return promise.future
    }

    // resolves a constant to data
    private func resolveConstant(_ const: Constant) throws -> Future<Context> {
        let promise = Promise(Context.self)
        switch const {
        case .bool(let bool):
            promise.complete(.bool(bool))
        case .double(let double):
            promise.complete(.double(double))
        case .int(let int):
            promise.complete(.int(int))
        case .string(let ast):
            let serializer = Serializer(ast: ast, renderer: renderer, context: context)
            try serializer.serialize().then { bytes in
                guard let string = String(data: bytes, encoding: .utf8) else {
                    promise.complete("could not parse string" as Error)
                    return
                }
                promise.complete(.string(string))
            }
        }
        return promise.future
    }

    // resolves an expression to data
    private func resolveExpression(_ op: Operator, left: Syntax, right: Syntax) throws -> Future<Context> {
        let l = try resolveSyntax(left)
        let r = try resolveSyntax(right)

        let promise = Promise(Context.self)

        switch op {
        case .equal:
            l.then { l in
                r.then { r in
                    promise.complete(.bool(l == r))
                }
            }
        case .notEqual:
            l.then { l in
                r.then { r in
                    promise.complete(.bool(l != r))
                }
            }
        case .and:
            l.then { l in
                r.then { r in
                    promise.complete(.bool(l?.bool != false && r?.bool != false))
                }
            }
        case .or:
            r.then { r in
                l.then { l in
                    promise.complete(.bool(l?.bool != false || r?.bool != false))
                }
            }
        default:
            l.then { l in
                r.then { r in
                    if let leftDouble = l?.double, let rightDouble = r?.double {
                        switch op {
                        case .add:
                            promise.complete(.double(leftDouble + rightDouble))
                        case .subtract:
                            promise.complete(.double(leftDouble - rightDouble))
                        case .greaterThan:
                            promise.complete(.bool(leftDouble > rightDouble))
                        case .lessThan:
                            promise.complete(.bool(leftDouble < rightDouble))
                        case .multiply:
                            promise.complete(.double(leftDouble * rightDouble))
                        case .divide:
                            promise.complete(.double(leftDouble / rightDouble))
                        default:
                            promise.complete(.bool(false))
                        }
                    } else {
                        promise.complete(.bool(false))
                    }
                }
            }
        }

        return promise.future
    }

    // resolves syntax to data (or fails)
    private func resolveSyntax(_ syntax: Syntax) throws -> Future<Context?> {
        switch syntax.kind {
        case .constant(let constant):
            let promise = Promise(Context?.self)
            try resolveConstant(constant).then { data in
                promise.complete(data)
            }
            return promise.future
        case .expression(let op, let left, let right):
            let promise = Promise(Context?.self)
            try resolveExpression(op, left: left, right: right).then { data in
                promise.complete(data)
            }
            return promise.future
        case .identifier(let id):
            let promise = Promise(Context?.self)
            if let data = try contextFetch(path: id) {
                promise.complete(data)
            } else {
                promise.complete(.null)
            }
            return promise.future
        case .tag(let name, let parameters, let body, let chained):
            return try renderTag(name: name, parameters: parameters, body: body, chained: chained, source: syntax.source)
        case .not(let syntax):
            switch syntax.kind {
            case .identifier(let id):
                let promise = Promise(Context?.self)
                if let data = try contextFetch(path: id) {
                    if data.bool == true {
                        promise.complete(.bool(false))
                    } else {
                        promise.complete(.bool(true))
                    }
                } else {
                    promise.complete(.bool(true))
                }
                return promise.future
            case .constant(let c):
                let ret: Bool

                switch c {
                case .bool(let bool):
                    ret = !bool
                case .double(let double):
                    ret = double != 1
                case .int(let int):
                    ret = int != 1
                case .string(_):
                    throw SerializerError.unexpectedSyntax(syntax)
                }

                let promise = Promise(Context?.self)
                promise.complete(.bool(ret))
                return promise.future
            default:
                throw SerializerError.unexpectedSyntax(syntax)
            }
        default:
            throw SerializerError.unexpectedSyntax(syntax)
        }
    }

    // fetches data from the context
    private func contextFetch(path: [String]) throws -> Context? {
        var current = context

        for part in path {
            guard let sub = current.dictionary?[part] else {
                return nil
            }

            current = sub
        }

        return current
    }
}
