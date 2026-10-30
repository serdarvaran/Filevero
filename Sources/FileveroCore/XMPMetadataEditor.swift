import Foundation

/// Namespace-aware XML packet editor for custom XMP metadata fields in images and documents.
/// Prevents XML entity expansion (XXE) and supports schema-compliant property injection (Alt, Bag, Seq).
enum XMPMetadataEditor {
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let standardSchemas = [
        "dc": "http://purl.org/dc/elements/1.1/",
        "xmp": "http://ns.adobe.com/xap/1.0/",
        "photoshop": "http://ns.adobe.com/photoshop/1.0/",
        "tiff": "http://ns.adobe.com/tiff/1.0/",
        "exif": "http://ns.adobe.com/exif/1.0/",
        "xmpRights": "http://ns.adobe.com/xap/1.0/rights/",
    ]

    static func isXMP(_ key: String) -> Bool {
        key.hasPrefix("{XMP-") || key.hasPrefix("XMP-")
    }

    private static func splitKey(_ key: String) throws -> (String, String) {
        let sanitized = key.replacingOccurrences(of: "{XMP-", with: "")
            .replacingOccurrences(of: "XMP-", with: "")
            .replacingOccurrences(of: "}.", with: ":")
            
        let components = sanitized.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2,
              components.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil })
        else {
            throw FileveroError.invalidInput("Invalid XMP field: \(key)")
        }
        return (components[0], components[1])
    }

    private static func parseDocument(_ data: Data) throws -> XMLDocument {
        let fallback = Data(
            "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='\(rdfNamespace)'><rdf:Description rdf:about=''/></rdf:RDF></x:xmpmeta>"
                .utf8
        )
        let rawString = String(decoding: data, as: UTF8.self)
        guard rawString.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              rawString.range(of: "<!ENTITY", options: .caseInsensitive) == nil
        else {
            throw FileveroError.invalidInput("XMP declarations with external entities or DTDs are not supported.")
        }
        
        return try XMLDocument(
            data: data.isEmpty ? fallback : data,
            options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
        )
    }

    private static func descriptions(_ doc: XMLDocument) throws -> [XMLElement] {
        try doc.nodes(forXPath: "//*[local-name()='Description']")
            .compactMap { $0 as? XMLElement }
            .filter { $0.uri == rdfNamespace }
    }

    static func fields(_ data: Data) throws -> [String: String] {
        guard !data.isEmpty else { return [:] }
        let doc = try parseDocument(data)
        var extractedFields: [String: String] = [:]
        
        for description in try descriptions(doc) {
            for attr in description.attributes ?? [] where attr.prefix != "rdf" && !(attr.prefix ?? "").isEmpty {
                guard let prefix = attr.prefix, let name = attr.localName else { continue }
                extractedFields["{XMP-\(prefix)}.\(name)"] = attr.stringValue ?? ""
            }
            for child in description.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard let prefix = child.prefix, !prefix.isEmpty, prefix != "rdf", let name = child.localName else {
                    continue
                }
                let listElements = try child.nodes(forXPath: ".//*[local-name()='li']").filter { $0.uri == rdfNamespace }
                if listElements.count > 1,
                   let encodedList = try? JSONSerialization.data(withJSONObject: listElements.map { $0.stringValue ?? "" }) {
                    extractedFields["{XMP-\(prefix)}.\(name)"] = String(decoding: encodedList, as: UTF8.self)
                } else {
                    extractedFields["{XMP-\(prefix)}.\(name)"] = listElements.first?.stringValue ?? child.stringValue ?? ""
                }
            }
        }
        return extractedFields
    }

    static func edit(_ data: Data, updates: [String: String], removals: [String]) throws -> Data {
        let doc = try parseDocument(data)
        guard let primaryDescription = try descriptions(doc).first else {
            throw FileveroError.invalidInput("This XMP packet has no editable description.")
        }
        
        for removalKey in removals {
            let (prefix, name) = try splitKey(removalKey)
            for description in try descriptions(doc) {
                for attr in description.attributes ?? []
                where attr.prefix == prefix && attr.localName?.caseInsensitiveCompare(name) == .orderedSame {
                    attr.detach()
                }
                for child in description.children ?? []
                where child.prefix == prefix && child.localName?.caseInsensitiveCompare(name) == .orderedSame {
                    child.detach()
                }
            }
        }
        
        for (fieldKey, fieldValue) in updates.sorted(by: { $0.key < $1.key }) {
            let (prefix, name) = try splitKey(fieldKey)
            var matchedElement: XMLElement?
            var parentElement = primaryDescription
            
            for description in try descriptions(doc) {
                if let attr = description.attributes?.first(where: {
                    $0.prefix == prefix && $0.localName?.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    attr.stringValue = fieldValue
                    matchedElement = nil
                    parentElement = description
                    break
                }
                if let child = description.children?.compactMap({ $0 as? XMLElement }).first(where: {
                    $0.prefix == prefix && $0.localName?.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    matchedElement = child
                    parentElement = description
                    break
                }
            }
            
            if parentElement.attributes?.contains(where: {
                $0.prefix == prefix && $0.localName?.caseInsensitiveCompare(name) == .orderedSame
            }) == true {
                continue
            }
            
            let targetNode: XMLElement
            if let existing = matchedElement {
                targetNode = existing
            } else {
                let resolvedUri = parentElement.resolveNamespace(forName: prefix + ":" + name)?.stringValue ?? standardSchemas[prefix]
                guard let uri = resolvedUri, !uri.isEmpty else {
                    throw FileveroError.invalidInput("The custom XMP namespace \(prefix) is not declared in this file.")
                }
                parentElement.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
                let localName = prefix == "dc" ? name.prefix(1).lowercased() + name.dropFirst() : name
                targetNode = XMLElement(name: prefix + ":" + localName, uri: uri)
                parentElement.addChild(targetNode)
            }
            
            let existingContainer = targetNode.children?.compactMap({ $0 as? XMLElement }).first(where: {
                $0.uri == rdfNamespace && ["Alt", "Seq", "Bag"].contains($0.localName ?? "")
            })
            let parsedValues = (try? JSONSerialization.jsonObject(with: Data(fieldValue.utf8))) as? [String]
            
            if let container = existingContainer {
                container.setChildren(nil)
                for itemValue in parsedValues ?? [fieldValue] {
                    let li = XMLElement(name: "rdf:li", uri: rdfNamespace)
                    li.stringValue = itemValue
                    if container.localName == "Alt" {
                        li.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
                    }
                    container.addChild(li)
                }
            } else if prefix == "dc", ["title", "description", "rights", "creator", "subject"].contains(name.lowercased()) {
                let listKind = ["title", "description", "rights"].contains(name.lowercased())
                    ? "Alt"
                    : name.lowercased() == "creator" ? "Seq" : "Bag"
                let container = XMLElement(name: "rdf:" + listKind, uri: rdfNamespace)
                targetNode.setChildren([container])
                for itemValue in parsedValues ?? [fieldValue] {
                    let li = XMLElement(name: "rdf:li", uri: rdfNamespace)
                    li.stringValue = itemValue
                    if listKind == "Alt" {
                        li.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
                    }
                    container.addChild(li)
                }
            } else {
                targetNode.stringValue = fieldValue
            }
        }
        
        let xmlOutput = String(decoding: doc.xmlData(options: [.nodeCompactEmptyElement]), as: UTF8.self)
        let sanitizedPacket = xmlOutput.replacingOccurrences(of: "^<\\?xml[^?]*\\?>", with: "", options: .regularExpression)
        return Data(sanitizedPacket.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

typealias XMPPacketEditor = XMPMetadataEditor

