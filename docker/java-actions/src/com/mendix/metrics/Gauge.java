package com.mendix.metrics;

/** A metric that holds a value. */
public interface Gauge extends Metric {
	void recordValue(double value);
	void recordDelta(double delta);
}
