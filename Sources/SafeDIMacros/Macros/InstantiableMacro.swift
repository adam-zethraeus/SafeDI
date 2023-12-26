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

import SafeDICore
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct InstantiableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext)
    throws -> [DeclSyntax]
    {
        if let fulfillingAdditionalTypesArgument = declaration.attributes.instantiableMacro?.fulfillingAdditionalTypes {
            if ArrayExprSyntax(fulfillingAdditionalTypesArgument) == nil {
                throw InstantiableError.fulfillingAdditionalTypesArgumentInvalid
            }
        }

        if
            let concreteDeclaration: ConcreteDeclSyntaxProtocol
                = ActorDeclSyntax(declaration)
                ?? ClassDeclSyntax(declaration)
                ?? StructDeclSyntax(declaration) {
            let visitor = InstantiableVisitor(declarationType: .concreteDecl)
            visitor.walk(concreteDeclaration)
            for diagnostic in visitor.diagnostics {
                context.diagnose(diagnostic)
            }

            guard visitor.dependencies.filter({ $0.source == .forwarded }).count <= 1 else {
                throw InstantiableError.tooManyForwardedProperties
            }

            let hasMemberwiseInitializerForInjectableProperties = visitor
                .initializers
                .contains(where: { $0.isValid(forFulfilling: visitor.dependencies) })
            guard hasMemberwiseInitializerForInjectableProperties else {
                if visitor.uninitializedPropertyNames.isEmpty {
                    return [
                        DeclSyntax(
                            Initializer.generateRequiredInitializer(for: visitor.dependencies)
                        )
                    ]
                } else {
                    var membersWithInitializer = declaration.memberBlock.members
                    membersWithInitializer.insert(
                        MemberBlockItemSyntax(
                            leadingTrivia: .newline,
                            decl: Initializer.generateRequiredInitializer(
                                for: visitor.dependencies,
                                andAdditionalPropertiesWithLabels: visitor.uninitializedPropertyNames
                            ),
                            trailingTrivia: .newline
                        ),
                        at: membersWithInitializer.startIndex
                    )
                    context.diagnose(Diagnostic(
                        node: Syntax(declaration.memberBlock),
                        error: FixableInstantiableError.missingRequiredInitializer,
                        changes: [
                            .replace(
                                oldNode: Syntax(declaration.memberBlock.members),
                                newNode: Syntax(membersWithInitializer))
                        ]
                    ))
                    return []
                }
            }
            return []

        } else if let extensionDeclaration = ExtensionDeclSyntax(declaration) {
            if extensionDeclaration.genericWhereClause != nil {
                var modifiedDeclaration = extensionDeclaration
                modifiedDeclaration.genericWhereClause = nil
                context.diagnose(Diagnostic(
                    node: node,
                    error: FixableInstantiableError.disallowedGenericWhereClause,
                    changes: [
                        .replace(
                            oldNode: Syntax(extensionDeclaration),
                            newNode: Syntax(modifiedDeclaration)
                        )
                    ]
                ))
            }

            let visitor = InstantiableVisitor(declarationType: .extensionDecl)
            visitor.walk(extensionDeclaration)
            for diagnostic in visitor.diagnostics {
                context.diagnose(diagnostic)
            }

            let initializersCount = visitor.initializers.count
            if initializersCount > 1 {
                throw InstantiableError.tooManyInstantiateMethods
            } else if initializersCount == 0 {
                let extendedTypeName = extensionDeclaration.extendedType.typeDescription.asSource
                var membersWithInitializer = declaration.memberBlock.members
                membersWithInitializer.insert(
                    MemberBlockItemSyntax(
                        leadingTrivia: .newline,
                        decl: FunctionDeclSyntax(
                            modifiers: DeclModifierListSyntax(
                                arrayLiteral: DeclModifierSyntax(
                                    name: TokenSyntax(
                                        TokenKind.keyword(.public),
                                        presence: .present
                                    ),
                                    trailingTrivia: .space
                                ),
                                DeclModifierSyntax(
                                    name: TokenSyntax(
                                        TokenKind.keyword(.static),
                                        presence: .present
                                    ),
                                    trailingTrivia: .space
                                )
                            ),
                            name: TokenSyntax(
                                TokenKind.identifier(InstantiableVisitor.instantiateMethodName),
                                leadingTrivia: .space,
                                presence: .present
                            ),
                            signature: FunctionSignatureSyntax(
                                parameterClause: FunctionParameterClauseSyntax(
                                    parameters: FunctionParameterListSyntax([])
                                ),
                                returnClause: ReturnClauseSyntax(
                                    arrow: .arrowToken(
                                        leadingTrivia: .space,
                                        trailingTrivia: .space
                                    ),
                                    type: IdentifierTypeSyntax(
                                        name: .identifier(extendedTypeName)
                                    )
                                )
                            ),
                            body: CodeBlockSyntax(
                                leadingTrivia: .newline,
                                statements: CodeBlockItemListSyntax([]),
                                trailingTrivia: .newline
                            )
                        ),
                        trailingTrivia: .newline
                    ),
                    at: membersWithInitializer.startIndex
                )
                context.diagnose(Diagnostic(
                    node: Syntax(extensionDeclaration.memberBlock.members),
                    error: FixableInstantiableError.missingRequiredInstantiateMethod(
                        typeName: extendedTypeName
                    ),
                    changes: [
                        .replace(
                            oldNode: Syntax(declaration.memberBlock.members),
                            newNode: Syntax(membersWithInitializer))
                    ]
                ))
            }
            return []
        } else {
            throw InstantiableError.decoratingIncompatibleType
        }
    }

    // MARK: - InstantiableError

    private enum InstantiableError: Error, CustomStringConvertible {
        case decoratingIncompatibleType
        case tooManyForwardedProperties
        case fulfillingAdditionalTypesArgumentInvalid
        case tooManyInstantiateMethods

        var description: String {
            switch self {
            case .decoratingIncompatibleType:
                "@\(InstantiableVisitor.macroName) must decorate an extension on a type or a class, struct, or actor declaration"
            case .tooManyForwardedProperties:
                "An @\(InstantiableVisitor.macroName) type must have at most one @\(Dependency.Source.forwarded.rawValue) property"
            case .fulfillingAdditionalTypesArgumentInvalid:
                "The argument `fulfillingAdditionalTypes` must be an inlined array"
            case .tooManyInstantiateMethods:
                "@\(InstantiableVisitor.macroName)-decorated extension must have a single `instantiate()` method"
            }
        }
    }
}
