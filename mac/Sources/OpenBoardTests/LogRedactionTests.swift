import Foundation
import OpenBoardKit

/**
 The log must never carry the host-service token.

 `app.log` is what gets attached to "send me your logs". The token in Superset's
 `manifest.json` is a bearer credential for every workspace on the machine, so every
 line is scrubbed on its way in: the header, the query parameter, the URL that carries
 it, and any secret the app has registered — wherever in a line it appears.
 */
func runLogRedactionTests() {
    let secret = "s3cr3t-9f8e7d6c5b4a"

    test("an Authorization: Bearer header loses its credential") {
        let line = LogRedactor.redact("POST /trpc/x Authorization: Bearer fake-cred-0x1",
                                      secrets: [])
        expect(!line.contains("fake-cred-0x1"), "credential kept: \(line)")
        expect(line.contains("«redacted»"), "no marker: \(line)")
        expect(line.hasPrefix("POST /trpc/x"), "the rest of the line was lost: \(line)")
    }

    test("a lowercase bearer is caught as well") {
        let line = LogRedactor.redact("authorization: bearer fake-cred-0x1", secrets: [])
        expect(!line.contains("fake-cred-0x1"), "credential kept: \(line)")
    }

    test("a token query parameter is redacted") {
        let line = LogRedactor.redact("GET /x?a=1&token=fake-tok-0x2 done", secrets: [])
        expect(!line.contains("fake-tok-0x2"), "token kept: \(line)")
        expect(line.contains("token=«redacted»"), "no marker: \(line)")
        expect(line.hasSuffix(" done"), "text after the token was eaten: \(line)")
    }

    test("a registered secret disappears even inside another string") {
        let line = LogRedactor.redact("prefix-\(secret)-suffix and \(secret)", secrets: [secret])
        expect(!line.contains(secret), "secret kept: \(line)")
        expectEqual(line, "prefix-«redacted»-suffix and «redacted»")
    }

    test("an empty secret redacts nothing") {
        expectEqual(LogRedactor.redact("plain line", secrets: [""]), "plain line")
    }

    test("a ws URL carrying a token is reduced to its path") {
        let line = LogRedactor.redact(
            "events: connecting ws://localhost:51234/events?token=fake-tok-0x2 now", secrets: []
        )
        expectEqual(line, "events: connecting /events now")
    }

    test("a line with nothing sensitive is untouched") {
        let plain = "key ACT06: jump to session 2 (ws://nothing here)"
        expectEqual(LogRedactor.redact(plain, secrets: [secret]), plain)
    }

    test("Log scrubs a registered token before writing") {
        let token = SecretToken("tok-\(UUID().uuidString)")
        Log.registerSecret(token)
        let raw = token.withRaw { $0 }
        let line = Log.redact("manifest read, authToken \(raw)")
        expect(!line.contains(raw), "registered token reached the log line: \(line)")
        expect(line.contains("«redacted»"))
    }
}
