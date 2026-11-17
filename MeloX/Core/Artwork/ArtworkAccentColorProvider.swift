import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct ArtworkDetailPalette: Equatable, Sendable {
    /// Unadjusted cover color, independent of the application appearance.
    let sourceRGB: SIMD3<Double>
    let accentRGB: SIMD3<Double>

    nonisolated static func fallback(prefersDarkAppearance _: Bool) -> Self {
        Self(
            sourceRGB: SIMD3<Double>(repeating: 0.5),
            accentRGB: ArtworkAccentColorProvider.fallback
        )
    }
}

struct ArtworkDetailAssets: @unchecked Sendable {
    let palette: ArtworkDetailPalette
    let flowingLightPalette: ArtworkFlowingLightPalette
    let blurredBackdropImage: CGImage?

    nonisolated static func fallback(prefersDarkAppearance: Bool) -> Self {
        Self(
            palette: .fallback(
                prefersDarkAppearance: prefersDarkAppearance
            ),
            flowingLightPalette: .fallback,
            blurredBackdropImage: nil
        )
    }
}

private nonisolated final class ArtworkDetailAssetsBox: NSObject, @unchecked Sendable {
    let assets: ArtworkDetailAssets

    init(_ assets: ArtworkDetailAssets) {
        self.assets = assets
    }
}

private nonisolated final class ArtworkDetailAssetsCache: @unchecked Sendable {
    private let storage = NSCache<NSURL, ArtworkDetailAssetsBox>()

    init() {
        storage.countLimit = 80
        storage.totalCostLimit = 12 * 1_024 * 1_024
    }

    func assets(for url: URL) -> ArtworkDetailAssets? {
        storage.object(forKey: url as NSURL)?.assets
    }

    func insert(_ assets: ArtworkDetailAssets, for url: URL) {
        let pixelCost = assets.blurredBackdropImage.map {
            $0.width * $0.height * 4
        } ?? 0
        storage.setObject(
            ArtworkDetailAssetsBox(assets),
            forKey: url as NSURL,
            cost: pixelCost
        )
    }

    func removeAll() {
        storage.removeAllObjects()
    }
}

actor ArtworkAccentColorProvider {
    static let shared = ArtworkAccentColorProvider()
    nonisolated static let fallback = SIMD3<Double>(repeating: 0.86)
    private nonisolated static let assetsCache = ArtworkDetailAssetsCache()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    nonisolated static func cachedDetailAssets(
        for artworkURL: URL?
    ) -> ArtworkDetailAssets? {
        guard let artworkURL else { return nil }
        return assetsCache.assets(for: artworkURL)
    }

    nonisolated static func clearCache() {
        assetsCache.removeAll()
    }

    func accentColor(for artworkURL: URL?) async -> SIMD3<Double> {
        guard let artworkURL else { return Self.fallback }
        if let cachedAssets = Self.assetsCache.assets(for: artworkURL) {
            return cachedAssets.palette.accentRGB
        }

        return await detailPalette(for: artworkURL).accentRGB
    }

    func detailPalette(
        for artworkURL: URL?,
        fallbackPrefersDarkAppearance: Bool = false
    ) async -> ArtworkDetailPalette {
        await detailAssets(
            for: artworkURL,
            fallbackPrefersDarkAppearance: fallbackPrefersDarkAppearance
        ).palette
    }

    func detailAssets(
        for artworkURL: URL?,
        fallbackPrefersDarkAppearance: Bool = false
    ) async -> ArtworkDetailAssets {
        guard let artworkURL else {
            return .fallback(
                prefersDarkAppearance: fallbackPrefersDarkAppearance
            )
        }
        if let cachedAssets = Self.assetsCache.assets(for: artworkURL) {
            return cachedAssets
        }

        do {
            let requestURL = optimizedArtworkURL(for: artworkURL)
            let (data, _) = try await URLSession.shared.data(from: requestURL)
            try Task.checkCancellation()
            guard let image = CIImage(
                data: data,
                options: [.applyOrientationProperty: true]
            ) else {
                return .fallback(
                    prefersDarkAppearance: fallbackPrefersDarkAppearance
                )
            }

            let preparedImage = downsampled(image)
            let assets = ArtworkDetailAssets(
                palette: makeDetailPalette(
                    from: representativeColor(of: preparedImage),
                    accentSource: averageColor(of: preparedImage)
                ),
                flowingLightPalette:
                    makeFlowingLightPalette(
                        from: preparedImage
                    ),
                blurredBackdropImage: makeBlurredBackdrop(
                    from: preparedImage
                )
            )
            Self.assetsCache.insert(assets, for: artworkURL)
            return assets
        } catch {
            return .fallback(
                prefersDarkAppearance: fallbackPrefersDarkAppearance
            )
        }
    }

    private func optimizedArtworkURL(for artworkURL: URL) -> URL {
        guard artworkURL.host?.hasSuffix(".music.126.net") == true,
              var components = URLComponents(
                url: artworkURL,
                resolvingAgainstBaseURL: false
              ) else {
            return artworkURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("param") == .orderedSame }
        queryItems.append(URLQueryItem(name: "param", value: "160y160"))
        components.queryItems = queryItems
        return components.url ?? artworkURL
    }

    private func downsampled(_ image: CIImage) -> CIImage {
        let maximumDimension = max(image.extent.width, image.extent.height)
        guard maximumDimension > 160 else { return image }

        let scale = 160 / maximumDimension
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    private func makeBlurredBackdrop(from image: CIImage) -> CGImage? {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return nil }

        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = 18
        guard let outputImage = filter.outputImage?.cropped(to: extent) else {
            return nil
        }

        return context.createCGImage(
            outputImage,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    private func averageColor(of image: CIImage) -> SIMD3<Double> {
        averageColor(
            of: image,
            extent: image.extent
        )
    }

    private func averageColor(
        of image: CIImage,
        extent: CGRect
    ) -> SIMD3<Double> {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let outputImage = filter.outputImage else { return Self.fallback }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return SIMD3<Double>(
            Double(pixel[0]) / 255,
            Double(pixel[1]) / 255,
            Double(pixel[2]) / 255
        )
    }

    private func makeFlowingLightPalette(
        from image: CIImage
    ) -> ArtworkFlowingLightPalette {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else {
            return .fallback
        }

        let dimension =
            ArtworkFlowingLightPalette.gridDimension
        let cellWidth = extent.width / CGFloat(dimension)
        let cellHeight = extent.height / CGFloat(dimension)
        let colors = (0..<dimension).flatMap { row in
            (0..<dimension).map { column in
                let cell = CGRect(
                    x: extent.minX
                        + CGFloat(column) * cellWidth,
                    y: extent.minY
                        + CGFloat(dimension - row - 1)
                            * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                return averageColor(
                    of: image,
                    extent: cell
                )
            }
        }
        return ArtworkFlowingLightPalette(
            colorsRGB: colors
        )
    }

    /// Population-weighted color buckets retain a cover's dominant hue rather than
    /// averaging complementary colors into gray. Chroma has a bounded bonus so a
    /// tiny saturated logo cannot outweigh the rest of the artwork. Neutral covers
    /// use their area average to preserve their original grayscale balance.
    private func representativeColor(of image: CIImage) -> SIMD3<Double> {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return Self.fallback }
        let width = Int(extent.width)
        let height = Int(extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let bucketCount = 8 * 8 * 8
        var weights = [Double](repeating: 0, count: bucketCount)
        var sums = [SIMD3<Double>](repeating: .zero, count: bucketCount)
        var average = SIMD3<Double>.zero
        var totalWeight = 0.0
        var chromaTotal = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.01 else { continue }
            // Core Image renders premultiplied RGBA; ignore transparent borders.
            let color = clamped(SIMD3<Double>(
                Double(pixels[offset]),
                Double(pixels[offset + 1]),
                Double(pixels[offset + 2])
            ) / (255 * alpha))
            let chroma = max(color.x, color.y, color.z) - min(color.x, color.y, color.z)
            let weight = alpha * (1 + 2 * chroma)
            let red = min(Int(color.x * 8), 7)
            let green = min(Int(color.y * 8), 7)
            let blue = min(Int(color.z * 8), 7)
            let bucket = red * 64 + green * 8 + blue
            weights[bucket] += weight
            sums[bucket] += color * weight
            average += color * alpha
            chromaTotal += chroma * alpha
            totalWeight += alpha
        }
        guard totalWeight > 0 else { return Self.fallback }
        average /= totalWeight
        guard chromaTotal / totalWeight > 0.04,
              let dominant = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[dominant] > 0 else { return average }
        return clamped(sums[dominant] / weights[dominant] * 0.75 + average * 0.25)
    }

    private func makeDetailPalette(
        from source: SIMD3<Double>,
        accentSource: SIMD3<Double>
    ) -> ArtworkDetailPalette {
        ArtworkDetailPalette(
            sourceRGB: clamped(source),
            // Preserve the existing accent used by player and other consumers.
            accentRGB: readableAccent(accentSource)
        )
    }

    private func readableAccent(_ source: SIMD3<Double>) -> SIMD3<Double> {
        let sourcePeak = max(source.x, source.y, source.z)
        guard sourcePeak > 0.04 else { return Self.fallback }

        let luminance = relativeLuminance(source)
        var accent = SIMD3<Double>(
            luminance + (source.x - luminance) * 1.35,
            luminance + (source.y - luminance) * 1.35,
            luminance + (source.z - luminance) * 1.35
        )

        let peak = max(accent.x, accent.y, accent.z)
        if peak < 0.76 {
            accent *= 0.76 / max(peak, 0.01)
        }

        let spread = max(accent.x, accent.y, accent.z)
            - min(accent.x, accent.y, accent.z)
        if spread < 0.08 {
            let neutral = min(max(luminance + 0.28, 0.74), 0.92)
            return SIMD3<Double>(repeating: neutral)
        }

        return SIMD3<Double>(
            min(max(accent.x, 0), 1),
            min(max(accent.y, 0), 1),
            min(max(accent.z, 0), 1)
        )
    }

    private func relativeLuminance(_ color: SIMD3<Double>) -> Double {
        color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
    }

    private func clamped(_ color: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            min(max(color.x, 0), 1),
            min(max(color.y, 0), 1),
            min(max(color.z, 0), 1)
        )
    }
}
