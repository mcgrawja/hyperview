//
//  CommuteService.swift
//  Hyperview
//
//  Real drive-time estimate for the briefing via MKDirections (no API key
//  needed). Finds today's first timed event with a location and computes the
//  ETA from the user's home location (the briefing weather location).
//

import Foundation
import MapKit

nonisolated enum CommuteService {

    /// Returns a prompt-ready sentence like
    /// "Estimated drive to 'O2O Class': 42 min — leave by 7:18 AM for an 8:00 AM start."
    static func estimate(homeLocation: String, briefingJSON: String) async -> String? {
        guard let target = firstLocatedEvent(in: briefingJSON) else { return nil }
        guard let home = await geocode(homeLocation),
              let destination = await geocode(target.location) else { return nil }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: home))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        let minutes = Int((eta.expectedTravelTime / 60).rounded())
        guard minutes > 4 else { return nil } // next door — not worth a line

        let leaveBy = target.start.addingTimeInterval(-eta.expectedTravelTime - 5 * 60) // 5-min buffer
        return "Estimated drive to '\(target.title)': ~\(minutes) min — leave by \(leaveBy.formatted(date: .omitted, time: .shortened)) for a \(target.start.formatted(date: .omitted, time: .shortened)) start."
    }

    // MARK: - Helpers

    private static func firstLocatedEvent(in briefingJSON: String) -> (title: String, location: String, start: Date)? {
        guard let data = briefingJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = parsed["today_events"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let now = Date()
        for event in events {
            guard (event["all_day"] as? Bool) != true,
                  let location = event["location"] as? String, !location.isEmpty,
                  let title = event["title"] as? String,
                  let startRaw = event["start"] as? String,
                  let start = iso.date(from: startRaw),
                  start > now else { continue }
            return (title, location, start)
        }
        return nil
    }

    private static func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.geocodeAddressString(query).first,
              let location = placemark.location else { return nil }
        return location.coordinate
    }
}
