import Foundation

/// Command-line parser, catalog introspection endpoint, and execution orchestrator for headless automation.
public enum CLIOrchestrator {
    
    /// Exports the full schema of supported routes, tools, metadata, and tuning parameters for external consumers
    /// (e.g. web playground, Windows parity harness) without requiring AST parsing.
    public static func catalog() -> [String: Any] {
        func formatToolsMap(_ tools: [String: [ToolKind]]) -> [String: [String]] {
            tools.mapValues { $0.map(\.rawValue) }
        }
        func mapToolProperties(_ propertyExtractor: (ToolKind) -> String?) -> [String: String] {
            Dictionary(
                uniqueKeysWithValues: ToolKind.allCases.compactMap { tool in
                    propertyExtractor(tool).map { (tool.rawValue, $0) }
                }
            )
        }
        
        return [
            "conversionMatrix": FeatureCatalog.allConversions,
            "sharedConversionMatrix": FeatureCatalog.conversionMatrix,
            "tools": ToolKind.allCases.map(\.rawValue),
            "singleTools": formatToolsMap(FeatureCatalog.singleTools),
            "multipleTools": formatToolsMap(FeatureCatalog.multipleTools),
            "macOnlySingleTools": formatToolsMap(FeatureCatalog.macOnlySingleTools),
            "macOnlyMultipleTools": formatToolsMap(FeatureCatalog.macOnlyMultipleTools),
            "toolNames": Dictionary(uniqueKeysWithValues: FeatureCatalog.toolNames.map { ($0.key.rawValue, $0.value) }),
            "editorTitles": mapToolProperties { $0.title },
            "editorHints": mapToolProperties { $0.editorHint },
            "saveTitles": mapToolProperties { $0.saveTitle },
            "categoryExtensions": Dictionary(
                uniqueKeysWithValues: FileCategory.knownExtensions.map { ($0.category.rawValue, $0.extensions) }
            ),
            "extensionAliases": FeatureCatalog.extensionAliases,
            "wheelFeedback": [
                "voices": Double(WheelAcousticTuning.voices),
                "volume": WheelAcousticTuning.volume,
                "minimumInterval": WheelAcousticTuning.minimumInterval,
            ],
        ]
    }

    /// Primary CLI entry point.
    public static func run(arguments args: [String] = CommandLine.arguments) -> Int32 {
        do {
            if args.count == 2, args[1] == "catalog" {
                let serialized = try JSONSerialization.data(
                    withJSONObject: catalog(),
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(decoding: serialized, as: UTF8.self))
                return 0
            }
            
            if args.count == 3, args[1] == "inspect" {
                let inputURL = URL(fileURLWithPath: args[2])
                let detectedCategory = FileCategory.detect(inputURL)
                var inspectionResult: [String: Any] = ["category": detectedCategory.rawValue]
                
                switch detectedCategory {
                case .image:
                    let loadedImage = try ImageEngine.load(inputURL)
                    inspectionResult["width"] = loadedImage.width
                    inspectionResult["height"] = loadedImage.height
                case .pdf:
                    let pdfDoc = try PDFEngine.open(inputURL)
                    inspectionResult["pages"] = pdfDoc.pageCount
                    inspectionResult["text"] = pdfDoc.string ?? ""
                case .audio, .video:
                    let mediaProperties = try MediaEngine.inspect(inputURL)
                    inspectionResult["duration"] = mediaProperties.duration
                    inspectionResult["hasAudio"] = mediaProperties.hasAudio
                    inspectionResult["hasVideo"] = mediaProperties.hasVideo
                    inspectionResult["width"] = mediaProperties.video?.width
                    inspectionResult["height"] = mediaProperties.video?.height
                    inspectionResult["channels"] = mediaProperties.audio?.channels
                default:
                    break
                }
                
                let jsonBytes = try JSONSerialization.data(withJSONObject: inspectionResult, options: .sortedKeys)
                print(String(decoding: jsonBytes, as: UTF8.self))
                return 0
            }
            
            if args.count == 2, args[1] == "dependencies" {
                var dependenciesMap: [String: String] = [:]
                for toolBinary in ["ffmpeg", "ffprobe", "soffice", "exiftool"] {
                    dependenciesMap[toolBinary] = try ExternalToolResolver.executable(toolBinary).path
                }
                let jsonBytes = try JSONSerialization.data(withJSONObject: dependenciesMap, options: .sortedKeys)
                print(String(decoding: jsonBytes, as: UTF8.self))
                return 0
            }
            
            guard args.count >= 4 else {
                print(
                    """
                    Usage: filevero-cli convert FORMAT FILE... [--options JSON]
                           filevero-cli tool TOOL_ID FILE... [--options JSON]
                           filevero-cli catalog
                    """
                )
                return 64
            }
            
            var options = OperationOptions()
            var operandPaths = Array(args.dropFirst(3))
            let formatAsJSON = operandPaths.contains("--json")
            operandPaths.removeAll { $0 == "--json" }
            
            if let optionsFlagIndex = operandPaths.firstIndex(of: "--options"), optionsFlagIndex + 1 < operandPaths.count {
                guard var suppliedDict = try JSONSerialization.jsonObject(with: Data(operandPaths[optionsFlagIndex + 1].utf8)) as? [String: Any] else {
                    throw FileveroError.invalidInput("Options must be a JSON object.")
                }
                
                canonicalizeFileURLs(&suppliedDict)
                var mergedDefaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
                
                let nestedStructures: [String: Data] = [
                    "imageMetadata": try JSONEncoder().encode(ImageMetadataOptions()),
                    "imageFrame": try JSONEncoder().encode(ImageFrameOptions()),
                    "imageRedaction": try JSONEncoder().encode(ImageRedactionOptions()),
                    "collage": try JSONEncoder().encode(CollageOptions()),
                ]
                for (nestedKey, defaultData) in nestedStructures where suppliedDict[nestedKey] is [String: Any] {
                    mergedDefaults[nestedKey] = try JSONSerialization.jsonObject(with: defaultData)
                }
                
                let finalPayload = mergeDictionaries(mergedDefaults, with: suppliedDict)
                options = try JSONDecoder().decode(OperationOptions.self, from: JSONSerialization.data(withJSONObject: finalPayload))
                operandPaths.removeSubrange(optionsFlagIndex...optionsFlagIndex + 1)
            }
            
            let requestedOperation: Operation
            if args[1] == "convert" {
                requestedOperation = .convert(args[2])
            } else if args[1] == "tool", let kind = ToolKind(rawValue: args[2]) {
                requestedOperation = .tool(kind)
            } else {
                throw FileveroError.invalidInput("Unknown operation.")
            }
            
            let generatedURLs = try ConversionEngine.run(
                ConversionRequest(
                    inputs: operandPaths.map { URL(fileURLWithPath: $0) },
                    operation: requestedOperation,
                    options: options
                )
            )
            
            if formatAsJSON {
                let serializedPaths = try JSONEncoder().encode(generatedURLs.map(\.path))
                print(String(decoding: serializedPaths, as: UTF8.self))
            } else {
                for url in generatedURLs {
                    print(url.path)
                }
            }
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func mergeDictionaries(_ base: [String: Any], with overrides: [String: Any]) -> [String: Any] {
        base.merging(overrides) { oldVal, newVal in
            if let nestedBase = oldVal as? [String: Any], let nestedOverride = newVal as? [String: Any] {
                return mergeDictionaries(nestedBase, with: nestedOverride)
            }
            return newVal
        }
    }

    private static func canonicalizeFileURLs(_ options: inout [String: Any]) {
        func resolveToURLString(_ value: Any?) -> Any? {
            guard let str = value as? String, URL(string: str)?.scheme == nil else { return value }
            return URL(fileURLWithPath: (str as NSString).expandingTildeInPath).absoluteString
        }
        
        for key in ["outputDirectory", "visualizationImage"] {
            if let val = options[key] { options[key] = resolveToURLString(val) }
        }
        for key in ["imageFrame", "collage"] {
            if var subDict = options[key] as? [String: Any], let val = subDict["backgroundImage"] {
                subDict["backgroundImage"] = resolveToURLString(val)
                options[key] = subDict
            }
        }
        if var annotationList = options["imageAnnotations"] as? [[String: Any]] {
            for idx in annotationList.indices {
                if let val = annotationList[idx]["imageURL"] {
                    annotationList[idx]["imageURL"] = resolveToURLString(val)
                }
            }
            options["imageAnnotations"] = annotationList
        }
    }
}

public typealias FileveroCommandLine = CLIOrchestrator

