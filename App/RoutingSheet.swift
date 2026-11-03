import BurrowKit
import SwiftUI
import SystemConfiguration

/// "Wi-Fi" for en0: the names System Settings shows.
enum InterfaceNames {
    static func display(_ bsdName: String) -> String {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? bsdName
    }
}

/// Settings › Routing › Choose Routes…: for each VPN route, clash and own entry, whether its traffic goes through
/// the VPN or stays on the network the Mac is on.
struct RoutingSheet: View {
    @Binding var profile: VPNProfile
    let serverRoutes: [IPv4Network]
    /// What the running tunnel's last look at the local network found.
    var localDevices: [LocalDevices] = []
    var hosts = HostNames.current()
    var localNetworks = LocalNetworks.current()
    var onDone: () -> Void

    @State private var rows: [RouteChoice] = []
    @State private var selection: RouteChoice.ID?
    @State private var newEntry = ""
    /// Names typed in this sheet that came from DNS (`/etc/hosts` names show by themselves).
    @State private var typedNames: [IPv4Network: String] = [:]
    @State private var lookingUp = false
    @State private var addProblem: String?

    private var newNetwork: IPv4Network? { IPv4Network(newEntry) }
    /// A host name such as `server` or `server.example.com`.
    private var newName: String? {
        let name = newEntry.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        guard !name.isEmpty, name.rangeOfCharacter(from: allowed.inverted) == nil,
              name.rangeOfCharacter(from: .letters) != nil else { return nil }
        return name
    }
    private var selectedIsOwn: Bool { rows.first { $0.id == selection }?.origin == .added }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routes for \(profile.name.isEmpty ? "this configuration" : profile.name)").font(.headline)
            Text("Tick where each address or range goes. **Auto**, for a range your network uses too: Burrow finds your devices there and keeps them local, everything else goes through the VPN. **VPN**: through the tunnel. **Local**: the network you're on.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if serverRoutes.isEmpty {
                Label("Connect once to list the VPN's own routes here. You can add addresses now.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Table(rows, selection: $selection) {
                TableColumn("Address or range") { row in
                    HStack(spacing: 6) {
                        if row.isClash {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Your network uses these addresses too")
                        }
                        Text(row.id).font(.system(.body, design: .monospaced))
                        if let name = typedNames[row.network] ?? hosts.name(of: row.network) {
                            Text(name).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 160, ideal: 175)
                TableColumn("From") { row in
                    Text(origin(of: row)).foregroundStyle(.secondary).help(origin(of: row))
                }
                TableColumn("Auto") { row in
                    if row.splittable != nil {
                        Toggle("", isOn: side(row.id, .automatic)).toggleStyle(.checkbox).labelsHidden()
                    }
                }
                .width(44)
                TableColumn("VPN") { row in
                    Toggle("", isOn: side(row.id, .vpn)).toggleStyle(.checkbox).labelsHidden()
                }
                .width(44)
                TableColumn("Local") { row in
                    Toggle("", isOn: side(row.id, .local)).toggleStyle(.checkbox).labelsHidden()
                }
                .width(44)
            }
            .frame(minHeight: 180)

            HStack {
                TextField("Add a name, address or range", text: $newEntry, prompt: Text("server, 192.168.1.20, 10.1.0.0/16"))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(add)
                    .onChange(of: newEntry) { addProblem = nil }
                    .frame(maxWidth: 340)
                Button("Add", action: add).disabled((newNetwork == nil && newName == nil) || lookingUp)
                if lookingUp { ProgressView().controlSize(.small) }
                Button("Remove") { rows.removeAll { $0.id == selection } }
                    .disabled(!selectedIsOwn)
                    .help("Removes an address you added; the VPN's own routes stay listed")
                Spacer()
            }
            if let addProblem {
                Text(addProblem).font(.caption).foregroundStyle(.orange)
            }

            if rows.contains(where: { $0.isClash && $0.side == .vpn && $0.network.prefix <= clashPrefix($0) }) {
                Label("A whole range of your network goes through the VPN: devices on it (printer, NAS) aren't reachable while connected. To reach just a few servers, add their addresses instead.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Changes apply when you save Settings, at once if connected.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    let lists = RouteChoices.lists(rows)
                    profile.alwaysViaVPN = lists.viaVPN
                    profile.alwaysLocal = lists.local
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 800, height: 460)
        .onAppear {
            rows = RouteChoices.rows(pushed: serverRoutes, local: localNetworks,
                                     viaVPN: IPv4Network.parseList(profile.alwaysViaVPN).networks,
                                     alwaysLocal: IPv4Network.parseList(profile.alwaysLocal).networks)
            selection = rows.first(where: \.isClash)?.id
        }
    }

    /// The checkboxes of a row work as one choice: ticking one unticks the others.
    private func side(_ id: String, _ side: RouteChoice.Side) -> Binding<Bool> {
        Binding(
            get: { rows.first { $0.id == id }?.side == side },
            set: { ticked in
                guard ticked, let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index].side = side
            })
    }

    private func origin(of row: RouteChoice) -> String {
        switch row.origin {
        case .vpnRoute: "VPN route"
        case .clash(let network, let interface):
            if row.side == .automatic, let range = row.splittable {
                if let scan = localDevices.first(where: { $0.range == range }) {
                    "Shared with your \(InterfaceNames.display(interface)): \(scan.found.count - 1) devices local"
                } else {
                    "Shared with your \(InterfaceNames.display(interface)) network"
                }
            } else {
                "VPN route, also your \(InterfaceNames.display(interface)) network \(network)"
            }
        case .added: "Added by you"
        }
    }

    private func clashPrefix(_ row: RouteChoice) -> Int {
        if case .clash(let network, _) = row.origin { return network.prefix }
        return 32
    }

    /// An address or range goes in as typed; a name as its addresses (`/etc/hosts` first, then DNS).
    private func add() {
        if let network = newNetwork {
            add([network])
        } else if let name = newName, !lookingUp {
            lookingUp = true
            Task {
                let addresses = await hosts.addresses(of: name)
                lookingUp = false
                guard !addresses.isEmpty else {
                    addProblem = "No IPv4 address found for “\(name)”. Over the VPN, company names may only resolve once connected."
                    return
                }
                for address in addresses where hosts.name(of: address) == nil { typedNames[address] = name }
                add(addresses)
            }
        }
    }

    private func add(_ networks: [IPv4Network]) {
        for network in networks {
            if let index = rows.firstIndex(where: { $0.network == network }) {
                rows[index].side = .vpn
            } else {
                rows.append(RouteChoice(network: network, origin: .added, side: .vpn))
            }
        }
        selection = networks.last?.description
        newEntry = ""
    }
}
