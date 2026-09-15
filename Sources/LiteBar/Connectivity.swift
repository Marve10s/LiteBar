import Foundation
import Network

enum Connectivity: Sendable {
    case checking
    case offline
    case available

    static func isConnectionError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(error.code)
    }
}

final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()

    func start(_ update: @escaping @Sendable (Connectivity) -> Void) {
        monitor.pathUpdateHandler = { path in
            update(path.status == .unsatisfied ? .offline : .available)
        }
        monitor.start(queue: DispatchQueue(label: "dev.ibrahime.LiteBar.connectivity", qos: .utility))
    }

    deinit { monitor.cancel() }
}

enum HTTPClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
