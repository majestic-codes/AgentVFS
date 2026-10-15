//
//  Interpreter.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// The keys and indices that lead from the original input to a value. Paths that share a prefix
/// share its storage, so following a deep value costs one node per level.
struct JSONPath {
    private let last: PathNode?

    static var root: Self { Self(last: nil) }

    private init(last: PathNode?) {
        self.last = last
    }

    var count: Int { last?.count ?? 0 }

    func appending(_ component: JSONValue) -> Self {
        Self(last: PathNode(parent: last, component: component))
    }

    func appending(contentsOf tail: [JSONValue]) -> Self {
        tail.reduce(self) { path, component in path.appending(component) }
    }

    var components: [JSONValue] {
        var result = [JSONValue](repeating: .null, count: count)
        var node = last
        while let current = node {
            result[current.count - 1] = current.component
            node = current.parent
        }
        return result
    }
}

/// One component of a `JSONPath`, after the path to its parent.
private final class PathNode {
    var parent: PathNode?
    let component: JSONValue
    let count: Int

    init(parent: PathNode?, component: JSONValue) {
        self.parent = parent
        self.component = component
        count = (parent?.count ?? 0) + 1
    }

    /// Releases the chain of parents one by one, so a long path does not recurse once per node.
    deinit {
        var next = parent
        parent = nil
        while var node = next {
            next = nil
            guard isKnownUniquelyReferenced(&node) else { return }
            next = node.parent
            node.parent = nil
        }
    }
}

/// A value flowing through a filter. While paths are tracked (inside `path(f)`, assignments and
/// `del`), `path` is where the value sits in the original input, and `nil` marks a value that was
/// computed rather than found, which cannot be used as a path. `depth`, when known, is at least
/// how deeply the value nests (see `Interpreter.depth(of:)`).
struct Item {
    var value: JSONValue
    var path: JSONPath?
    var depth: Int?

    init(_ value: JSONValue, path: JSONPath? = nil, depth: Int? = nil) {
        self.value = value
        self.path = path
        self.depth = depth
    }

    /// The same value without its path.
    var detached: Self { Self(value, depth: depth) }
}

/// What one evaluation step runs against: its input, its scope and whether paths are tracked.
struct Frame {
    let input: Item
    let env: Env
    let tracking: Bool

    /// The same step on the plain input value, with path tracking off.
    var plain: Self { Self(input: input.detached, env: env, tracking: false) }
}

/// Receives each output. Returning `false` stops the generator that produced it.
typealias Sink = (Item) throws -> Bool

/// A run stopped by a limit of `JQ.Options` (steps, time, memory or nesting) or by cancellation.
/// `try` cannot catch it.
public struct JQAbort: Error, Sendable {
    /// Which limit stopped the run.
    public let message: String
}

/// `halt` and `halt_error`: the filter asked to stop with an exit status.
public struct JQHalt: Error, Sendable {
    /// The exit status asked for.
    public let exitCode: Int
    /// What `halt_error` prints, or `nil` for `halt`.
    public let message: JSONValue?
}

/// `break $label`, caught only by the label activation with the same id.
struct BreakSignal: Error {
    let id: Int
}

/// An error thrown downstream of a `try`, carried through it untouched.
struct Passthrough: Error {
    let id: Int
    let error: any Error
}

/// Lexical scope: a linked list of bindings.
final class Env {
    enum Binding {
        case variable(String, JSONValue)
        case function(FunctionDefinition)
        /// A filter argument, evaluated in the caller's scope.
        case closure(String, Expr, Env)
        /// Mutually visible definitions, such as the builtin library.
        case table([String: FunctionDefinition])
        case label(String, Int)
        case root
    }

    let parent: Env?
    let binding: Binding

    init(_ parent: Env?, _ binding: Binding) {
        self.parent = parent
        self.binding = binding
    }
}

/// Produces the inputs `input` and `inputs` read.
protocol InputSource: AnyObject {

    func next() throws -> JSONValue?
    /// The name of the input the last value came from, or `nil` before the first.
    var currentName: String? { get }
    /// The lines of that input read so far, as `input_line_number` reports them.
    var currentLine: Int { get }
}

final class Interpreter {
    var steps = 0
    let maxSteps: Int
    /// Time, memory and cancellation for this run.
    let budget: Budget
    /// Stack address when the interpreter was created, and how far below it evaluation may go.
    private let stackBase: UInt
    private let stackBudget: UInt
    private var nextID = 0
    let inputs: InputSource?
    /// Takes text written by `debug`, `stderr` and friends, and throws to stop the program.
    let message: (String) throws -> Void
    /// Compiled patterns by options and source. `NSRegularExpression` is the sanctioned NS exception,
    /// see `JQRegex`.
    var regexCache: [String: NSRegularExpression] = [:]

    /// Create the interpreter on the thread that will run it: the stack budget is measured from
    /// here, as three quarters of that thread's stack.
    init(maxSteps: Int, budget: Budget, inputs: InputSource?, message: @escaping (String) throws -> Void) {
        self.maxSteps = maxSteps
        self.budget = budget
        self.inputs = inputs
        self.message = message
        stackBase = Self.stackAddress()
        let stackSize = max(Thread.current.stackSize, 256 << 10)
        stackBudget = UInt(stackSize / 4 * 3)
    }

    @inline(never)
    private static func stackAddress() -> UInt {
        var marker = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
    }

    func newID() -> Int {
        nextID += 1
        return nextID
    }

    /// Counts one evaluation step. Every 64 steps it checks the time limit and cancellation,
    /// every 1024 the memory limit.
    func tick() throws {
        steps += 1
        if steps > maxSteps {
            throw JQAbort(message: "program exceeded the evaluation budget of \(maxSteps) steps")
        }
        if steps & 63 == 0 { try budget.check() }
        if steps & 1023 == 0 { try budget.checkMemory() }
    }

    /// Notes the memory a new value takes, so the footprint is measured soon after large values.
    func charge(_ value: JSONValue) throws {
        let bytes = Self.storageSize(value)
        if bytes > 0 { try budget.note(allocating: bytes) }
    }

    /// Bytes a value's own storage takes, without its elements' storage.
    static func storageSize(_ value: JSONValue) -> Int {
        switch value {
        case let .string(text): text.utf8.count
        case let .array(elements): elements.count * MemoryLayout<JSONValue>.stride
        case let .object(object): object.count * MemoryLayout<JSONValue>.stride * 3
        case .null, .bool, .number: 0
        }
    }

    // MARK: Nesting

    /// How deeply `item` nests: its known `depth`, or measured.
    func depth(of item: Item) throws -> Int {
        if let depth = item.depth { return depth }
        return try measureDepth(item.value)
    }

    /// How deeply `value` nests: 0 for a scalar, one more than its deepest element for an array or
    /// object. Visits every array and object in it, one evaluation step each, and stops past
    /// `Operations.maxDepth`.
    func measureDepth(_ value: JSONValue) throws -> Int {
        guard value.isContainer else { return 0 }
        try tick()
        var deepest = 1
        var levels: [(elements: [JSONValue], next: Int)] = [(value.elements, 0)]
        while let top = levels.indices.last {
            guard levels[top].next < levels[top].elements.count else {
                levels.removeLast()
                continue
            }
            let element = levels[top].elements[levels[top].next]
            levels[top].next += 1
            guard element.isContainer else { continue }
            try tick()
            levels.append((element.elements, 0))
            deepest = max(deepest, levels.count)
            if deepest > Operations.maxDepth { return deepest }
        }
        return deepest
    }

    /// `depth`, after checking that a value may nest that deeply. Values nested deeper than
    /// `Operations.maxDepth` would overflow the stack when they are released.
    func allowedDepth(_ depth: Int) throws -> Int {
        guard depth <= Operations.maxDepth else {
            throw JQError("Value nests too deeply (more than \(Operations.maxDepth) levels)")
        }
        return depth
    }

    // MARK: Lookup

    enum FunctionReference {
        case closure(Expr, Env)
        case function(FunctionDefinition, Env)
    }

    func lookupFunction(_ key: String, in env: Env) -> FunctionReference? {
        var current: Env? = env
        while let scope = current {
            switch scope.binding {
            case let .function(definition) where definition.key == key:
                return .function(definition, scope)
            case let .closure(name, expr, closureEnv) where name == key:
                return .closure(expr, closureEnv)
            case let .table(definitions):
                if let definition = definitions[key] { return .function(definition, scope) }
            default:
                break
            }
            current = scope.parent
        }
        return nil
    }

    func lookupVariable(_ name: String, in env: Env) -> JSONValue? {
        var current: Env? = env
        while let scope = current {
            if case let .variable(bound, value) = scope.binding, bound == name { return value }
            current = scope.parent
        }
        return nil
    }

    func lookupLabel(_ name: String, in env: Env) -> Int? {
        var current: Env? = env
        while let scope = current {
            if case let .label(bound, id) = scope.binding, bound == name { return id }
            current = scope.parent
        }
        return nil
    }

    // MARK: Evaluation

    /// Runs `expr` on `input`, passing each output to `sink`. `tracking` is true while paths are
    /// being collected. Returns `false` when the sink asked to stop.
    func eval(_ expr: Expr, _ input: Item, _ env: Env, _ tracking: Bool, _ sink: Sink) throws -> Bool {
        try tick()
        let here = Self.stackAddress()
        if here < stackBase, stackBase - here > stackBudget {
            throw JQAbort(message: "program nests too deeply (recursion or generators too deep for the stack)")
        }
        // Each case lives in its own function so that one level of evaluation needs little stack.
        let frame = Frame(input: input, env: env, tracking: tracking)
        return switch expr {
        case .identity: try sink(input)
        case .recurseAll: try recurseAll(input, tracking, sink)
        case let .literal(value): try sink(Item(value))
        case let .index(base, key, optional): try evalIndex(base, key, optional, frame, sink)
        case let .slice(base, start, end, optional): try evalSlice(base, (start, end), optional, frame, sink)
        case let .iterate(base, optional): try evalIterate(base, optional, frame, sink)
        case let .tryCatch(body, handler): try evalTry(body, handler, frame, sink)
        case let .pipe(first, second): try evalPipe(first, second, frame, sink)
        case let .comma(first, second): try evalComma(first, second, frame, sink)
        case let .negate(operand): try evalNegate(operand, frame, sink)
        case let .binary(binaryOperator, lhs, rhs): try evalBinary(binaryOperator, lhs, rhs, frame, sink)
        case let .logicalAnd(lhs, rhs): try evalLogic(and: true, lhs, rhs, frame, sink)
        case let .logicalOr(lhs, rhs): try evalLogic(and: false, lhs, rhs, frame, sink)
        case let .alternative(lhs, rhs): try evalAlternative(lhs, rhs, frame, sink)
        case let .assign(assignOperator, lhs, rhs): try assign(assignOperator, lhs, rhs, frame, sink)
        case let .ifThen(condition, then, otherwise): try evalIf(condition, then, otherwise, frame, sink)
        case let .reduce(fold): try evalReduce(fold, frame, sink)
        case let .foreach(fold, extract): try evalForeach(fold, extract, frame, sink)
        case let .functionDefinition(definition, rest): try evalDefinition(definition, rest, frame, sink)
        case let .call(name, arguments, _): try evalCall(name, arguments, frame, sink)
        case let .variable(name): try evalVariable(name, env, sink)
        case let .bind(source, patterns, body): try evalBind(source, patterns, body, frame, sink)
        case let .label(name, body): try evalLabel(name, body, frame, sink)
        case let .breakLabel(name): throw try breakSignal(name, env)
        case let .array(body): try evalArray(body, frame, sink)
        case let .object(entries): try buildObject(entries, 0, JSONObject(), frame.plain, sink)
        case let .string(parts, format): try evalString(parts, format, frame, sink)
        case let .format(name): try evalFormat(name, input, sink)
        }
    }
}
