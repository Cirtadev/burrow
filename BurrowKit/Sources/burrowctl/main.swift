import BurrowKit
import Foundation

// Developer tool. It never reads the keychain (rebuilt CLIs would prompt on every build).

func usage() -> Never {
    print("""
    usage: burrowctl configs                 list configurations tunnelblickd can start
           burrowctl daemon <arg>...         send one request to tunnelblickd (e.g. `daemon test`)
           burrowctl start-args <name>       print the start request Burrow would send (password redacted)
           burrowctl otp <secret|otpauth://> print the current code
           burrowctl processes               list running openvpn processes
           burrowctl ovpn <file>             summarize an .ovpn file (never prints keys)
           burrowctl networks [route...]     local IPv4 networks, and clashes with the given VPN routes
    """)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }
let command = arguments.removeFirst()

switch command {
case "configs":
    print("Tunnelblick installed: \(Tunnelblick.isInstalled); default OpenVPN: \(Tunnelblick.defaultOpenVPNVersion() ?? "?")")
    for configuration in Tunnelblick.configurations() {
        print("\(configuration.id)\t\(configuration.tblkPath)")
    }

case "daemon":
    guard !arguments.isEmpty else { usage() }
    do {
        let reply = try TunnelblickDaemon().run(arguments)
        print("status \(reply.status)")
        if !reply.stdout.isEmpty { print("stdout:\n\(reply.stdout)") }
        if !reply.stderr.isEmpty { print("stderr:\n\(reply.stderr)") }
        exit(reply.status == 0 ? 0 : 1)
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }

case "start-args":
    guard let name = arguments.first,
          let configuration = Tunnelblick.configurations().first(where: { $0.displayName == name }) else { usage() }
    let port = (try? LocalPort.free()) ?? 0
    var request = Tunnelblick.startArguments(for: configuration, port: port, managementPassword: "<password>")
    request[0] = "openvpnstart: " + request[0]
    print(request.joined(separator: " "))

case "otp":
    guard let secret = arguments.first else { usage() }
    do {
        let totp = try TOTP(parsing: secret)
        print("\(totp.code(at: .now))  (\(totp.secondsRemaining(at: .now)) s left)")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }

case "ovpn":
    guard let path = arguments.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else { usage() }
    let summary = OVPNSummary(text)
    print("server: \(summary.serverDescription)")
    print("client: \(summary.isClient)  auth-user-pass: \(summary.needsUsernamePassword)  inline key: \(summary.hasInlineKey)")
    print(summary.problem.map { "problem: \($0)" } ?? "usable: yes")

case "networks":
    let local = LocalNetworks.current()
    for entry in local { print("\(entry.interface)\t\(entry.network)") }
    let routes = arguments.compactMap(IPv4Network.init)
    for clash in RouteClash.find(vpnRoutes: routes, local: local) {
        print("clash: VPN route \(clash.vpnRoute) overlaps \(clash.localNetwork) on \(clash.interface)")
    }

case "processes":
    print(Processes.pids(named: "openvpn").map(String.init).joined(separator: "\n"))

default:
    usage()
}
