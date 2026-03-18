import Foundation
import Testing

@testable import StashMac

@Test func testAllTopicsHaveSections() {
    for topic in HelpTopic.allCases {
        #expect(!topic.sections.isEmpty, "Topic '\(topic.rawValue)' has no sections")
    }
}

@Test func testAllTopicsHaveIcons() {
    for topic in HelpTopic.allCases {
        #expect(!topic.icon.isEmpty, "Topic '\(topic.rawValue)' has no icon")
    }
}

@Test func testTopicCount() {
    #expect(HelpTopic.allCases.count == 9)
}

@Test func testTopicIdentifiers() {
    let ids = HelpTopic.allCases.map(\.id)
    let uniqueIDs = Set(ids)
    #expect(ids.count == uniqueIDs.count, "Help topic IDs must be unique")
}

@Test func testKeyboardShortcutsTopicHasTables() {
    let sections = HelpTopic.keyboard.sections
    let tableCount = sections.filter {
        if case .table = $0 { return true }
        return false
    }.count
    #expect(tableCount >= 2, "Keyboard shortcuts topic should have multiple tables")
}
