//
//  EncodingTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation
import Testing
@testable import AgentVFS

@Suite("Text encodings")
struct EncodingTests {
    private func text(_ content: FileContent) -> String? {
        switch content {
        case let .text(data), let .transcodedText(data, _): String(bytes: data, encoding: .utf8)
        default: nil
        }
    }

    private func encoded(_ string: String, _ encoding: String.Encoding) throws -> Data {
        try #require(string.data(using: encoding))
    }

    /// The text classification finds in `string` written in `encoding`, or `nil` when it is not text.
    private func classified(_ string: String, _ encoding: String.Encoding) throws -> String? {
        let data = try encoded(string, encoding)
        return text(FileContent.classify(data))
    }

    @Test("UTF-16 and UTF-32 with a byte order mark, and UTF-16 without one")
    func wide() throws {
        let sample = "name,city\nОля,Київ\n"
        // With a BOM, in platform order.
        #expect(try classified(sample, .utf16) == sample)
        #expect(try classified(sample, .utf16BigEndian) == nil, "no BOM and Cyrillic: not guessable")
        let bigEndian = try encoded(sample, .utf16BigEndian)
        #expect(text(FileContent.classify(Data([0xFE, 0xFF]) + bigEndian)) == sample)
        #expect(try classified(sample, .utf32) == sample)
        let ascii = "id,total\n1,10\n2,20\n"
        #expect(try classified(ascii, .utf16LittleEndian) == ascii)
        #expect(try classified(ascii, .utf16BigEndian) == ascii)
        let littleEndian = try encoded(ascii, .utf16LittleEndian)
        let transcoded = FileContent.transcodedText(Data(ascii.utf8), originalByteSize: ascii.utf16.count * 2)
        #expect(FileContent.classify(littleEndian) == transcoded)
    }

    @Test("Windows-1251 Cyrillic and Windows-1252 accents")
    func singleByte() throws {
        let ukrainian = "Виписка банку: сума 100 грн, отримувач ТОВ «Їжак»\n"
        #expect(try classified(ukrainian, .windowsCP1251) == ukrainian)
        let french = "café crème, naïve résumé\n"
        #expect(try classified(french, .windowsCP1252) == french)
        #expect(try classified(french, .isoLatin1) == french)
    }

    @Test("binary stays binary")
    func binary() {
        let pngStart = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48])
        #expect(text(FileContent.classify(pngStart)) == nil)
        #expect(text(FileContent.classify(Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) }))) == nil)
        #expect(text(FileContent.classify(Data([0x01, 0x02, 0xC3, 0x28, 0x10]))) == nil)
        #expect(text(FileContent.classify(Data("plain ascii\n".utf8))) == "plain ascii\n")
    }

    @Test("a local Windows-1251 file can be read and searched")
    func localFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let bank = try encoded("дата;сума\n01.10;100\n02.10;Повернення\n", .windowsCP1251)
        try bank.write(to: root.appendingPathComponent("bank.csv"))
        let excel = try encoded("id,city\n1,Kyiv\n", .utf16)
        try excel.write(to: root.appendingPathComponent("excel.txt"))
        let driver = try LocalDirectoryDriver(root: root)
        let fileSystem = try WorkspaceFileSystem(mounts: [WorkspaceMount(name: "d", driver: driver)])
        let shell = CommandInterpreter(fileSystem: fileSystem)
        #expect(await shell.run("cat d/bank.csv").output == "дата;сума\n01.10;100\n02.10;Повернення")
        #expect(await shell.run("grep -n Повернення d/bank.csv").output == "3:02.10;Повернення")
        #expect(await shell.run("cat d/excel.txt").output == "id,city\n1,Kyiv")
    }
}
