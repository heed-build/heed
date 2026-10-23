import Foundation
import HeedCore
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Start work's smart guesses (`[start_work] smart_guesses`): Apple's on-device model, where the Mac has it. Everything
/// it decides is in HeedCore (`StartWorkForm.question`, `apply`); this only asks the model.
enum SmartGuesses {
    /// The advisor, or nil where the model cannot run: before macOS 26, on a Mac without Apple Intelligence, while it
    /// is off or its model is still downloading.
    static func advisor() -> (any StartWorkAdvisor)? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
                return FoundationModelsAdvisor()
            }
        #endif
        return nil
    }

    /// Whether the model can run here, as Settings says it.
    static var status: String {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return "Apple's on-device model is ready."
                case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence to use it."
                case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading."
                case .unavailable(.deviceNotEligible): return "This Mac cannot run Apple's on-device model."
                case .unavailable: return "Apple's on-device model is not available."
                }
            }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }
}

#if canImport(FoundationModels)
    /// Asks the on-device model one structured question per pause in typing: only the fields still open, the repo and
    /// prefix as fixed choices (a guided pattern makes generation fail, so the name is free text, cleaned afterwards).
    @available(macOS 26, *)
    struct FoundationModelsAdvisor: StartWorkAdvisor {
        /// What the prefixes mean, for those the defaults have; others go by their name.
        private static let meanings = [
            "feature": "new behaviour", "fix": "repairs a bug, a crash or something broken", "docs": "documentation",
            "chore": "maintenance, cleanup, renames", "bump": "dependency or version upgrades",
            "refactor": "restructuring without changing behaviour", "test": "tests", "perf": "speed or resource use",
        ]

        func prewarm() {
            LanguageModelSession().prewarm()
        }

        func advise(_ question: StartWorkQuestion) async throws -> StartWorkAdvice {
            var properties: [DynamicGenerationSchema.Property] = []
            // The name first: asked after the repo, the model copies a recent session's title.
            if question.asksName {
                properties.append(.init(
                    name: "name",
                    description: "A git branch name for this task: two to five lowercase words from the task, joined by "
                        + "hyphens, naming what changes",
                    schema: DynamicGenerationSchema(type: String.self)
                ))
            }
            if !question.prefixes.isEmpty {
                let kinds = question.prefixes
                    .map { prefix in Self.meanings[prefix].map { "\(prefix) = \($0)" } ?? prefix }
                properties.append(.init(
                    name: "prefix",
                    schema: DynamicGenerationSchema(
                        name: "Prefix", description: "The kind of change: " + kinds.joined(separator: "; "),
                        anyOf: question.prefixes
                    )
                ))
            }
            if question.asksRepo {
                properties.append(.init(
                    name: "repo",
                    schema: DynamicGenerationSchema(
                        name: "Repo", description: "The repository the task is done in",
                        anyOf: question.candidates.map(\.id)
                    )
                ))
                properties.append(.init(
                    name: "why", description: "Why the task belongs in that repository, in at most eight words",
                    schema: DynamicGenerationSchema(type: String.self)
                ))
            }
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "StartWork", properties: properties), dependencies: []
            )
            let session = LanguageModelSession(instructions: Self.instructions(question))
            let response = try await session.respond(
                to: "Task: \(question.prompt.prefix(1500))", schema: schema,
                // Temperature 0 rather than `samplingMode: .greedy`, which only Xcode 27's SDK has.
                options: GenerationOptions(temperature: 0)
            )
            let content = response.content
            func text(_ property: String) -> String? { try? content.value(String.self, forProperty: property) }
            return StartWorkAdvice(
                repo: question.asksRepo ? text("repo") : nil, why: question.asksRepo ? text("why") : nil,
                name: question.asksName ? text("name") : nil, prefix: question.prefixes.isEmpty ? nil : text("prefix")
            )
        }

        static func instructions(_ question: StartWorkQuestion) -> String {
            var lines = ["You help a developer start a coding task."]
            if question.asksRepo {
                lines.append("Repositories:")
                for candidate in question.candidates {
                    var line = "- \(candidate.id)"
                    if !candidate.about.isEmpty { line += ": \(candidate.about)" }
                    if !candidate.recent.isEmpty { line += " Recent work: \(candidate.recent.joined(separator: "; "))" }
                    lines.append(line)
                }
            }
            if question.asksName, !question.examples.isEmpty {
                lines.append(
                    "Branch names the developer used before, for their style only: "
                        + question.examples.joined(separator: ", ")
                )
            }
            return lines.joined(separator: "\n")
        }
    }
#endif
