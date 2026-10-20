import SwiftUI

/// Static About information.
enum SettingsAbout {
    static let repositoryAddress = "https://github.com/sajadabvi/learn_piano_IOS"
    static var repositoryURL: URL? { URL(string: repositoryAddress) }

    /// Bundled license files: (title, resource name, extension).
    static let licenses: [(title: String, resource: String, ext: String)] = [
        ("Bravura music font (SIL Open Font License 1.1)", "Bravura-OFL", "txt"),
    ]

    /// Finds a bundled license file whether it was copied flat or inside a Licenses folder.
    static func licenseURL(resource: String, ext: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resource, withExtension: ext)
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "Licenses")
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "Resources/Licenses")
    }
}

/// Licenses of bundled third-party material, loaded from Resources/Licenses.
struct SettingsLicensesView: View {
    var body: some View {
        List {
            Section {
                ForEach(SettingsAbout.licenses, id: \.resource) { license in
                    NavigationLink(license.title) {
                        SettingsLicenseTextView(title: license.title, resource: license.resource, ext: license.ext)
                    }
                }
            } footer: {
                Text("LearnPiano uses no third-party code. Sheet music is engraved with the Bravura font by Steinberg Media Technologies GmbH.")
            }
        }
        .navigationTitle("Licenses")
    }
}

/// One license text, read off the main thread.
struct SettingsLicenseTextView: View {
    var title: String
    var resource: String
    var ext: String
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            Group {
                if let text {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                } else if let problem {
                    Text(problem)
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Theme.sheetBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let url = SettingsAbout.licenseURL(resource: resource, ext: ext) else {
            problem = "The license file is missing from this build. The SIL Open Font License 1.1 is available at https://openfontlicense.org."
            return
        }
        let result = await Task.detached(priority: .utility) { () -> Result<String, Error> in
            Result { try String(contentsOf: url, encoding: .utf8) }
        }.value
        switch result {
        case .success(let string): text = string
        case .failure(let error): problem = "The license could not be read: \(error.localizedDescription)"
        }
    }
}
