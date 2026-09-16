import Foundation

/// Dedicated session so blocking Room/asset waits never sit on `URLSession.shared`
/// (Default QoS). Callbacks run at `.userInitiated` to match bootstrap/raster waiters.
enum DrawsKitURLSession {
    private static let delegateQueueName = "io.drawskit.url-session"
    private static let maxConcurrentCallbacks = 4

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.name = delegateQueueName
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = maxConcurrentCallbacks
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    static func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(NSError(domain: "DrawsKit", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "empty response",
                ]))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw NSError(domain: "DrawsKit", code: 6, userInfo: [NSLocalizedDescriptionKey: "request cancelled"])
        }
    }
}
