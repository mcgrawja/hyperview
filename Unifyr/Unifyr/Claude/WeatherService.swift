//
//  WeatherService.swift
//  Unifyr
//
//  Day weather for the briefing card via Open-Meteo (free, keyless, HTTPS).
//  Fetched natively — the strip renders from real data with zero API tokens;
//  a compact text summary is handed to Claude for the Brief section.
//

import Foundation
import CoreLocation
import MapKit

nonisolated struct WeatherSlot: Sendable, Identifiable {
    let id: Int            // hour offset from today 00:00 (6, 9, … 24)
    let label: String      // "6AM"
    let emoji: String
    let rainPercent: Int
    let tempF: Int
}

nonisolated struct DayWeather: Sendable {
    let locationName: String
    let slots: [WeatherSlot]
    let hiF: Int
    let loF: Int
    let concerns: [String]

    var promptSummary: String {
        let strip = slots.map { "\($0.label) \($0.emoji) \($0.tempF)°F \($0.rainPercent)% rain" }
            .joined(separator: "; ")
        let alerts = concerns.isEmpty ? "none" : concerns.joined(separator: ", ")
        return "Weather in \(locationName): hi \(hiF)°F / lo \(loF)°F. \(strip). Significant concerns: \(alerts)."
    }
}

nonisolated enum WeatherService {

    static func fetch(location: String) async -> DayWeather? {
        guard let (lat, lon, name) = await geocode(location) else { return nil }
        guard let encoded = try? await forecast(lat: lat, lon: lon, name: name) else { return nil }
        return encoded
    }

    // MARK: - Open-Meteo calls

    /// Apple's geocoder handles "City, ST" natively and requires no location
    /// permission (it's a network lookup, not device location). Uses
    /// MKGeocodingRequest (macOS 26); CLGeocoder is deprecated.
    private static func geocode(_ query: String) async -> (Double, Double, String)? {
        guard let request = MKGeocodingRequest(addressString: query),
              let item = (try? await request.mapItems)?.first else { return nil }
        let coordinate = item.location.coordinate
        let name = item.name ?? query
        return (coordinate.latitude, coordinate.longitude, name)
    }

    private static func forecast(lat: Double, lon: Double, name: String) async throws -> DayWeather? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"), // 2 days so the 12AM slot exists
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = parsed["hourly"] as? [String: Any],
              let temps = hourly["temperature_2m"] as? [Double],
              let rain = hourly["precipitation_probability"] as? [Any],
              let codes = hourly["weather_code"] as? [Int],
              let daily = parsed["daily"] as? [String: Any],
              let hiValues = daily["temperature_2m_max"] as? [Double],
              let loValues = daily["temperature_2m_min"] as? [Double],
              temps.count >= 25, codes.count >= 25 else { return nil }

        let hours = [6, 9, 12, 15, 18, 21, 24]
        let labels = ["6AM", "9AM", "12PM", "3PM", "6PM", "9PM", "12AM"]
        let slots = zip(hours, labels).map { hour, label in
            WeatherSlot(
                id: hour,
                label: label,
                emoji: emoji(code: codes[hour], hour: hour),
                rainPercent: intValue(rain, at: hour),
                tempF: Int(temps[hour].rounded())
            )
        }

        let hi = Int((hiValues.first ?? 0).rounded())
        let lo = Int((loValues.first ?? 0).rounded())
        // Look at the whole day's codes (through 12AM) for concerns.
        let dayCodes = Array(codes.prefix(25))
        return DayWeather(
            locationName: name,
            slots: slots,
            hiF: hi,
            loF: lo,
            concerns: concerns(codes: dayCodes, hi: hi, lo: lo, maxRain: (0...24).map { intValue(rain, at: $0) }.max() ?? 0)
        )
    }

    private static func intValue(_ array: [Any], at index: Int) -> Int {
        guard index < array.count else { return 0 }
        if let value = array[index] as? Int { return value }
        if let value = array[index] as? Double { return Int(value.rounded()) }
        return 0
    }

    // MARK: - WMO weather code mapping

    private static func emoji(code: Int, hour: Int) -> String {
        let night = hour >= 21 || hour < 6
        switch code {
        case 0: return night ? "🌙" : "☀️"
        case 1, 2: return night ? "☁️" : "🌤️"
        case 3: return "☁️"
        case 45, 48: return "🌫️"
        case 51...57: return "🌦️"
        case 61...67: return "🌧️"
        case 71...77, 85, 86: return "🌨️"
        case 80...82: return "🌦️"
        case 95...99: return "⛈️"
        default: return night ? "🌙" : "☀️"
        }
    }

    private static func concerns(codes: [Int], hi: Int, lo: Int, maxRain: Int) -> [String] {
        var out: [String] = []
        if codes.contains(where: { (95...99).contains($0) }) { out.append("Thunderstorms") }
        if codes.contains(where: { [65, 67, 82].contains($0) }) { out.append("Heavy Rain") }
        if codes.contains(where: { (71...77).contains($0) || [85, 86].contains($0) }) { out.append("Snow/Ice") }
        if codes.contains(where: { [45, 48].contains($0) }) { out.append("Fog") }
        if hi >= 97 { out.append("Extreme Heat") }
        if lo <= 25 { out.append("Freezing Temps") }
        if out.isEmpty, maxRain >= 70 { out.append("Likely Rain") }
        return out
    }
}
