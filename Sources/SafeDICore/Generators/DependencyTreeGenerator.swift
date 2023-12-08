// Distributed under the MIT License
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Collections

public final class DependencyTreeGenerator {

    // MARK: Initialization

    public init(
        moduleNames: [String],
        typeDescriptionToFulfillingInstantiableMap: [TypeDescription: Instantiable]
    ) {
        self.moduleNames = moduleNames + ["SwiftUI", "UIKit"]
        self.typeDescriptionToFulfillingInstantiableMap = typeDescriptionToFulfillingInstantiableMap
    }

    // MARK: Public

    public func generate() async throws -> String {
        try validateReachableTypeDescriptions()

        let typeDescriptionToScopeMap = try createTypeDescriptionToScopeMapping()
        try validateUndeclaredReceivedProperties(typeDescriptionToScopeMap: typeDescriptionToScopeMap)
        let rootCombinedScopes = try rootInstantiableTypes
            .sorted()
            .compactMap { try typeDescriptionToScopeMap[$0]?.createCombinedScope() }

        let dependencyTree = try await withThrowingTaskGroup(
            of: String.self,
            returning: String.self
        ) { taskGroup in
            for rootCombinedScope in rootCombinedScopes {
                if rootCombinedScope.instantiable.dependencies.isEmpty {
                    // Nothing to do here! We already have an empty initializer.
                } else {
                    taskGroup.addTask {
                        try await """
                            extension \(rootCombinedScope.instantiable.concreteInstantiableType.asSource) {
                                \(rootCombinedScope.instantiable.isClass ? "@convenience " : "")init() {
                            \(rootCombinedScope.generateCode(leadingWhitespace: "        "))
                                    self.init(\(rootCombinedScope.instantiable.initializer.createInitializerArgumentList(given: rootCombinedScope.instantiable.dependencies)))
                                }
                            }
                            """
                    }
                }
            }
            var generatedCombinedScopes = [String]()
            for try await generatedCombinedScope in taskGroup {
                generatedCombinedScopes.append(generatedCombinedScope)
            }
            return generatedCombinedScopes.sorted().joined(separator: "\n\n")
        }

        return """
        // This file was generated by the SafeDIGenerateDependencyTree build tool plugin.
        // Any modifications made to this file will be overwritten on subsequent builds.
        // Please refrain from editing this file directly.

        \(imports)

        \(dependencyTree.isEmpty ? "// No root @\(InstantiableVisitor.macroName)-decorated types found." : dependencyTree)
        """
    }

    // MARK: - DependencyTreeGeneratorError

    enum DependencyTreeGeneratorError: Error, CustomStringConvertible {

        case noInstantiableFound(TypeDescription)
        case unfulfillableProperties([UnfulfillableProperty])

        var description: String {
            switch self {
            case let .noInstantiableFound(typeDescription):
                "No `@\(InstantiableVisitor.macroName)`-decorated type found to fulfill `@\(Dependency.Source.instantiated.rawValue)` or  `@\(Dependency.Source.lazyInstantiated.rawValue)`-decorated property with type `\(typeDescription.asSource)`"
            case let .unfulfillableProperties(unfulfillableProperties):
                """
                The following received properties were never instantiated:
                \(unfulfillableProperties.map {
                    """
                    `\($0.property.asSource)` is not instantiated in chain: \(([$0.instantiable] + $0.parentStack)
                    .reversed()
                    .map(\.concreteInstantiableType.asSource)
                    .joined(separator: " -> "))
                    """
                }.joined(separator: "\n"))
                """
            }
        }

        struct UnfulfillableProperty: Hashable, Comparable {
            static func < (lhs: DependencyTreeGenerator.DependencyTreeGeneratorError.UnfulfillableProperty, rhs: DependencyTreeGenerator.DependencyTreeGeneratorError.UnfulfillableProperty) -> Bool {
                lhs.property < rhs.property
            }

            let property: Property
            let instantiable: Instantiable
            let parentStack: [Instantiable]
        }
    }

    // MARK: Private

    private let moduleNames: [String]
    private let typeDescriptionToFulfillingInstantiableMap: [TypeDescription: Instantiable]

    private var imports: String {
        Set(moduleNames)
            .map { "import \($0)" }
            .sorted()
            .joined(separator: "\n")
    }

    /// A collection of `@Instantiable`-decorated types that do not explicitly receive dependencies.
    /// - Note: These are not necessarily roots in the build graph, since these types may be instantiated by another `@Instantiable`.
    private lazy var possibleRootInstantiableTypes: Set<TypeDescription> = Set(
        typeDescriptionToFulfillingInstantiableMap
            .values
            .filter(\.dependencies.areAllInstantiated)
            .map(\.concreteInstantiableType)
    )

    /// A collection of `@Instantiable`-decorated types that are instantiated by at least one other
    /// `@Instantiable`-decorated type or do not explicitly receive dependencies.
    private lazy var reachableTypeDescriptions: Set<TypeDescription> = {
        var reachableTypeDescriptions = Set<TypeDescription>()

        func recordReachableTypeDescription(_ reachableTypeDescription: TypeDescription) {
            guard !reachableTypeDescriptions.contains(reachableTypeDescription) else {
                // We've visited this tree already. Ignore.
                return
            }
            reachableTypeDescriptions.insert(reachableTypeDescription)
            guard let instantiable = typeDescriptionToFulfillingInstantiableMap[reachableTypeDescription] else {
                // We can't find an instantiable for this type.
                // This is bad, but we'll handle this error in `validateReachableTypeDescriptions()`.
                return
            }
            let reachableChildTypeDescriptions = instantiable
                .dependencies
                .filter(\.isInstantiated)
                .map(\.property.typeDescription.asInstantiatedType)
            for reachableChildTypeDescription in reachableChildTypeDescriptions {
                recordReachableTypeDescription(reachableChildTypeDescription)
            }
        }

        for reachableTypeDescription in possibleRootInstantiableTypes {
            recordReachableTypeDescription(reachableTypeDescription)
        }

        return reachableTypeDescriptions
    }()

    /// A collection of `@Instantiable`-decorated types that are instantiated by another
    /// `@Instantiable`-decorated type that is reachable in the dependency tree.
    private lazy var childInstantiableTypes: Set<TypeDescription> = Set(
        reachableTypeDescriptions
            .compactMap { typeDescriptionToFulfillingInstantiableMap[$0] }
            .flatMap(\.dependencies)
            .filter(\.isInstantiated)
            .map(\.property.typeDescription.asInstantiatedType)
    )

    /// A collection of `@Instantiable`-decorated types that are at the roots of their respective dependency trees.
    private lazy var rootInstantiableTypes: Set<TypeDescription> = possibleRootInstantiableTypes
        .subtracting(childInstantiableTypes)

    private func createTypeDescriptionToScopeMapping() throws -> [TypeDescription: Scope] {
        // Create the mapping.
        let typeDescriptionToScopeMap: [TypeDescription: Scope] = reachableTypeDescriptions
            .reduce(into: [TypeDescription: Scope](), { partialResult, typeDescription in
                guard let instantiable = typeDescriptionToFulfillingInstantiableMap[typeDescription] else {
                    // We can't find an instantiable for this type.
                    // This is bad, but we handle this error in `validateReachableTypeDescriptions()`.
                    return
                }
                guard partialResult[instantiable.concreteInstantiableType] == nil else {
                    // We've already created a scope for this `instantiable`. Skip.
                    return
                }
                let scope = Scope(instantiable: instantiable)
                for instantiableType in instantiable.instantiableTypes {
                    partialResult[instantiableType] = scope
                }
            })

        // Populate the propertiesToInstantiate on each scope.
        for scope in typeDescriptionToScopeMap.values {
            var additionalPropertiesToInstantiate = [Scope.PropertyToInstantiate]()
            for instantiatedProperty in scope.instantiable.instantiatedProperties {
                let instantiatedType = instantiatedProperty.typeDescription.asInstantiatedType
                guard
                    let instantiable = typeDescriptionToFulfillingInstantiableMap[instantiatedType],
                    let instantiatedScope = typeDescriptionToScopeMap[instantiatedType]
                else {
                    assertionFailure("Invalid state. Could not look up info for \(instantiatedProperty.typeDescription)")
                    continue
                }
                additionalPropertiesToInstantiate.append(Scope.PropertyToInstantiate(
                    property: instantiatedProperty,
                    instantiable: instantiable,
                    scope: instantiatedScope,
                    type: instantiatedProperty.nonLazyPropertyType
                ))
            }
            for instantiatedProperty in scope.instantiable.lazyInstantiatedProperties {
                let instantiatedType = instantiatedProperty.typeDescription.asInstantiatedType
                guard
                    let instantiable = typeDescriptionToFulfillingInstantiableMap[instantiatedType],
                    let instantiatedScope = typeDescriptionToScopeMap[instantiatedType]
                else {
                    assertionFailure("Invalid state. Could not look up info for \(instantiatedProperty.typeDescription)")
                    continue
                }

                additionalPropertiesToInstantiate.append(Scope.PropertyToInstantiate(
                    property: instantiatedProperty,
                    instantiable: instantiable,
                    scope: instantiatedScope,
                    type: .lazy
                ))
            }
            scope.propertiesToInstantiate.append(contentsOf: additionalPropertiesToInstantiate)
        }
        return typeDescriptionToScopeMap
    }

    private func validateUndeclaredReceivedProperties(typeDescriptionToScopeMap: [TypeDescription: Scope]) throws {
        var unfulfillableProperties = Set<DependencyTreeGeneratorError.UnfulfillableProperty>()
        func propagateUndeclaredReceivedProperties(
            on scope: Scope,
            receivableProperties: Set<Property>,
            instantiables: OrderedSet<Instantiable>
        ) {
            for receivedProperty in scope.receivedProperties {
                let parentContainsProperty = receivableProperties.contains(receivedProperty)
                if !parentContainsProperty {
                    unfulfillableProperties.insert(.init(
                        property: receivedProperty,
                        instantiable: scope.instantiable,
                        parentStack: instantiables.elements)
                    )
                }
            }

            for childScope in scope.propertiesToInstantiate.map(\.scope) {
                guard !instantiables.contains(childScope.instantiable) else {
                    // We've previously visited this child scope.
                    // There is a cycle in our scope tree. Do not re-enter it.
                    continue
                }
                
                var instantiables = instantiables
                instantiables.insert(scope.instantiable, at: 0)

                propagateUndeclaredReceivedProperties(
                    on: childScope,
                    receivableProperties: receivableProperties.union(scope.properties),
                    instantiables: instantiables
                )
            }
        }

        for rootScope in rootInstantiableTypes.compactMap({ typeDescriptionToScopeMap[$0] }) {
            propagateUndeclaredReceivedProperties(
                on: rootScope,
                receivableProperties: Set(rootScope.properties),
                instantiables: []
            )
        }

        if !unfulfillableProperties.isEmpty {
            throw DependencyTreeGeneratorError.unfulfillableProperties(unfulfillableProperties.sorted())
        }
    }

    private func validateReachableTypeDescriptions() throws {
        for reachableTypeDescription in reachableTypeDescriptions {
            if typeDescriptionToFulfillingInstantiableMap[reachableTypeDescription] == nil {
                throw DependencyTreeGeneratorError.noInstantiableFound(reachableTypeDescription)
            }
        }
    }
}

// MARK: - Dependency

extension Dependency {
    fileprivate var isInstantiated: Bool {
        switch source {
        case .instantiated, .lazyInstantiated:
            return true
        case .forwarded, .received:
            return false
        }
    }
}

// MARK: - Array

extension Array where Element == Dependency {
    fileprivate var areAllInstantiated: Bool {
        first(where: { !$0.isInstantiated }) == nil
    }
}