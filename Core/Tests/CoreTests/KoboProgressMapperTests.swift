import Testing
import Foundation
@testable import Core

struct KoboProgressMapperTests {
    @Test func koboToLocatorWithKoboSpan() throws {
        let json = KoboProgressMapper.toLocator(
            source: "f_0035.xhtml",
            type: "KoboSpan",
            value: "kobo.10.1",
            progressPercent: 45.0,
            totalPercent: 16.0
        )
        let dict = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        #expect(dict["href"] as? String == "f_0035.xhtml")
        let locations = dict["locations"] as! [String: Any]
        #expect(locations["progression"] as? Double == 0.45)
        #expect(locations["totalProgression"] as? Double == 0.16)
        #expect(locations["cssSelector"] as? String == #"#kobo\.10\.1"#)
    }

    @Test func koboToLocatorWithoutKoboSpan() throws {
        let json = KoboProgressMapper.toLocator(
            source: "OEBPS/x.xhtml", type: "Generic", value: "",
            progressPercent: 12.0, totalPercent: 6.0
        )
        let dict = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let locations = dict["locations"] as! [String: Any]
        #expect(locations["cssSelector"] == nil)
        #expect(locations["progression"] as? Double == 0.12)
    }
}
