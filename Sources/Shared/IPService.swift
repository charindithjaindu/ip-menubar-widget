import Foundation

/// Snapshot of the network identity we show in both the menu bar app and the widget.
struct IPInfo: Equatable {
    var ipv4: String
    var ipv6: String
    var country: String
    var countryFlag: String
    var isp: String

    static let placeholder = IPInfo(
        ipv4: "203.0.113.7",
        ipv6: "2001:db8::1",
        country: "United States",
        countryFlag: "🇺🇸",
        isp: "Example ISP"
    )

    static let loading = IPInfo(ipv4: "…", ipv6: "…", country: "…", countryFlag: "🏳️", isp: "…")
}

/// Fetches the public IPv4, IPv6 and country. Shared by both targets.
enum IPService {
    static func fetch() async -> IPInfo {
        // One geo request returns IPv4 + country together; IPv6 needs its own
        // connection (a single request can't report both protocols).
        async let geo = geoLookup()
        async let v6 = ipv6()

        let g = await geo

        // Use geo's address as the IPv4 if it really is v4 (no colon). On a
        // dual-stack machine geo may have connected over v6, so fall back to a
        // dedicated IPv4-only host in that case.
        let ipv4: String
        if let ip = g.ip, !ip.contains(":") {
            ipv4 = ip
        } else {
            ipv4 = (await plainText(from: "https://api.ipify.org")) ?? "Unavailable"
        }

        return IPInfo(ipv4: ipv4, ipv6: await v6, country: g.country, countryFlag: g.flag, isp: g.isp)
    }

    /// Tries several IPv6 providers in order. Returns the first result that is
    /// actually an IPv6 address (contains ":"); otherwise "Not available".
    /// Note: all of these can only succeed if your network has a public IPv6 route.
    private static func ipv6() async -> String {
        let providers = [
            "https://ipv6.icanhazip.com",
            "https://6.ident.me",
            "https://ipv6.seeip.org",
            "https://api6.ipify.org"   // original source, now a fallback
        ]
        for urlString in providers {
            if let text = await plainText(from: urlString), text.contains(":") {
                return text
            }
        }
        return "Not available"
    }

    private static func plainText(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private struct Geo: Decodable {
        let ip: String?
        let name: String?
        let code: String?
        let isp: String?

        // ipwho.is nests the provider under a "connection" object.
        private struct Connection: Decodable {
            let isp: String?
            let org: String?
        }

        // Accept the field names used by the different providers we try:
        //   ipapi.co  -> "org"        ipinfo.io -> "org"
        //   ipwho.is  -> connection.isp/org     ifconfig.co -> "asn_org"
        enum CodingKeys: String, CodingKey {
            case ip, country_name, country, country_code, countryCode
            case org, asn_org, connection
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ip = try c.decodeIfPresent(String.self, forKey: .ip)
            name = try c.decodeIfPresent(String.self, forKey: .country_name)
                ?? c.decodeIfPresent(String.self, forKey: .country)
            code = try c.decodeIfPresent(String.self, forKey: .country_code)
                ?? c.decodeIfPresent(String.self, forKey: .countryCode)
            let connection = try c.decodeIfPresent(Connection.self, forKey: .connection)
            let org = try c.decodeIfPresent(String.self, forKey: .org)
            let asnOrg = try c.decodeIfPresent(String.self, forKey: .asn_org)
            isp = connection?.isp ?? connection?.org ?? org ?? asnOrg
        }
    }

    /// One request that yields the connecting IP, country and ISP.
    private static func geoLookup() async -> (ip: String?, country: String, flag: String, isp: String) {
        // Try providers in order until one returns a usable country.
        let providers = [
            "https://ipapi.co/json/",
            "https://ipwho.is/",
            "https://ifconfig.co/json"
        ]
        for urlString in providers {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let geo = try? JSONDecoder().decode(Geo.self, from: data),
                  let name = geo.name, !name.isEmpty else { continue }
            let flag = geo.code.map(flagEmoji) ?? "🏳️"
            let isp = geo.isp.map { $0.isEmpty ? "Unknown" : $0 } ?? "Unknown"
            return (geo.ip, name, flag, isp)
        }
        return (nil, "Unknown", "🏳️", "Unknown")
    }

    /// Turns an ISO country code like "US" into 🇺🇸 via regional indicator symbols.
    static func flagEmoji(_ code: String) -> String {
        let base: UInt32 = 127_397
        var result = ""
        for scalar in code.uppercased().unicodeScalars where ("A"..."Z").contains(Character(scalar)) {
            if let flagScalar = UnicodeScalar(base + scalar.value) {
                result.unicodeScalars.append(flagScalar)
            }
        }
        return result.isEmpty ? "🏳️" : result
    }
}
