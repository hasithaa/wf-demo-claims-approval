// The Prometheus reporter serves /metrics on :9797 (its default); nothing scrapes it in the
// demo, but a metrics reporter is what turns the registry on.
import ballerinax/prometheus as _;
// Publishes every metric sample as a log line, which fluent-bit routes to the console's metrics index.
import ballerinax/metrics.logs as _;
