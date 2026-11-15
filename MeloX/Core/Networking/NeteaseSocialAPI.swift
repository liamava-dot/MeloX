import Foundation

extension NeteaseAPI {
    func shareToTimeline(
        _ resource: NeteaseShareResource,
        message: String = ""
    ) async throws {
        guard resource.supportsTimelineSharing else {
            throw NeteaseSocialError.unsupportedTimelineResource
        }

        let response: APIStatusResponse = try await client.eapi(
            "/api/share/friends/resource",
            data: [
                "type": resource.resourceType,
                "msg": message,
                "id": resource.resourceID,
            ],
            authenticated: true
        )
        try validate(responseCode: response.code, message: response.message)
    }

}
