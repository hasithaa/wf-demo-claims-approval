// Links the Prometheus metrics reporter into the executable. The reporter activates only
// when Config.toml turns metrics on, so this import costs nothing when observability is off.
import ballerinax/prometheus as _;
