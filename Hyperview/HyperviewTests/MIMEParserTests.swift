//
//  MIMEParserTests.swift
//  HyperviewTests
//
//  Ground-truth tests for MIMEParser against realistic messages (folded
//  Received headers, DKIM blobs, multipart/alternative with quoted boundary,
//  quoted-printable and base64 parts). Written to reproduce the live bug where
//  a real iCloud-delivered message parsed as headerless text/plain.
//

import Testing
import Foundation
@testable import Hyperview

struct MIMEParserTests {

    /// A trimmed-down but structurally faithful iCloud-delivered Gmail message.
    private func realisticMultipart() -> Data {
        let crlf = "\r\n"
        let lines = [
            "Return-path: <sender@gmail.com>",
            "Original-recipient: rfc822;jason@mcgraw.cc",
            "Received: from p00-icloudmta-smtpin-us-west-2a-60-percent-12 by p129-mailgateway-smtpin-yoxpo (mailgateway 2513B25)",
            "\twith SMTP id d573ca8a-bc41-44d4-bd0a-a1855735eb1b",
            "\tfor <jason@mcgraw.cc>; Tue, 8 Jul 2026 01:02:03 GMT",
            "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=gmail.com; s=20230601;",
            "        h=to:subject:message-id:date:from:mime-version:from:to:cc:subject;",
            "        b=ABCDefGHijKLmnOPqrSTuvWXyz0123456789+/ABCDefGHijKLmnOPqrSTuvWX",
            "         yz0123456789+/ABCDefGHijKLmnOP=",
            "MIME-Version: 1.0",
            "From: Sender Person <sender@gmail.com>",
            "Date: Mon, 7 Jul 2026 20:01:02 -0500",
            "Message-ID: <CA+abc123@mail.gmail.com>",
            "Subject: OTYC Resources",
            "To: jason@mcgraw.cc",
            "Content-Type: multipart/alternative; boundary=\"00000000000012a8cf065619ae4a\"",
            "",
            "--00000000000012a8cf065619ae4a",
            "Content-Type: text/plain; charset=\"UTF-8\"; format=flowed; delsp=yes",
            "",
            "I've shared an item with you:",
            "",
            "OTYC Resources",
            "https://drive.google.com/drive/folders/abc?usp=sharing",
            "",
            "--00000000000012a8cf065619ae4a",
            "Content-Type: text/html; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "<div dir=3D\"ltr\">I've shared an <b>item</b> with you.</div>=",
            "",
            "--00000000000012a8cf065619ae4a--",
            "",
        ]
        return Data(lines.joined(separator: crlf).utf8)
    }

    @Test func parsesRealisticICloudMultipart() {
        let body = MIMEParser.parse(realisticMultipart())
        #expect(body.text?.contains("I've shared an item with you") == true,
                "plain part extracted: got \(String(describing: body.text?.prefix(80)))")
        #expect(body.html?.contains("<div dir=\"ltr\">") == true,
                "html part extracted + quoted-printable decoded: got \(String(describing: body.html?.prefix(80)))")
        #expect(body.text?.contains("--00000000000012a8cf") != true, "no raw boundaries in text")
    }

    @Test func parsesSinglePartPlain() {
        let raw = "From: a@b.c\r\nContent-Type: text/plain; charset=\"utf-8\"\r\n\r\nHello there.\r\n"
        let body = MIMEParser.parse(Data(raw.utf8))
        #expect(body.text == "Hello there.\r\n")
        #expect(body.html == nil)
    }

    @Test func parsesAttachmentsAndInlineImages() {
        let pdf = Data("fake-pdf-bytes".utf8).base64EncodedString()
        let png = Data("fake-png-bytes".utf8).base64EncodedString()
        let raw = [
            "From: a@b.c",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: text/html; charset=\"utf-8\"",
            "",
            "<p>See attached <img src=\"cid:img1@mail\"></p>",
            "--outer",
            "Content-Type: application/pdf; name=\"report.pdf\"",
            "Content-Disposition: attachment; filename=\"report.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            pdf,
            "--outer",
            "Content-Type: image/png",
            "Content-ID: <img1@mail>",
            "Content-Transfer-Encoding: base64",
            "",
            png,
            "--outer--",
            "",
        ].joined(separator: "\r\n")

        let body = MIMEParser.parse(Data(raw.utf8))
        #expect(body.html?.contains("cid:img1@mail") == true)
        #expect(body.attachments.count == 2)

        let pdfPart = body.attachments.first { $0.filename == "report.pdf" }
        #expect(pdfPart?.mimeType == "application/pdf")
        #expect(pdfPart.map { String(decoding: $0.data, as: UTF8.self) } == "fake-pdf-bytes")

        let inline = body.attachments.first { $0.contentID == "img1@mail" }
        #expect(inline?.mimeType == "image/png")
        #expect(inline.map { String(decoding: $0.data, as: UTF8.self) } == "fake-png-bytes")
    }

    @Test func parsesBase64HTMLOnly() {
        let html = "<p>Hi &amp; bye</p>"
        let b64 = Data(html.utf8).base64EncodedString()
        let raw = "Content-Type: text/html; charset=\"utf-8\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64)\r\n"
        let body = MIMEParser.parse(Data(raw.utf8))
        #expect(body.html == html)
    }
}
