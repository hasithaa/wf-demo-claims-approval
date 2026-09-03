// Links the Prometheus metrics reporter into the executable. The reporter activates only
// when Config.toml turns metrics on, so this import costs nothing when observability is off.
import ballerinax/prometheus as _;
// And the Jaeger tracer: workflow spans (run, sendData, human task completions, the
// agent's turns) publish over OTLP to the demo's jaeger service.
import ballerinax/jaeger as _;
