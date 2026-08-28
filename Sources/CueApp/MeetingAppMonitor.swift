import AppKit
import CoreGraphics
import Foundation
import CueCore

struct MeetingAppDetection: Identifiable, Equatable, Sendable {
    let id: String
    let applicationName: String
    let windowTitle: String

    var displayTitle: String {
        windowTitle.isEmpty ? applicationName : windowTitle
    }
}

@MainActor
final class MeetingAppMonitor {
    typealias DetectionHandler = @MainActor (MeetingAppDetection) -> Void

    private let detectionHandler: DetectionHandler
    private var monitorTask: Task<Void, Never>?
    private var lastDetectionID: String?

    init(detectionHandler: @escaping DetectionHandler) {
        self.detectionHandler = detectionHandler
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.inspectVisibleWindows()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        lastDetectionID = nil
    }

    private func inspectVisibleWindows() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(0)
        ) as? [[String: Any]] else { return }

        let detection = windowList.lazy.compactMap(Self.zoomDetection).first
        guard let detection else {
            lastDetectionID = nil
            return
        }
        guard detection.id != lastDetectionID else { return }
        lastDetectionID = detection.id
        detectionHandler(detection)
    }

    private static func zoomDetection(
        _ window: [String: Any]
    ) -> MeetingAppDetection? {
        let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        guard let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
              )
        else { return nil }

        let title = ((window[kCGWindowName as String] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard MeetingAppDetectionHeuristic.isZoomMeetingWindow(
            ownerName: owner,
            windowTitle: title,
            layer: layer,
            width: bounds.width,
            height: bounds.height
        )
        else { return nil }

        let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        return MeetingAppDetection(
            id: "zoom:\(ownerPID)",
            applicationName: owner.isEmpty ? "Zoom" : owner,
            windowTitle: title
        )
    }
}
