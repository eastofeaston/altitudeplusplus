import Foundation
import Observation

struct Program: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var summary: String?
    var category: String?
    /// Gracenote's program type, e.g. "Sports event" for game broadcasts.
    var kind: String?
    var start: Date
    var end: Date
    var imageURL: URL?

    func isOn(at date: Date) -> Bool { start <= date && date < end }

    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    var isGame: Bool { kind == "Sports event" }
}

/// Now/next listings for the 24/7 channel, from the public XMLTV feed.
@Observable
@MainActor
final class GuideStore {
    private(set) var programs: [Program] = []
    private(set) var lastLoaded: Date?
    private(set) var loadError: String?

    func program(at date: Date = .now) -> Program? {
        programs.first { $0.isOn(at: date) }
    }

    func upcoming(after date: Date = .now, limit: Int = 8) -> [Program] {
        Array(programs.filter { $0.start > date }.prefix(limit))
    }

    func loadIfStale() async {
        if let lastLoaded, lastLoaded.timeIntervalSinceNow > -30 * 60, !programs.isEmpty { return }
        await load()
    }

    func load() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: AltitudeConfig.epgURL)
            let parsed = XMLTVParser.parse(data)
            programs = parsed
                .filter { $0.end > .now.addingTimeInterval(-3600) }
                .sorted { $0.start < $1.start }
            lastLoaded = .now
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Parses the handful of XMLTV fields the guide needs.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private var programs: [Program] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inProgramme = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter
    }()

    static func parse(_ data: Data) -> [Program] {
        let delegate = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.programs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "programme":
            inProgramme = true
            current = [
                "id": attributeDict["id"] ?? UUID().uuidString,
                "start": attributeDict["start"] ?? "",
                "stop": attributeDict["stop"] ?? "",
            ]
        case "icon" where inProgramme:
            current["icon"] = attributeDict["src"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inProgramme else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title", "sub-title", "sub-type", "desc", "category":
            if !value.isEmpty, current[elementName] == nil { current[elementName] = value }
        case "programme":
            inProgramme = false
            if let start = Self.dateFormatter.date(from: current["start"] ?? ""),
               let end = Self.dateFormatter.date(from: current["stop"] ?? ""),
               let title = current["title"] {
                programs.append(Program(
                    id: (current["id"] ?? "") + (current["start"] ?? ""),
                    title: title,
                    subtitle: current["sub-title"],
                    summary: current["desc"],
                    category: current["category"],
                    kind: current["sub-type"],
                    start: start,
                    end: end,
                    imageURL: current["icon"].flatMap(URL.init(string:))
                ))
            }
        default:
            break
        }
        text = ""
    }
}
