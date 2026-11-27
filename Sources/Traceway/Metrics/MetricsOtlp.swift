import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf

let attrSentAt = "traceway.sent_at"
let attrRetry = "traceway.retry"

/// A resource or point attribute of a metrics payload.
enum MetricAttribute: Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

private typealias ProtoRequest = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest
private typealias ProtoKeyValue = Opentelemetry_Proto_Common_V1_KeyValue

private func nanos(_ ms: Int64) -> UInt64 { UInt64(max(0, ms)) * 1_000_000 }

private func keyValue(_ key: String, _ value: MetricAttribute) -> ProtoKeyValue {
    var out = ProtoKeyValue()
    out.key = key
    switch value {
    case .string(let v): out.value.stringValue = v
    case .int(let v): out.value.intValue = v
    case .double(let v): out.value.doubleValue = v
    case .bool(let v): out.value.boolValue = v
    }
    return out
}

/// In key order, so the same batch always encodes to the same bytes.
private func keyValues(_ attributes: [String: MetricAttribute]) -> [ProtoKeyValue] {
    attributes.keys.sorted().map { keyValue($0, attributes[$0]!) }
}

private func keyValues(_ dims: MetricDims) -> [ProtoKeyValue] {
    dims.keys.sorted().map { keyValue($0, .string(dims[$0]!)) }
}

/// Renders a batch as an OTLP `ExportMetricsServiceRequest` in protobuf,
/// with the generated types of opentelemetry-swift: exponential histograms
/// and monotonic sums, both with delta temporality, which is what the
/// server takes from a client (a cumulative series would need an identity
/// per device). The same shape as the Android SDK's marshaler writes.
func encodeMetrics(
    _ batch: MetricBatch,
    resource: [String: MetricAttribute],
    scopeName: String,
    scopeVersion: String
) -> Data {
    let start = nanos(batch.startMs)
    let end = nanos(batch.endMs)
    var metrics: [Opentelemetry_Proto_Metrics_V1_Metric] = []
    var histogramIndex: [String: Int] = [:]
    for point in batch.histograms {
        let h = point.histogram
        var data = Opentelemetry_Proto_Metrics_V1_ExponentialHistogramDataPoint()
        data.attributes = keyValues(point.dims)
        data.startTimeUnixNano = start
        data.timeUnixNano = end
        data.count = UInt64(h.count)
        data.sum = h.sum
        data.scale = histogramScale
        data.zeroCount = UInt64(h.zeroCount)
        if h.count > 0 {
            data.min = h.min
            data.max = h.max
        }
        var positive = Opentelemetry_Proto_Metrics_V1_ExponentialHistogramDataPoint.Buckets()
        if let low = h.buckets.keys.min(), let high = h.buckets.keys.max() {
            var counts = [UInt64](repeating: 0, count: high - low + 1)
            for (index, n) in h.buckets { counts[index - low] = UInt64(n) }
            positive.offset = Int32(low)
            positive.bucketCounts = counts
        }
        data.positive = positive
        data.negative = Opentelemetry_Proto_Metrics_V1_ExponentialHistogramDataPoint.Buckets()
        data.exemplars = point.exemplars.map { e in
            var exemplar = Opentelemetry_Proto_Metrics_V1_Exemplar()
            var filtered: [String: MetricAttribute] = ["session.id": .string(e.sessionId)]
            if let target = e.target { filtered["traceway.target"] = .string(target) }
            exemplar.filteredAttributes = keyValues(filtered)
            exemplar.timeUnixNano = nanos(e.timeMs)
            exemplar.asDouble = e.value
            return exemplar
        }
        if let index = histogramIndex[point.name] {
            metrics[index].exponentialHistogram.dataPoints.append(data)
        } else {
            var metric = Opentelemetry_Proto_Metrics_V1_Metric()
            metric.name = point.name
            metric.unit = point.unit
            var histogram = Opentelemetry_Proto_Metrics_V1_ExponentialHistogram()
            histogram.aggregationTemporality = .delta
            histogram.dataPoints = [data]
            metric.exponentialHistogram = histogram
            histogramIndex[point.name] = metrics.count
            metrics.append(metric)
        }
    }
    var sumIndex: [String: Int] = [:]
    for point in batch.sums {
        var data = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
        data.attributes = keyValues(point.dims)
        data.startTimeUnixNano = start
        data.timeUnixNano = end
        data.asDouble = point.value
        if let index = sumIndex[point.name] {
            metrics[index].sum.dataPoints.append(data)
        } else {
            var metric = Opentelemetry_Proto_Metrics_V1_Metric()
            metric.name = point.name
            var sum = Opentelemetry_Proto_Metrics_V1_Sum()
            sum.aggregationTemporality = .delta
            sum.isMonotonic = true
            sum.dataPoints = [data]
            metric.sum = sum
            sumIndex[point.name] = metrics.count
            metrics.append(metric)
        }
    }

    var scopeMetrics = Opentelemetry_Proto_Metrics_V1_ScopeMetrics()
    scopeMetrics.scope.name = scopeName
    scopeMetrics.scope.version = scopeVersion
    scopeMetrics.metrics = metrics
    var resourceMetrics = Opentelemetry_Proto_Metrics_V1_ResourceMetrics()
    resourceMetrics.resource.attributes = keyValues(resource)
    resourceMetrics.scopeMetrics = [scopeMetrics]
    var request = ProtoRequest()
    request.resourceMetrics = [resourceMetrics]
    return (try? request.serializedData()) ?? Data()
}

/// The request with every resource restamped for its one resend: the server
/// corrects the device clock from the send time, so a resend states its own
/// `traceway.sent_at`, and `traceway.retry` lets it drop a payload it
/// already has. Everything else is kept as it was, fields this SDK does not
/// know included. Nil when `body` is not a request this SDK can read.
func restampForRetry(_ body: Data, sentAtMs: Int64) -> Data? {
    guard var request = try? ProtoRequest(serializedBytes: body) else { return nil }
    for i in request.resourceMetrics.indices {
        var attributes = request.resourceMetrics[i].resource.attributes.filter {
            $0.key != attrSentAt && $0.key != attrRetry
        }
        attributes.append(keyValue(attrSentAt, .int(sentAtMs)))
        attributes.append(keyValue(attrRetry, .bool(true)))
        request.resourceMetrics[i].resource.attributes = attributes
    }
    return try? request.serializedData()
}
