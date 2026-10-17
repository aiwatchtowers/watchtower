import XCTest
@testable import WatchtowerCore

/// The "Blocked …" line over a workbench html preview (#563).
final class HTMLBlockedResourcesTests: XCTestCase {
    func testEveryHostOffTheAllowlistIsNamed() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js/dist/reveal.css">
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
        <link rel="stylesheet" href='https://evil.example/a.css'>
        <script src=https://tracker.example/t.js></script>
        <style>body { background: url("https://evil.example/bg.png") } @import "http://cdn.jsdelivr.net/x.css";</style>
        </head><body>
        <img src="logo.png"><img src="data:image/png;base64,AAAA"><img src="//third.example/p.gif">
        <img srcset="small.png 1x, https://fourth.example/big.png 2x">
        <img src="https://evil.example/a.css">
        <a href="https://linked.example/">a link is not a resource</a>
        <form action="https://form.example/"></form>
        </body></html>
        """
        let blocked = HTMLBlockedResources.scan(html)
        XCTAssertEqual(blocked.hosts, ["evil.example", "tracker.example", "third.example", "fourth.example", "cdn.jsdelivr.net"])
        XCTAssertEqual(blocked.total, 6, "distinct URLs: a.css twice counts once; http to an allowlisted host is blocked")
        XCTAssertEqual(blocked.hiddenFiles, 0)
        XCTAssertEqual(blocked.banner(), "Blocked 6 external resources: evil.example, tracker.example, third.example…")
    }

    func testNothingIsCountedThatNeverLoads() {
        let html = """
        <link rel="canonical" href="https://canon.example/">
        <link rel="alternate" href="https://alt.example/feed">
        <link rel="preconnect" href="https://pre.example">
        <link rel="dns-prefetch" href="//dns.example">
        <link rel="manifest" href="https://manifest.example/m.json">
        <base href="https://base.example/">
        <!-- <img src="https://commented.example/x.png"> -->
        <script>const u = "<img src='https://in-script.example/x.png'>"; fetch(`url(https://in-script.example/y)`)</script>
        <pre><img src="https://in-pre.example/x.png"></pre>
        <textarea><img src="https://in-textarea.example/x.png"></textarea>
        <noscript><img src="https://in-noscript.example/x.png"></noscript>
        <script src="https://unpkg.com/x.js"></script><img src="a.png"><a href="https://x.example">x</a>
        """
        let blocked = HTMLBlockedResources.scan(html)
        XCTAssertEqual(blocked, .init(total: 0, hosts: []))
        XCTAssertNil(blocked.banner())
    }

    func testAllowlistedHostsStillBlockFramesMediaAndEmbeds() {
        let html = """
        <iframe src="https://cdn.jsdelivr.net/gh/a/b/page.html"></iframe>
        <video src="https://unpkg.com/x/clip.mp4" poster="https://unpkg.com/x/poster.png"></video>
        <audio><source src="https://cdnjs.cloudflare.com/a.mp3"></audio>
        <picture><source srcset="https://unpkg.com/x/a.webp"><img src="https://unpkg.com/x/a.png"></picture>
        <embed src="https://cdn.jsdelivr.net/e.swf"><object data="https://cdn.jsdelivr.net/o.pdf"></object>
        <link rel="icon" href="https://cdn.jsdelivr.net/favicon.ico">
        """
        let blocked = HTMLBlockedResources.scan(html)
        XCTAssertEqual(blocked.total, 5, "iframe, video, audio source, embed, object; a poster and a picture source are images")
        XCTAssertEqual(blocked.hosts, ["cdn.jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com"])
    }

    func testHiddenLocalFilesAreCounted() {
        let html = """
        <script src=".secrets/config.js"></script><link rel="stylesheet" href="sub/.hidden/a.css">
        <img src="./img/ok.png"><img src="../up.png"><iframe src=".env"></iframe><img src=".secrets/config.js">
        """
        let blocked = HTMLBlockedResources.scan(html)
        XCTAssertEqual(blocked.hiddenFiles, 3)
        XCTAssertEqual(blocked.total, 0)
        XCTAssertEqual(blocked.banner(), "Blocked 3 hidden files")
        XCTAssertEqual(HTMLBlockedResources.scan(#"<img src="https://a.example/1.png"><img src=".env">"#).banner(),
                       "Blocked 1 external resource: a.example · 1 hidden file")
    }
}
