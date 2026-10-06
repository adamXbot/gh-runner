import AppKit
import SwiftUI

/// Everything the shared surfaces need to know about Runner Menu: the profile
/// behind Settings, About, the app and Help menus and the menu bar popover.
enum RunnerMenuSurface {
    static let repository = URL(string: "https://github.com/adamXbot/gh-runner")!
    static let issues = URL(string: "https://github.com/adamXbot/gh-runner/issues")!
    static let releaseNotes = URL(string: "https://github.com/adamXbot/gh-runner/releases")!

    static let app = SurfaceApp(
        wordmark: SurfaceWordmark(lead: "Runner ", accent: "Menu"),
        accent: .green,
        summary: "Manage the GitHub Actions self-hosted runners on this Mac from the menu bar.",
        capabilities: [
            SurfaceCapability("Token-free registration",
                              detail: "Registration tokens come from your gh login; nothing is typed or stored."),
            SurfaceCapability("Start and stop",
                              detail: "A detached run.sh or a launchd service that keeps going after you quit."),
            SurfaceCapability("Live stats and logs",
                              detail: "State, PID, CPU, memory, uptime, the current job and a live log tail."),
            SurfaceCapability("Verified runner updates",
                              detail: "Every runner package is checked against the SHA-256 GitHub publishes."),
            SurfaceCapability("Fleet overview",
                              detail: "Every local runner, its repository and its recent jobs at a glance."),
            SurfaceCapability("Dedicated account",
                              detail: "Monitors runners owned by a standard account through a signed agent."),
        ],
        distribution: .openSource(repository: repository, issues: issues, licence: "MIT License"),
        shape: .menuBarUtility,
        acknowledgements: [
            SurfaceAcknowledgement(name: "Sparkle", licence: "MIT License", text: sparkleLicence),
        ]
    )

    /// The mark in the popover header: the app icon.
    @MainActor
    static var mark: Image {
        Image(nsImage: NSApplication.shared.applicationIconImage)
    }

    /// The manual: `Contents/Resources/Manual` in the assembled app, or the
    /// package resource bundle when run with `swift run`.
    static var manualFolder: URL? {
        if let bundled = SurfaceManual.bundledFolder { return bundled }
        // `Bundle.module` traps when its bundle is missing, so it is only
        // consulted for the bare executable in the package build directory.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: "Manual", withExtension: nil)
    }

    /// Every shortcut the app defines, after the standard group.
    static func shortcuts(for app: SurfaceApp) -> [SurfaceShortcutGroup] {
        [
            .standard(for: app),
            SurfaceShortcutGroup("Runners", items: [
                SurfaceShortcut("⌘R", "Refresh", detail: "Re-reads every runner, in the menu bar panel and the window"),
                SurfaceShortcut("↩", "Start or stop the selected runner", detail: "In the menu bar panel"),
                SurfaceShortcut("⎋", "Back", detail: "Returns to the runner list or closes the activity preview"),
            ]),
            SurfaceShortcutGroup("Windows", items: [
                SurfaceShortcut("⌘0", "Runner Menu Window", detail: "Opens the full window from the Window menu"),
            ]),
        ]
    }

    /// Sparkle's LICENSE file, as shipped in the framework the app embeds.
    private static let sparkleLicence = """
        Copyright (c) 2006-2013 Andy Matuschak.
        Copyright (c) 2009-2013 Elgato Systems GmbH.
        Copyright (c) 2011-2014 Kornel Lesiński.
        Copyright (c) 2015-2017 Mayur Pawashe.
        Copyright (c) 2014 C.W. Betts.
        Copyright (c) 2014 Petroules Corporation.
        Copyright (c) 2014 Big Nerd Ranch.
        All rights reserved.

        Permission is hereby granted, free of charge, to any person obtaining a copy of
        this software and associated documentation files (the "Software"), to deal in
        the Software without restriction, including without limitation the rights to
        use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
        the Software, and to permit persons to whom the Software is furnished to do so,
        subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
        FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
        COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
        CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        =================
        EXTERNAL LICENSES
        =================

        bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

        Copyright 2003-2005 Colin Percival
        All rights reserved

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions 
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.

        --

        sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

        The sais-lite copyright is as follows:

        Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

        Permission is hereby granted, free of charge, to any person
        obtaining a copy of this software and associated documentation
        files (the "Software"), to deal in the Software without
        restriction, including without limitation the rights to use,
        copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the
        Software is furnished to do so, subject to the following
        conditions:

        The above copyright notice and this permission notice shall be
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
        OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
        HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
        WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
        FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
        OTHER DEALINGS IN THE SOFTWARE.

        --

        Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

        Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

        This software is provided 'as-is', without any express or implied warranty. In no event will the
        authors be held liable for any damages arising from the use of this software.

        Permission is granted to anyone to use this software for any purpose, including commercial
        applications, and to alter it and redistribute it freely, subject to the following restrictions:

        1. The origin of this software must not be misrepresented; you must not claim that you wrote the
           original software. If you use this software in a product, an acknowledgment in the product
           documentation would be appreciated but is not required.

        2. Altered source versions must be plainly marked as such, and must not be misrepresented as
           being the original software.

        3. This notice may not be removed or altered from any source distribution.

        --

        SUSignatureVerifier.m:

        Copyright (c) 2011 Mark Hamlin.

        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.
        """
}

/// The glyph families the menu bar item can use. Each one changes with the
/// runners' state; Settings ▸ General chooses the family.
enum MenuBarGlyph: String, CaseIterable, Identifiable {
    case circles
    case plain

    static let `default` = MenuBarGlyph.circles

    /// The aggregate state of the monitored runners, from most to least urgent.
    enum State {
        case busy
        case running
        case transitioning
        case stopped
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circles: return "Circles"
        case .plain: return "Plain"
        }
    }

    func symbol(for state: State) -> String {
        switch (self, state) {
        case (.circles, .busy): return "bolt.horizontal.circle.fill"
        case (.circles, .running): return "play.circle.fill"
        case (.circles, .transitioning): return "clock.arrow.circlepath"
        case (.circles, .stopped): return "stop.circle"
        case (.plain, .busy): return "bolt.fill"
        case (.plain, .running): return "play.fill"
        case (.plain, .transitioning): return "clock"
        case (.plain, .stopped): return "stop"
        }
    }

    /// The choices for the icon picker in Settings.
    static var icons: [SurfaceMenuBarIcon] {
        allCases.map { glyph in
            SurfaceMenuBarIcon(id: glyph.id, title: glyph.title, image: Image(systemName: glyph.symbol(for: .running)))
        }
    }
}
