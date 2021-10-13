import Foundation
import PromiseKit
import Yams
import AnalyticsGenTools
import JSONSchema
import DictionaryCoder

final class DefaultEventGenerator: EventGenerator {

    // MARK: - Instance Properties

    let fileProvider: FileProvider
    let remoteRepoProvider: RemoteRepoProvider
    let templateRenderer: TemplateRenderer
    let dictionaryDecoder: DictionaryDecoder

    // MARK: - Initializers

    init(
        fileProvider: FileProvider,
        remoteRepoProvider: RemoteRepoProvider,
        templateRenderer: TemplateRenderer,
        dictionaryDecoder: DictionaryDecoder
    ) {
        self.fileProvider = fileProvider
        self.remoteRepoProvider = remoteRepoProvider
        self.templateRenderer = templateRenderer
        self.dictionaryDecoder = dictionaryDecoder
    }

    // MARK: - Instance Methods

    private func fetchGitReference(configuration: Configuration) throws -> Promise<GitReference?> {
        switch configuration.source {
        case .local:
            return .value(.none)

        case .gitHub(let gitHubConfiguration):
            return remoteRepoProvider
                .fetchReference(gitHubConfiguration: gitHubConfiguration)
                .asOptional()
        }
    }

    private func resolveSchemasPath(configuration: Configuration) throws -> Promise<URL> {
        switch configuration.source {
        case .local(let path):
            return .value(URL(fileURLWithPath: path))

        case .gitHub(let gitHubConfiguration):
            return remoteRepoProvider
                .fetchRepo(gitHubConfiguration: gitHubConfiguration)
                .map { path in
                    gitHubConfiguration.path.map { path.appendingPathComponent($0) } ?? path
                }
        }
    }

    private func clearDestinationFolder(at path: String) throws {
        let fileManager = FileManager.default

        try fileManager.contentsOfDirectory(atPath: path).forEach { filename in
            if filename.hasSuffix(".swift") {
                try fileManager.removeItem(atPath: path + "/" + filename)
            }
        }
    }

    private func generate(
        parameters: GenerationParameters,
        event: Event,
        schemaURL: URL,
        platform: EventPlatform
    ) throws {
        let filename = schemaURL.deletingPathExtension().lastPathComponent.deletingSuffix("event").camelized
        let screenShownDefaultParameters: [InternalEventParameter.KnownName?] = [.screenName, .hhtmSource, .hhtmFrom]

        if let internalEvent = event.internal, (internalEvent.platform ?? .androidIOS) == platform {
            if internalEvent.knownEventName == .screenShown,
               internalEvent.parameters.filter({ !screenShownDefaultParameters.contains($0.knownName) }).isEmpty {
                return
            }

            try templateRenderer.renderTemplate(
                parameters.render.internalTemplate,
                to: parameters.render.destination.appending(path: "\(filename)Event.swift"),
                context: InternalEventContext(
                    name: event.name,
                    description: event.description,
                    category: event.category,
                    eventName: internalEvent.event,
                    experiment: event.experiment.map {
                        InternalEventContext.Experiment(description: $0.description, url: $0.url.absoluteString)
                    },
                    structName: filename.appending("Event"),
                    parameters: internalEvent.parameters.nonEmpty?.map { parameter in
                        InternalEventContext.Parameter(
                            name: parameter.name,
                            description: parameter.description,
                            oneOf: parameter.type.oneOf,
                            const: parameter.type.const,
                            type: parameter.type.swiftType
                        )
                    },
                    hasParametersToInit: !internalEvent
                        .parameters
                        .filter { !$0.type.oneOf.isNil || !$0.type.swiftType.isNil }
                        .isEmpty
                )
            )
        }

        if let externalEvent = event.external, (externalEvent.platform ?? .androidIOS) == platform {
            try templateRenderer.renderTemplate(
                parameters.render.externalTemplate,
                to: parameters.render.destination.appending(path: "\(filename)ExternalEvent.swift"),
                context: ExternalEventContext(
                    name: event.name,
                    description: event.description,
                    category: event.category,
                    structName: filename.appending("ExternalEvent"),
                    action: ExternalEventContext.Action(
                        description: externalEvent.action.description,
                        value: externalEvent.action.value,
                        oneOf: externalEvent.action.oneOf
                    ),
                    label: externalEvent.label.map { label in
                        ExternalEventContext.Label(
                            description: label.description,
                            oneOf: label.oneOf
                        )
                    }
                )
            )
        }
    }

    private func generate(configuration: Configuration, schemasPath: URL, remoteGitReference: GitReference?) throws {
        guard let enumerator = FileManager.default.enumerator(at: schemasPath, includingPropertiesForKeys: nil) else {
            throw MessageError("Failed to create enumerator at \(schemasPath).")
        }

        let generarionParameters = try resolveGenerationParameters(from: configuration)
        let platform = configuration.platform ?? .androidIOS

        let events: [(Event, URL)] = try enumerator
            .lazy
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == .yamlExtension }
            .map { url in
                Log.info("Fetching schema: \(url.lastPathComponent)")

                let event: Event = try fileProvider.readFile(at: url.path)

                return (event, url)
            }

        try clearDestinationFolder(at: configuration.destination ?? "./")

        try events.forEach { event, url in
            try generate(parameters: generarionParameters, event: event, schemaURL: url, platform: platform)
        }

        if let reference = remoteGitReference {
            try fileProvider.writeFile(content: reference, at: .lockFilePath)
        }
    }

    // MARK: - EventGenerator

    func generate(configurationPath: String) -> Promise<EventGenerationResult> {
        firstly {
            fileProvider.readFile(at: configurationPath)
        }.then { configuration in
            try self.fetchGitReference(configuration: configuration).map { (configuration, $0) }
        }.then { configuration, remoteGitReference -> Promise<EventGenerationResult> in
            if let lockReference: GitReference = try self.fileProvider.readFileIfExists(at: .lockFilePath),
               let remoteGitReference = remoteGitReference {
                if lockReference == remoteGitReference {
                    return .value(.upToDate)
                }
            }

            return try self
                .resolveSchemasPath(configuration: configuration)
                .done {
                    try self.generate(
                        configuration: configuration,
                        schemasPath: $0,
                        remoteGitReference: remoteGitReference
                    )
                }
                .map { .success }
        }
    }
}

// MARK: - GenerationParametersResolving

extension DefaultEventGenerator: GenerationParametersResolving {

    // MARK: - Instance Properties

    var defaultInternalTemplateType: RenderTemplateType {
        .native(name: "InternalEvent")
    }

    var defaultExternalTemplateType: RenderTemplateType {
        .native(name: "ExternalEvent")
    }

    var defaultDestination: RenderDestination {
        .console
    }
}

// MARK: -

private extension RenderDestination {

    // MARK: - Instance Methods

    func appending(path: String) -> Self {
        switch self {
        case .file(let filePath):
            return .file(path: filePath.appending("/\(path)"))

        case .console:
            return self
        }
    }
}

// MARK: -

private extension String {

    // MARK: - Type Properties

    static let yamlExtension = "yaml"
    static let lockFilePath = ".analyticsGen.lock"
}
