// Serves /metrics on :9797 for the demo's Prometheus; a metrics reporter is what turns the registry on.
import ballerinax/prometheus as _;
// Publishes every metric sample as a log line, which fluent-bit routes to the console's metrics index.
import ballerinax/metrics.logs as _;
// Exports spans over OTLP to the demo's Jaeger.
import ballerinax/jaeger as _;
