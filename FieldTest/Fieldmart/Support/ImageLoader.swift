import UIKit

/// The app's image loader: `URLSession` plus an `NSCache`, decoding off the
/// main thread, and handing out the **same** `UIImage` for the same URL as
/// long as it is cached (what most production loaders do, and what the
/// SDK's picture deduplication keys on).
final class ImageLoader {
    private let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()
    private var waiting: [URL: [(UIImage?) -> Void]] = [:]
    private let decodeQueue = DispatchQueue(label: "com.tracewayapp.fieldmart.decode", qos: .userInitiated,
                                            attributes: .concurrent)

    init(session: URLSession) {
        self.session = session
        cache.countLimit = 600
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Loads `url`; `completion` runs on the main queue (immediately for a
    /// cached image). Main thread only.
    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let image = cached(url) {
            completion(image)
            return
        }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]
        session.dataTask(with: url) { [weak self] data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
            guard let self = self else { return }
            self.decodeQueue.async {
                let image = ok ? data.flatMap(ImageLoader.decode) : nil
                DispatchQueue.main.async {
                    if let image = image { self.cache.setObject(image, forKey: url as NSURL) }
                    let callbacks = self.waiting.removeValue(forKey: url) ?? []
                    for callback in callbacks { callback(image) }
                }
            }
        }.resume()
    }

    /// Decodes and forces the bitmap off the main thread.
    static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data, scale: 1) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// The deliberately wasteful loader of Feed's shipment rows: it keeps the
/// bytes, but decodes a **new** `UIImage` every time a cell is configured
/// (H-I5: the SDK keys pictures by `UIImage` identity).
final class FreshImageLoader {
    private let session: URLSession
    private let bytes = NSCache<NSURL, NSData>()
    private var waiting: [URL: [(Data?) -> Void]] = [:]
    private let decodeQueue = DispatchQueue(label: "com.tracewayapp.fieldmart.decode-fresh", qos: .userInitiated)

    init(session: URLSession) {
        self.session = session
        bytes.countLimit = 400
    }

    /// A new `UIImage` for `url` on every call. Main thread only.
    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        data(url) { [weak self] data in
            guard let self = self, let data = data else {
                completion(nil)
                return
            }
            self.decodeQueue.async {
                let image = ImageLoader.decode(data)
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    private func data(_ url: URL, completion: @escaping (Data?) -> Void) {
        if let cached = bytes.object(forKey: url as NSURL) {
            completion(cached as Data)
            return
        }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]
        session.dataTask(with: url) { [weak self] data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
            DispatchQueue.main.async {
                guard let self = self else { return }
                let body = ok ? data : nil
                if let body = body { self.bytes.setObject(body as NSData, forKey: url as NSURL) }
                let callbacks = self.waiting.removeValue(forKey: url) ?? []
                for callback in callbacks { callback(body) }
            }
        }.resume()
    }
}

extension UIImageView {
    private static var urlKey: UInt8 = 0

    /// The URL this view is waiting for, so a reused cell ignores a late
    /// answer for its previous content.
    var fmImageURL: URL? {
        get { objc_getAssociatedObject(self, &UIImageView.urlKey) as? URL }
        set { objc_setAssociatedObject(self, &UIImageView.urlKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Shows the picture at `url` from `loader` (stable images).
    func fmSetImage(_ url: URL?, loader: ImageLoader) {
        fmImageURL = url
        guard let url = url else {
            image = nil
            return
        }
        if let cached = loader.cached(url) {
            image = cached
            return
        }
        image = nil
        loader.load(url) { [weak self] loaded in
            guard let self = self, self.fmImageURL == url else { return }
            self.image = loaded
        }
    }

    /// Shows the picture at `url` as a new `UIImage` (Feed shipments).
    func fmSetFreshImage(_ url: URL?, loader: FreshImageLoader) {
        fmImageURL = url
        image = nil
        guard let url = url else { return }
        loader.load(url) { [weak self] loaded in
            guard let self = self, self.fmImageURL == url else { return }
            self.image = loaded
        }
    }
}
