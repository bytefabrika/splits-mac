import SwiftUI

/// The legal notices: in Settings, and linked from the welcome screen. `LEGAL.md` in the repo says the same.
struct LegalView: View {
    static let sections: [(title: String, text: String)] = [
        ("Independent app",
         """
         Splits is an independent app made by Bytefabrika. It is not made, sponsored, endorsed or approved by Garmin Ltd. or \
         its subsidiaries. Garmin and Garmin Connect are trademarks of Garmin Ltd. or its subsidiaries; they are named only to \
         say which service Splits works with. Other names belong to their owners.
         """),
        ("Not medical advice",
         """
         Splits is not a medical device. It does not diagnose, treat, cure or prevent any disease or condition. Its numbers, \
         charts, verdicts and coach notes are general fitness information, worked out from what your watch recorded, and can \
         be wrong. Don't use them to make medical decisions. Talk to a doctor before you start or change training, and stop \
         and get help if something feels wrong.
         """),
        ("Notes written by AI",
         """
         The coach's notes are written on your Mac by Apple's on-device language model. They are generated text: they can \
         misread a number or say something that isn't so. The numbers on the page are the reference.
         """),
        ("Your key and your account",
         """
         Splits uses the Garmin Connect Personal API with a key you create in your own account. You are responsible for your \
         key and for using it within the terms you accepted when you created it, which allow personal use only. Don't share \
         your key. Splits keeps it in your keychain and sends it only to that service, to fetch your own data. The service can \
         change, limit or end the API at any time, and Splits may then stop working.
         """),
        ("Your privacy",
         """
         Bytefabrika has no server for Splits and receives none of your data: no account, no analytics, no tracking. What \
         Splits downloads is stored on this Mac only, and the AI runs on this Mac. Settings › General › Remove Key and Data \
         deletes all of it.
         """),
        ("No warranty",
         """
         Splits is free and open source under the MIT License, and is provided "as is", without warranty of any kind. As far \
         as the law allows, Bytefabrika is not liable for any loss or damage from using it, including lost data, a blocked \
         key or account, or decisions made from what it shows. Nothing here limits rights that the law doesn't let us limit.
         """),
        ("Data and references",
         """
         Country borders: Natural Earth (public domain). Cities: GeoNames (CC BY 4.0, geonames.org). The sleep and HRV methods \
         follow published research (Plews et al., Buchheit, Wittmann et al., Roenneberg et al., Van Dongen et al.); citing it \
         doesn't mean the authors endorse Splits.
         """),
        ("Contact", "Bytefabrika, hello@bytefabrika.io, bytefabrika.io"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.headline)
                        Text(section.text).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("© 2026 Bytefabrika").font(.caption).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
