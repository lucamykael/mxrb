package com.mendix.metrics;

/**
 * The metrics of the application. The Ruby application keeps no Micrometer
 * registry, so the sidecar's metrics record nothing.
 */
public interface Metrics {
	Metric.Builder<Counter> createCounter(String name);
	Metric.Builder<Timer> createTimer(String name);
	Metric.Builder<Gauge> createGauge(String name);

	/** Metrics that record nothing. */
	static Metrics none() {
		return new Metrics() {
			@Override
			public Metric.Builder<Counter> createCounter(String name) {
				return builder(new Counter() {
					@Override
					public void increment() {
					}

					@Override
					public void increment(double amount) {
					}
				});
			}

			@Override
			public Metric.Builder<Timer> createTimer(String name) {
				return builder(new Timer() {
					@Override
					public void record(long amount, java.util.concurrent.TimeUnit unit) {
					}

					@Override
					public <T> T record(java.util.function.Supplier<T> work) {
						return work.get();
					}
				});
			}

			@Override
			public Metric.Builder<Gauge> createGauge(String name) {
				return builder(new Gauge() {
					@Override
					public void recordValue(double value) {
					}

					@Override
					public void recordDelta(double delta) {
					}
				});
			}
		};
	}

	private static <M extends Metric> Metric.Builder<M> builder(M metric) {
		return new Metric.Builder<>() {
			@Override
			public Metric.Builder<M> withDescription(String description) {
				return this;
			}

			@Override
			public Metric.Builder<M> withTag(String name, String value) {
				return this;
			}

			@Override
			public M build() {
				return metric;
			}
		};
	}
}
